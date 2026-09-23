#!/usr/bin/env bash
# Idempotent install: Kubernetes worker node for Wazuh Manager/Dashboard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config
require_root

log "=== Wazuh K8s: Worker install on $(hostname) ==="

preflight() {
  check_ubuntu_2204
  check_cpu "${MIN_CPU_WORKER}"
  check_ram_gb "${MIN_RAM_GB_WORKER}"
  check_disk_free / "${MIN_DISK_GB_OS}"
  [[ -n "${KUBEADM_TOKEN}" ]] || die "KUBEADM_TOKEN is empty — set in cluster.env"
  [[ -n "${KUBEADM_HASH}" ]] || die "KUBEADM_HASH is empty — set in cluster.env"
  check_port_reachable "${CP_IP}" 6443 || die "Cannot reach control-plane ${CP_IP}:6443"
}

setup_disks() {
  install_packages lvm2 xfsprogs e2fsprogs curl apt-transport-https ca-certificates gnupg jq
  disable_swap
  ensure_kernel_modules
  setup_lvm_mount "${CONTAINER_DISK}" /var/lib/containerd vg_container lv_containerd ext4 "defaults,noatime"
  check_disk_free /var/lib/containerd 80
}

install_containerd() {
  if already_done containerd; then
    systemctl enable --now containerd
    return 0
  fi
  install_packages containerd
  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl enable --now containerd
  mark_done containerd
}

install_k8s_packages() {
  if already_done k8s-pkgs; then
    return 0
  fi
  local ver_minor
  ver_minor="$(echo "${K8S_VERSION}" | cut -d. -f1,2)"
  mkdir -p /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${ver_minor}/deb/Release.key" \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  fi
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${ver_minor}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  idempotent_apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "kubelet=${K8S_VERSION}" "kubeadm=${K8S_VERSION}" "kubectl=${K8S_VERSION}"
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable --now kubelet
  mark_done k8s-pkgs
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
install_containerd
install_k8s_packages
kubeadm_join
prepare_manager_dirs
label_hint
log "Worker install finished — label node from CP if needed"
