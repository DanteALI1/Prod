#!/usr/bin/env bash
# Idempotent install: dedicated Indexer Kubernetes node (join + data disk)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config
require_root

log "=== Wazuh K8s: Indexer node install on $(hostname) ==="

preflight() {
  check_ubuntu_2204
  check_cpu "${MIN_CPU_INDEXER}"
  check_ram_gb "${MIN_RAM_GB_INDEXER}"
  check_disk_free / "${MIN_DISK_GB_OS}"
  [[ -n "${KUBEADM_TOKEN}" ]] || die "KUBEADM_TOKEN empty"
  [[ -n "${KUBEADM_HASH}" ]] || die "KUBEADM_HASH empty"
  [[ -n "${INDEXER_DATA_DISK}" ]] || die "INDEXER_DATA_DISK must be set (e.g. /dev/sdc)"
  check_port_reachable "${CP_IP}" 6443 || die "CP ${CP_IP}:6443 unreachable"
  for p in 9200 9300; do
    if ss -lnt | grep -q ":${p}"; then
      warn "Port ${p} already listening (OK if indexer pod running)"
    fi
  done
}

setup_disks() {
  install_packages lvm2 xfsprogs e2fsprogs curl apt-transport-https ca-certificates gnupg jq
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
  fi
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
  log "================================="
}

preflight
setup_disks
install_containerd
install_k8s_packages
kubeadm_join
print_scheduling
log "Indexer node host prep finished"
