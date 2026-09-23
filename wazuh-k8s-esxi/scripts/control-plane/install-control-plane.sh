#!/usr/bin/env bash
# Idempotent install: Kubernetes control-plane (kubeadm) for Wazuh package
# Target OS: RED OS 8 | Astra Linux | Ubuntu 22.04 — bare metal / empty VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config
require_root

log "=== Wazuh K8s: Control-Plane install on $(hostname) ==="

preflight() {
  check_supported_os
  bootstrap_host_tools
  configure_selinux
  check_cpu "${MIN_CPU_CP}"
  check_ram_gb "${MIN_RAM_GB_CP}"
  check_disk_free / "${MIN_DISK_GB_OS}"
  assert_port_free_or_k8s 6443
  for p in 10250 2379 2380; do
    if ! check_port_free "${p}"; then
      if [[ -f /etc/kubernetes/admin.conf ]]; then
        warn "Port ${p} in use (OK if control-plane already running)"
      else
        die "Port ${p} is already in use"
      fi
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
  if [[ -d /var/lib/containerd ]]; then
    check_disk_free /var/lib/containerd "${MIN_DISK_GB_CONTAINER}"
  fi
  open_firewall_ports control-plane
}

kubeadm_init() {
  if [[ -f /etc/kubernetes/admin.conf ]]; then
    log "admin.conf exists — skip kubeadm init"
    return 0
  fi
  cat >/tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v$(_k8s_semver)
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
  local join_cmd
  join_cmd="$(kubeadm token create --print-join-command)"
  echo "${join_cmd}" | tee -a "${LOG_FILE}"
  # Helper: extract token and hash for cluster.env
  local token hash
  token="$(echo "${join_cmd}" | awk '{for(i=1;i<=NF;i++) if($i=="--token") print $(i+1)}')"
  hash="$(echo "${join_cmd}" | awk '{for(i=1;i<=NF;i++) if($i=="--discovery-token-ca-cert-hash") print $(i+1)}')"
  log "Suggested cluster.env lines:"
  log "  KUBEADM_TOKEN=${token}"
  log "  KUBEADM_HASH=${hash}"
  log "================================================================="
}

# --- main ---
preflight
setup_disks
install_containerd_runtime
install_kubernetes_pkgs
kubeadm_init
setup_kubeconfig
install_cni
create_wazuh_ns
print_join
log "Control-plane install finished successfully (OS=${OS_ID})"
