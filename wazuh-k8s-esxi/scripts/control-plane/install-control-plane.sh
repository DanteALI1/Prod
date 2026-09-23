#!/usr/bin/env bash
# Idempotent install: Kubernetes control-plane (kubeadm) for Wazuh package
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config
require_root

log "=== Wazuh K8s: Control-Plane install on $(hostname) ==="

preflight() {
  check_ubuntu_2204
  check_cpu "${MIN_CPU_CP}"
  check_ram_gb "${MIN_RAM_GB_CP}"
  check_disk_free / "${MIN_DISK_GB_OS}"
  for p in 6443 10250 2379 2380; do
    check_port_free "${p}" || true
  done
  # 6443 must be free before first init
  if ss -lnt | grep -q ':6443'; then
    if [[ -f /etc/kubernetes/admin.conf ]]; then
      log "API already listening — assuming control-plane exists"
    else
      die "Port 6443 in use but admin.conf missing"
    fi
  fi
}

setup_disks() {
  install_packages lvm2 xfsprogs e2fsprogs curl apt-transport-https ca-certificates gnupg lsb-release jq
  disable_swap
  ensure_kernel_modules
  setup_lvm_mount "${CONTAINER_DISK}" /var/lib/containerd vg_container lv_containerd ext4 "defaults,noatime"
  check_disk_free /var/lib/containerd "${MIN_DISK_GB_CONTAINER}"
}

install_containerd() {
  if already_done containerd; then
    log "containerd stamp present — skip install"
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
    log "k8s packages stamp present"
    return 0
  fi
  # Kubernetes apt repo (pkgs.k8s.io)
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

kubeadm_init() {
  if [[ -f /etc/kubernetes/admin.conf ]]; then
    log "admin.conf exists — skip kubeadm init"
    return 0
  fi
  cat >/tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v$(echo "${K8S_VERSION}" | cut -d- -f1)
controlPlaneEndpoint: "${CONTROL_PLANE_ENDPOINT}"
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${CP_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: "$(hostname)"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
  run_or_dry kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs
  mark_done kubeadm-init
}

setup_kubeconfig() {
  mkdir -p /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local home
    home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    mkdir -p "${home}/.kube"
    cp -f /etc/kubernetes/admin.conf "${home}/.kube/config"
    chown -R "${SUDO_USER}:${SUDO_USER}" "${home}/.kube"
  fi
  export KUBECONFIG=/etc/kubernetes/admin.conf
  log "kubeconfig installed"
}

install_cni() {
  export KUBECONFIG=/etc/kubernetes/admin.conf
  if already_done cni; then
    log "CNI stamp present"
    return 0
  fi
  case "${CNI_PLUGIN}" in
    calico)
      kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/calico.yaml
      ;;
    cilium)
      install_packages helm || true
      if ! command -v helm >/dev/null; then
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
      fi
      helm repo add cilium https://helm.cilium.io/ || true
      helm repo update
      helm upgrade --install cilium cilium/cilium --namespace kube-system \
        --set ipam.mode=kubernetes \
        --set kubeProxyReplacement=false
      ;;
    *)
      die "Unknown CNI_PLUGIN=${CNI_PLUGIN}"
      ;;
  esac
  mark_done cni
}

create_wazuh_ns() {
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl get ns "${WAZUH_NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${WAZUH_NAMESPACE}"
  log "Namespace ${WAZUH_NAMESPACE} ready"
}

print_join() {
  export KUBECONFIG=/etc/kubernetes/admin.conf
  log "===== SAVE THIS JOIN COMMAND INTO cluster.env (TOKEN + HASH) ====="
  kubeadm token create --print-join-command | tee -a "${LOG_FILE}"
  log "================================================================="
}

# --- main ---
preflight
setup_disks
install_containerd
install_k8s_packages
kubeadm_init
setup_kubeconfig
install_cni
create_wazuh_ns
print_join
log "Control-plane install finished successfully"
