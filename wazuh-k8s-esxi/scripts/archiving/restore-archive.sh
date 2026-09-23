#!/usr/bin/env bash
# List / restore / cleanup archived Wazuh indices from snapshot repository
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

usage() {
  cat <<EOF
Usage:
  $0 --list
  $0 --show <snapshot>
  $0 --restore <snapshot> --indices <pattern> [--replicas N]
  $0 --alias-add <index>
  $0 --delete-restored <pattern>
  $0 --snapshot-now
EOF
  exit 1
}

INDEXER_POD="$(kubectl -n "${WAZUH_NAMESPACE}" get pods -l app=wazuh-indexer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${INDEXER_POD}" ]] || die "No indexer pod"

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

ACTION=""
SNAPSHOT=""
INDICES=""
REPLICAS="1"
ALIAS_INDEX=""
DELETE_PATTERN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) ACTION=list; shift ;;
    --show) ACTION=show; SNAPSHOT="${2:-}"; shift 2 ;;
    --restore) ACTION=restore; SNAPSHOT="${2:-}"; shift 2 ;;
    --indices) INDICES="${2:-}"; shift 2 ;;
    --replicas) REPLICAS="${2:-}"; shift 2 ;;
    --alias-add) ACTION=alias; ALIAS_INDEX="${2:-}"; shift 2 ;;
    --delete-restored) ACTION=delete; DELETE_PATTERN="${2:-}"; shift 2 ;;
    --snapshot-now) ACTION=snapnow; shift ;;
    -h|--help) usage ;;
    *) err "Unknown arg: $1"; usage ;;
  esac
done

[[ -n "${ACTION}" ]] || usage

case "${ACTION}" in
  list)
    log "Snapshots in ${SNAPSHOT_REPO_NAME}:"
    curl_idx GET "/_cat/snapshots/${SNAPSHOT_REPO_NAME}?v&s=start_epoch"
    ;;
  show)
    [[ -n "${SNAPSHOT}" ]] || die "snapshot name required"
    curl_idx GET "/_snapshot/${SNAPSHOT_REPO_NAME}/${SNAPSHOT}" | jq .
    ;;
  restore)
    [[ -n "${SNAPSHOT}" && -n "${INDICES}" ]] || die "--restore needs snapshot and --indices"
    log "Restoring ${INDICES} from ${SNAPSHOT} with prefix restore- (replicas=${REPLICAS})"
    body=$(jq -n --arg idx "${INDICES}" --argjson rep "${REPLICAS}" \
      '{
        indices: $idx,
        ignore_unavailable: true,
        include_global_state: false,
        rename_pattern: "(.+)",
        rename_replacement: "restore-$1",
        index_settings: {"index.number_of_replicas": $rep}
      }')
    echo "${body}" | curl_idx POST "/_snapshot/${SNAPSHOT_REPO_NAME}/${SNAPSHOT}/_restore?wait_for_completion=false" -d @-
    log "Restore started. Watch: curl ... /_cat/recovery?v"
    curl_idx GET "/_cat/recovery?v&active_only=true" || true
    ;;
  alias)
    [[ -n "${ALIAS_INDEX}" ]] || die "index required"
    body=$(jq -n --arg i "${ALIAS_INDEX}" '{actions:[{add:{index:$i, alias:"wazuh-alerts-archive-view"}}]}')
    echo "${body}" | curl_idx POST "/_aliases" -d @-
    log "Alias wazuh-alerts-archive-view -> ${ALIAS_INDEX}"
    ;;
  delete)
    [[ -n "${DELETE_PATTERN}" ]] || die "pattern required"
    [[ "${DELETE_PATTERN}" == restore-* ]] || die "Refusing to delete pattern not starting with restore-"
    log "Deleting ${DELETE_PATTERN}"
    curl_idx DELETE "/${DELETE_PATTERN}"
    ;;
  snapnow)
    local_name="manual-$(date +%Y%m%d-%H%M%S)"
    body='{"indices":"wazuh-alerts-*,wazuh-archives-*","include_global_state":false}'
    echo "${body}" | curl_idx PUT "/_snapshot/${SNAPSHOT_REPO_NAME}/${local_name}?wait_for_completion=false" -d @-
    log "Snapshot ${local_name} requested"
    ;;
esac
