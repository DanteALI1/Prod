#!/usr/bin/env bash
# Idempotent install: Kubernetes worker node for Wazuh Manager/Dashboard
# Target OS: RED OS 8 | Astra Linux | Ubuntu 22.04 — bare metal / empty VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config
require_root

log "=== Wazuh K8s: Worker install on $(hostname) ==="

preflight() {
  check_supported_os
  bootstrap_host_tools
  configure_selinux
  check_cpu "${MIN_CPU_WORKER}"
  check_ram_gb "${MIN_RAM_GB_WORKER}"
  check_disk_free / "${MIN_DISK_GB_OS}"
  [[ -n "${KUBEADM_TOKEN:-}" ]] || die "KUBEADM_TOKEN is empty — set in cluster.env after CP install"
  [[ -n "${KUBEADM_HASH:-}" ]] || die "KUBEADM_HASH is empty — set in cluster.env (sha256:...)"
  normalize_kubeadm_hash
  check_port_reachable "${CP_IP}" 6443 || die "Cannot reach control-plane ${CP_IP}:6443"
}

setup_disks() {
  local pkgs
  pkgs="$(resolve_pkg_list lvm2 xfsprogs e2fsprogs)"
  # shellcheck disable=SC2086
  install_packages ${pkgs}
  disable_swap
  ensure_kernel_modules
  setup_lvm_mount "${CONTAINER_DISK}" /var/lib/containerd vg_container lv_containerd ext4 "defaults,noatime"
  if [[ -d /var/lib/containerd ]]; then
    check_disk_free /var/lib/containerd 80
  fi
  open_firewall_ports worker
}

kubeadm_join() {
  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    log "Already joined cluster"
    return 0
  fi
  run_or_dry kubeadm join "${CONTROL_PLANE_ENDPOINT}" \
    --token "${KUBEADM_TOKEN}" \
    --discovery-token-ca-cert-hash "${KUBEADM_HASH}" \
    --cri-socket unix:///run/containerd/containerd.sock
  mark_done kubeadm-join
}

prepare_manager_dirs() {
  # Local paths used by manifests/storage/pv-manager-lab.yaml
  mkdir -p /var/lib/wazuh-manager/{master-data,master-etc,worker-data}
  chmod 755 /var/lib/wazuh-manager
  log "Prepared /var/lib/wazuh-manager/* for lab PVs"
}

label_hint() {
  log "After ALL nodes joined, from control-plane run:"
  log "  sudo -E bash scripts/common/label-nodes.sh"
  log "Or manually:"
  log "  kubectl label node $(hostname) node-role.kubernetes.io/worker= wazuh.role=general --overwrite"
}

preflight
setup_disks
install_containerd_runtime
install_kubernetes_pkgs
kubeadm_join
prepare_manager_dirs
label_hint
log "Worker install finished — label node from CP if needed (OS=${OS_ID})"
