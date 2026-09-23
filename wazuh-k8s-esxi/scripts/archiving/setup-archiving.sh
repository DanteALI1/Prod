#!/usr/bin/env bash
# Configure OpenSearch snapshot repository + ISM policy (90-day lifecycle)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config

if [[ -z "${KUBECONFIG:-}" && -f /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi
require_cmd kubectl
if ! command -v jq >/dev/null 2>&1; then
  detect_os
  # shellcheck disable=SC2086
  install_packages $(resolve_pkg_list jq) || die "jq required"
fi
require_cmd jq

log "=== setup-archiving: ISM + snapshot repo ==="

INDEXER_POD="$(kubectl -n "${WAZUH_NAMESPACE}" get pods -l app=wazuh-indexer -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${INDEXER_POD}" ]] || die "No indexer pod found"

# Body must be streamed into the pod (host paths are invisible to curl inside the container).
curl_idx() {
  local method="$1" path="$2"
  shift 2
  local body_file="" own_tmp=false
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d)
        if [[ "${2:-}" == "@-" ]]; then
          body_file="$(mktemp)"
          cat >"${body_file}"
          own_tmp=true
          shift 2
        elif [[ "${2:-}" == @* ]]; then
          body_file="${2#@}"
          shift 2
        else
          body_file="$(mktemp)"
          printf '%s' "$2" >"${body_file}"
          own_tmp=true
          shift 2
        fi
        ;;
      *)
        args+=("$1"); shift ;;
    esac
  done
  if [[ -n "${body_file}" ]]; then
    [[ -f "${body_file}" ]] || die "curl_idx body file missing: ${body_file}"
    kubectl -n "${WAZUH_NAMESPACE}" exec -i "${INDEXER_POD}" -- \
      curl -sk -u "${INDEXER_ADMIN_USER}:${INDEXER_ADMIN_PASSWORD}" \
      -H "Content-Type: application/json" \
      -X "${method}" "https://localhost:9200${path}" -d @- "${args[@]+"${args[@]}"}" \
      <"${body_file}"
    [[ "${own_tmp}" == "true" ]] && rm -f "${body_file}"
  else
    kubectl -n "${WAZUH_NAMESPACE}" exec "${INDEXER_POD}" -- \
      curl -sk -u "${INDEXER_ADMIN_USER}:${INDEXER_ADMIN_PASSWORD}" \
      -H "Content-Type: application/json" \
      -X "${method}" "https://localhost:9200${path}" "${args[@]+"${args[@]}"}"
  fi
}

check_cluster_health() {
  local health
  health="$(curl_idx GET '/_cluster/health' | jq -r '.status')"
  log "Cluster health: ${health}"
  [[ "${health}" == "green" || "${health}" == "yellow" ]] || die "Indexer unhealthy: ${health}"
}

register_snapshot_repo() {
  local body
  if [[ "${SNAPSHOT_REPO_TYPE}" == "s3" ]]; then
    [[ -n "${SNAPSHOT_S3_ACCESS_KEY}" ]] || die "SNAPSHOT_S3_ACCESS_KEY required for s3 repo"
    body=$(jq -n \
      --arg bucket "${SNAPSHOT_S3_BUCKET}" \
      --arg endpoint "${SNAPSHOT_S3_ENDPOINT}" \
      --arg region "${SNAPSHOT_S3_REGION}" \
      '{
        type: "s3",
        settings: {
          bucket: $bucket,
          endpoint: $endpoint,
          region: $region,
          path_style_access: "true"
        }
      }')
    log "Registering S3 snapshot repo ${SNAPSHOT_REPO_NAME} -> ${SNAPSHOT_S3_BUCKET}"
  else
    body=$(jq -n --arg loc "${SNAPSHOT_REPO_PATH}" \
      '{type:"fs", settings:{location:$loc, compress:true}}')
    log "Registering FS snapshot repo ${SNAPSHOT_REPO_NAME} -> ${SNAPSHOT_REPO_PATH}"
    log "NOTE: path must be mounted on ALL indexer pods (NFS) and listed in path.repo"
  fi
  echo "${body}" | curl_idx PUT "/_snapshot/${SNAPSHOT_REPO_NAME}" -d @-
  log "Snapshot repository registered"
}

apply_ism_policy() {
  local policy_file="${ROOT_DIR}/config/ism-policy.json"
  [[ -f "${policy_file}" ]] || die "Missing ${policy_file}"

  local tmp
  tmp="$(mktemp)"
  jq --arg hot "${HOT_RETENTION_DAYS}d" \
     --arg warm "${WARM_AFTER_DAYS}d" \
     --arg cold "${COLD_SNAPSHOT_AFTER_DAYS}d" \
     --arg repo "${SNAPSHOT_REPO_NAME}" \
     '
      .policy.states = [
        {
          name: "hot",
          actions: [{replica_count:{number_of_replicas:1}}],
          transitions: [{state_name:"warm", conditions:{min_index_age:$hot}}]
        },
        {
          name: "warm",
          actions: [
            {replica_count:{number_of_replicas:1}},
            {force_merge:{max_num_segments:1}},
            {read_only:{}}
          ],
          transitions: [{state_name:"cold_archive", conditions:{min_index_age:$cold}}]
        },
        {
          name: "cold_archive",
          actions: [
            {snapshot:{repository:$repo, snapshot:"ism-snap-{{ctx.index}}-{{ctx.execution_id}}"}},
            {delete:{}}
          ]
        }
      ]
      | .policy.default_state = "hot"
      | .policy.ism_template = [{index_patterns:["wazuh-alerts-*","wazuh-archives-*"], priority:100}]
     ' "${policy_file}" >"${tmp}"

  log "Applying ISM policy wazuh-retention-90d (hot ${HOT_RETENTION_DAYS}d, archive ${COLD_SNAPSHOT_AFTER_DAYS}d)"
  curl_idx PUT "/_plugins/_ism/policies/wazuh-retention-90d" -d @"${tmp}"
  rm -f "${tmp}"
  log "ISM policy applied"
}

manual_snapshot_now() {
  local name="manual-$(date +%Y%m%d-%H%M%S)"
  log "Creating optional baseline snapshot ${name}"
  echo '{"indices":"wazuh-alerts-*,wazuh-archives-*","include_global_state":false}' \
    | curl_idx PUT "/_snapshot/${SNAPSHOT_REPO_NAME}/${name}?wait_for_completion=false" -d @- \
    || warn "manual snapshot request failed"
}

verify() {
  curl_idx GET "/_snapshot/${SNAPSHOT_REPO_NAME}" | tee -a "${LOG_FILE}"
  curl_idx GET "/_plugins/_ism/policies/wazuh-retention-90d" | tee -a "${LOG_FILE}" | jq '{policy:.policy.policy.description? // .}' 2>/dev/null || true
  log "Archiving setup complete"
}

check_cluster_health
register_snapshot_repo
apply_ism_policy
manual_snapshot_now
verify
log "Done. Restore procedure: scripts/archiving/restore-guide.md"
