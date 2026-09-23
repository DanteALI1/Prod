#!/usr/bin/env bash
# Deploy Wazuh Indexer + Manager into the cluster (run on CP / admin host)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config

BACKUP_ONLY=false
for arg in "$@"; do
  case "${arg}" in
    --backup-only) BACKUP_ONLY=true ;;
  esac
done

require_root_or_kube() {
  if [[ "${EUID}" -ne 0 && ! -f "${KUBECONFIG:-}" && ! -f /etc/kubernetes/admin.conf && ! -f "${HOME}/.kube/config" ]]; then
    die "Need root or valid kubeconfig"
  fi
  if [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -f /etc/kubernetes/admin.conf ]]; then
      export KUBECONFIG=/etc/kubernetes/admin.conf
    elif [[ -f "${HOME}/.kube/config" ]]; then
      export KUBECONFIG="${HOME}/.kube/config"
    fi
  fi
  require_cmd kubectl
}

preflight() {
  kubectl cluster-info >/dev/null || die "kubectl cannot reach cluster"
  local idx_count
  idx_count="$(kubectl get nodes -l wazuh.role=indexer --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if (( idx_count < 3 )); then
    die "Need 3 nodes labeled wazuh.role=indexer (have ${idx_count}). Label/taint indexer nodes first."
  fi
  local wrk
  wrk="$(kubectl get nodes -l wazuh.role=general --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if (( wrk < 1 )); then
    warn "No nodes with wazuh.role=general — labeling all non-indexer workers"
    kubectl get nodes -o name | while read -r n; do
      n="${n#node/}"
      if ! kubectl get node "${n}" -o jsonpath='{.metadata.labels.wazuh\.role}' 2>/dev/null | grep -q indexer; then
        if [[ "${n}" != "$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]]; then
          kubectl label node "${n}" wazuh.role=general --overwrite || true
        fi
      fi
    done
  fi
  kubectl get ns "${WAZUH_NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${WAZUH_NAMESPACE}"
  generate_cluster_key
  log "Preflight OK (indexer nodes=${idx_count})"
}

ensure_helm() {
  if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  require_cmd helm
}

apply_storage() {
  log "Applying StorageClass / PV manifests"
  kubectl apply -f "${ROOT_DIR}/manifests/storage/"
}

create_secrets() {
  if kubectl -n "${WAZUH_NAMESPACE}" get secret wazuh-credentials >/dev/null 2>&1; then
    log "Secret wazuh-credentials exists — skip create"
  else
    kubectl -n "${WAZUH_NAMESPACE}" create secret generic wazuh-credentials \
      --from-literal=indexer-user="${INDEXER_ADMIN_USER}" \
      --from-literal=indexer-password="${INDEXER_ADMIN_PASSWORD}" \
      --from-literal=api-user="${WAZUH_API_USER}" \
      --from-literal=api-password="${WAZUH_API_PASSWORD}" \
      --from-literal=dashboard-password="${DASHBOARD_PASSWORD}" \
      --from-literal=cluster-key="${WAZUH_CLUSTER_KEY}"
  fi
}

render_and_apply_manifests() {
  local out="${ROOT_DIR}/manifests/.rendered"
  mkdir -p "${out}"
  # shellcheck disable=SC2016
  for f in \
    "${ROOT_DIR}/manifests/indexer/statefulset-indexer.yaml" \
    "${ROOT_DIR}/manifests/manager/statefulset-manager-master.yaml" \
    "${ROOT_DIR}/manifests/manager/statefulset-manager-worker.yaml" \
    "${ROOT_DIR}/manifests/manager/services.yaml"
  do
    [[ -f "${f}" ]] || die "Missing manifest ${f}"
    local base
    base="$(basename "${f}")"
    sed \
      -e "s|__NAMESPACE__|${WAZUH_NAMESPACE}|g" \
      -e "s|__WAZUH_VERSION__|${WAZUH_VERSION}|g" \
      -e "s|__CLUSTER_KEY__|${WAZUH_CLUSTER_KEY}|g" \
      -e "s|__INDEXER_PASSWORD__|${INDEXER_ADMIN_PASSWORD}|g" \
      -e "s|__API_PASSWORD__|${WAZUH_API_PASSWORD}|g" \
      "${f}" >"${out}/${base}"
    kubectl apply -f "${out}/${base}"
  done
}

deploy_via_official_repo() {
  # Prefer official wazuh-kubernetes checkout + our values overlay when network allows
  local work="/var/tmp/wazuh-kubernetes"
  if [[ ! -d "${work}/.git" ]]; then
    git clone --depth 1 --branch "${WAZUH_K8S_TAG}" "${WAZUH_K8S_GIT}" "${work}" \
      || warn "Clone failed — falling back to local manifests only"
  fi
  if [[ -d "${work}/envs/single-node" ]] || [[ -d "${work}/wazuh" ]]; then
    log "Official repo present at ${work} — apply local hardened manifests (StatefulSets) which pin nodeSelector/taints"
  fi
  apply_storage
  create_secrets
  render_and_apply_manifests
}

wait_ready() {
  log "Waiting for Indexer pods..."
  kubectl -n "${WAZUH_NAMESPACE}" rollout status statefulset/wazuh-indexer --timeout=600s || die "Indexer not Ready"
  log "Waiting for Manager master..."
  kubectl -n "${WAZUH_NAMESPACE}" rollout status statefulset/wazuh-manager-master --timeout=600s || die "Manager master not Ready"
  log "Waiting for Manager worker..."
  kubectl -n "${WAZUH_NAMESPACE}" rollout status statefulset/wazuh-manager-worker --timeout=600s || warn "Manager worker not Ready yet"
}

backup_manager_config() {
  local dest="${1:-/var/backups/wazuh}"
  mkdir -p "${dest}"
  local ts file
  ts="$(date +%Y%m%d-%H%M%S)"
  file="${dest}/wazuh-manager-conf-${ts}.tgz"
  local pod
  pod="$(kubectl -n "${WAZUH_NAMESPACE}" get pods -l app=wazuh-manager,node-type=master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${pod}" ]] || pod="$(kubectl -n "${WAZUH_NAMESPACE}" get pods -o name | grep manager-master | head -1 | cut -d/ -f2)"
  [[ -n "${pod}" ]] || die "Manager master pod not found"
  kubectl -n "${WAZUH_NAMESPACE}" exec "${pod}" -- \
    tar czf - /var/ossec/etc/rules /var/ossec/etc/decoders /var/ossec/etc/shared /var/ossec/etc/ossec.conf \
    >/tmp/_wazuh_bk.tgz 2>/dev/null || \
  kubectl -n "${WAZUH_NAMESPACE}" exec "${pod}" -- \
    sh -c 'tar czf - /var/ossec/etc/rules /var/ossec/etc/decoders /var/ossec/etc/shared /var/ossec/etc/ossec.conf' \
    >"${file}"
  if [[ -f /tmp/_wazuh_bk.tgz ]]; then
    mv /tmp/_wazuh_bk.tgz "${file}"
  fi
  log "Backup written: ${file}"
}

# --- main ---
require_root_or_kube
if [[ "${BACKUP_ONLY}" == "true" ]]; then
  backup_manager_config
  exit 0
fi
preflight
ensure_helm
deploy_via_official_repo
wait_ready
backup_manager_config
log "Manager + Indexer deploy finished"
log "Next: scripts/dashboard/install-dashboard.sh && scripts/archiving/setup-archiving.sh"
