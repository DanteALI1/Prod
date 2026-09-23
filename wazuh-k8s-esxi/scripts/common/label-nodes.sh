#!/usr/bin/env bash
# Run on control-plane after all nodes joined: apply role labels and indexer taints
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib.sh"
load_config

if [[ -z "${KUBECONFIG:-}" && -f /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi
require_cmd kubectl

log "Labeling workers: ${WORKER_HOSTS}"
for h in ${WORKER_HOSTS}; do
  kubectl label node "${h}" node-role.kubernetes.io/worker= wazuh.role=general --overwrite \
    || warn "Cannot label ${h} — check node name"
done

log "Labeling + tainting indexers: ${INDEXER_HOSTS}"
for h in ${INDEXER_HOSTS}; do
  kubectl label node "${h}" node-role.kubernetes.io/worker= wazuh.role=indexer --overwrite \
    || warn "Cannot label ${h}"
  kubectl taint nodes "${h}" wazuh-indexer=true:NoSchedule --overwrite \
    || warn "Cannot taint ${h}"
done

kubectl get nodes -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.wazuh\\.role,TAINTS:.spec.taints
log "Done"
