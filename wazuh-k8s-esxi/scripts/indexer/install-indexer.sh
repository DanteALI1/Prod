#!/usr/bin/env bash
# Idempotent install: dedicated Indexer Kubernetes node (join + data disk)
# Target OS: RED OS 8 | Astra Linux | Ubuntu 22.04 — bare metal / empty VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config
require_root

log "=== Wazuh K8s: Indexer node install on $(hostname) ==="

preflight() {
  check_supported_os
  bootstrap_host_tools
  configure_selinux
  check_cpu "${MIN_CPU_INDEXER}"
  check_ram_gb "${MIN_RAM_GB_INDEXER}"
  check_disk_free / "${MIN_DISK_GB_OS}"
  [[ -n "${KUBEADM_TOKEN:-}" ]] || die "KUBEADM_TOKEN empty"
  [[ -n "${KUBEADM_HASH:-}" ]] || die "KUBEADM_HASH empty"
  normalize_kubeadm_hash
  [[ -n "${INDEXER_DATA_DISK:-}" ]] || die "INDEXER_DATA_DISK must be set (e.g. /dev/sdc)"
  check_port_reachable "${CP_IP}" 6443 || die "CP ${CP_IP}:6443 unreachable"
  for p in 9200 9300; do
    if ! check_port_free "${p}"; then
      warn "Port ${p} already listening (OK if indexer pod running)"
    fi
  done
}

setup_disks() {
  local pkgs
  pkgs="$(resolve_pkg_list lvm2 xfsprogs e2fsprogs)"
  # shellcheck disable=SC2086
  install_packages ${pkgs}
  disable_swap
  ensure_kernel_modules
  setup_lvm_mount "${CONTAINER_DISK}" /var/lib/containerd vg_container lv_containerd ext4 "defaults,noatime"
  setup_lvm_mount "${INDEXER_DATA_DISK}" /var/lib/wazuh-indexer vg_indexer lv_data xfs "defaults,noatime,nodiratime"
  # OpenSearch process in official images often runs as UID 1000
  chown -R 1000:1000 /var/lib/wazuh-indexer
  chmod 750 /var/lib/wazuh-indexer
  check_disk_free /var/lib/wazuh-indexer "${MIN_DISK_GB_INDEXER_DATA}"
  # Disable THP for better latency (best effort)
  if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo never >/sys/kernel/mm/transparent_hugepage/enabled || true
    echo never >/sys/kernel/mm/transparent_hugepage/defrag || true
    cat >/etc/tmpfiles.d/disable-thp.conf <<'EOF'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - never
w /sys/kernel/mm/transparent_hugepage/defrag - - - - never
EOF
  fi
  open_firewall_ports indexer
}

kubeadm_join() {
  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    log "Already joined"
    return 0
  fi
  run_or_dry kubeadm join "${CONTROL_PLANE_ENDPOINT}" \
    --token "${KUBEADM_TOKEN}" \
    --discovery-token-ca-cert-hash "${KUBEADM_HASH}" \
    --cri-socket unix:///run/containerd/containerd.sock
  mark_done kubeadm-join
}

print_scheduling() {
  local n
  n="$(hostname)"
  log "===== FROM CONTROL-PLANE RUN ====="
  log "kubectl label node ${n} wazuh.role=indexer node-role.kubernetes.io/worker= --overwrite"
  log "kubectl taint nodes ${n} wazuh-indexer=true:NoSchedule --overwrite"
  log "Or: sudo -E bash scripts/common/label-nodes.sh"
  log "================================="
}

preflight
setup_disks
install_containerd_runtime
install_kubernetes_pkgs
kubeadm_join
print_scheduling
log "Indexer node host prep finished (OS=${OS_ID})"
