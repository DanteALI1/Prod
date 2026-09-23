#!/usr/bin/env bash
# Deploy Wazuh Dashboard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config

if [[ -z "${KUBECONFIG:-}" ]]; then
  [[ -f /etc/kubernetes/admin.conf ]] && export KUBECONFIG=/etc/kubernetes/admin.conf
fi
require_cmd kubectl

log "=== Wazuh Dashboard deploy ==="

preflight() {
  kubectl -n "${WAZUH_NAMESPACE}" get sts wazuh-indexer >/dev/null \
    || die "Indexer StatefulSet missing — run install-manager.sh first"
  local ready
  ready="$(kubectl -n "${WAZUH_NAMESPACE}" get sts wazuh-indexer -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${ready}" != "3" ]]; then
    warn "Indexer readyReplicas=${ready} (want 3) — continuing but Dashboard may be red"
  fi
}

apply() {
  local out="${ROOT_DIR}/manifests/.rendered"
  mkdir -p "${out}"
  sed \
    -e "s|__NAMESPACE__|${WAZUH_NAMESPACE}|g" \
    -e "s|__WAZUH_VERSION__|${WAZUH_VERSION}|g" \
    -e "s|__DASHBOARD_PASSWORD__|${DASHBOARD_PASSWORD}|g" \
    -e "s|__INDEXER_PASSWORD__|${INDEXER_ADMIN_PASSWORD}|g" \
    "${ROOT_DIR}/manifests/dashboard/deployment-dashboard.yaml" >"${out}/deployment-dashboard.yaml"
  kubectl apply -f "${out}/deployment-dashboard.yaml"
}

wait_ready() {
  kubectl -n "${WAZUH_NAMESPACE}" rollout status deployment/wazuh-dashboard --timeout=300s \
    || die "Dashboard not Available"
  kubectl -n "${WAZUH_NAMESPACE}" get svc wazuh-dashboard -o wide
  log "Dashboard deployed. Example: kubectl -n ${WAZUH_NAMESPACE} port-forward svc/wazuh-dashboard 8443:443"
}

preflight
apply
wait_ready
log "Dashboard install finished"
