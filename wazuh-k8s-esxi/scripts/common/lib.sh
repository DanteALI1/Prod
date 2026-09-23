#!/usr/bin/env bash
# Shared helpers for wazuh-k8s-esxi install scripts. Source only — do not execute.
# shellcheck disable=SC2034,SC2155

set -o errtrace

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "${_LIB_DIR}/../.." && pwd)"

load_config() {
  local candidates=(
    "${WAZUH_K8S_ENV:-}"
    "${_ROOT_DIR}/config/cluster.env"
    "/etc/wazuh-k8s/cluster.env"
    "$(pwd)/config/cluster.env"
  )
  local loaded=false
  for f in "${candidates[@]}"; do
    [[ -z "${f}" ]] && continue
    if [[ -f "${f}" ]]; then
      # shellcheck source=/dev/null
      source "${f}"
      loaded=true
      echo "[INFO] Loaded config: ${f}"
      break
    fi
  done
  if [[ "${loaded}" != "true" ]]; then
    echo "[WARN] No cluster.env found; using script defaults / environment"
  fi
  mkdir -p "${LOG_DIR:-/var/log/wazuh-k8s-install}"
  touch "${LOG_FILE:-/var/log/wazuh-k8s-install/install.log}"
}

log()  { local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO]  $*"; echo "${msg}" | tee -a "${LOG_FILE}"; }
warn() { local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [WARN]  $*"; echo "${msg}" | tee -a "${LOG_FILE}" >&2; }
err()  { local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ERROR] $*"; echo "${msg}" | tee -a "${LOG_FILE}" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

check_ubuntu_2204() {
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS (/etc/os-release missing)"
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  if [[ "${ID}" != "ubuntu" ]] || [[ "${VERSION_ID}" != "22.04" ]]; then
    die "Unsupported OS: ${PRETTY_NAME:-unknown}. Target is Ubuntu 22.04 LTS."
  fi
  log "OS OK: ${PRETTY_NAME}"
}

check_cpu() {
  local min="$1"
  local have
  have="$(nproc)"
  if (( have < min )); then
    die "CPU check failed: have ${have} vCPU, need >= ${min}"
  fi
  log "CPU OK: ${have} vCPU (min ${min})"
}

check_ram_gb() {
  local min_gb="$1"
  local have_kb have_gb
  have_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  have_gb=$(( have_kb / 1024 / 1024 ))
  if (( have_gb < min_gb )); then
    die "RAM check failed: have ~${have_gb} GiB, need >= ${min_gb} GiB"
  fi
  log "RAM OK: ~${have_gb} GiB (min ${min_gb} GiB)"
}

disk_free_gb() {
  local path="${1:-/}"
  df -BG --output=avail "${path}" 2>/dev/null | tail -1 | tr -dc '0-9'
}

check_disk_free() {
  local path="$1"
  local min_gb="$2"
  local have
  have="$(disk_free_gb "${path}")"
  [[ -n "${have}" ]] || die "Cannot determine free space on ${path}"
  if (( have < min_gb )); then
    die "Disk check failed on ${path}: ${have} GiB free, need >= ${min_gb} GiB"
  fi
  log "Disk OK: ${path} has ${have} GiB free (min ${min_gb} GiB)"
}

check_port_free() {
  local port="$1"
  if ss -lntu | awk '{print $5}' | grep -Eq "[:.]${port}\$"; then
    die "Port ${port} is already in use"
  fi
  log "Port ${port} is free"
}

check_port_reachable() {
  local host="$1"
  local port="$2"
  local timeout="${3:-5}"
  if timeout "${timeout}" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
    log "Reachable: ${host}:${port}"
    return 0
  fi
  warn "Not reachable: ${host}:${port}"
  return 1
}

disable_swap() {
  if [[ "${SWAP_ENABLED}" == "true" ]]; then
    warn "SWAP_ENABLED=true — leaving swap as-is (not recommended for K8s)"
    return 0
  fi
  swapoff -a || true
  if grep -Eq '^\s*[^#].+\s+swap\s' /etc/fstab; then
    sed -ri 's/^(\s*[^#].+\s+swap\s)/#\1/' /etc/fstab
    log "Commented swap entries in /etc/fstab"
  fi
  log "Swap disabled"
}

ensure_kernel_modules() {
  modprobe overlay
  modprobe br_netfilter
  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
vm.max_map_count                    = 262144
fs.file-max                         = 65536
EOF
  sysctl --system >/dev/null
  log "Kernel modules and sysctl applied (incl. vm.max_map_count=262144 for OpenSearch)"
}

idempotent_apt_update() {
  apt-get update -y
}

install_packages() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# Create LVM VG/LV and mount if disk present and not already mounted.
# Args: device mountpoint vg_name lv_name fstype mount_opts
setup_lvm_mount() {
  local device="$1"
  local mountpoint="$2"
  local vg_name="$3"
  local lv_name="$4"
  local fstype="${5:-xfs}"
  local opts="${6:-defaults,noatime,nodiratime}"

  if [[ -z "${device}" ]]; then
    warn "No device specified for ${mountpoint}; skipping LVM setup"
    return 0
  fi
  if [[ ! -b "${device}" ]]; then
    die "Block device not found: ${device}"
  fi

  require_cmd pvcreate
  require_cmd vgcreate
  require_cmd lvcreate
  require_cmd mkfs.${fstype}

  mkdir -p "${mountpoint}"

  if findmnt -n "${mountpoint}" >/dev/null 2>&1; then
    log "Already mounted: ${mountpoint}"
    return 0
  fi

  if ! pvs "${device}" >/dev/null 2>&1; then
    wipefs -a "${device}" || true
    pvcreate -ff -y "${device}"
  else
    log "PV already exists on ${device}"
  fi

  if ! vgs "${vg_name}" >/dev/null 2>&1; then
    vgcreate "${vg_name}" "${device}"
  else
    log "VG ${vg_name} already exists"
  fi

  if ! lvs "${vg_name}/${lv_name}" >/dev/null 2>&1; then
    lvcreate -n "${lv_name}" -l 100%FREE "${vg_name}"
  else
    log "LV ${vg_name}/${lv_name} already exists"
  fi

  local mapper="/dev/${vg_name}/${lv_name}"
  if ! blkid "${mapper}" >/dev/null 2>&1; then
    if [[ "${fstype}" == "xfs" ]]; then
      mkfs.xfs -f "${mapper}"
    else
      mkfs.ext4 -F "${mapper}"
    fi
  fi

  local uuid
  uuid="$(blkid -s UUID -o value "${mapper}")"
  if ! grep -q "${uuid}" /etc/fstab; then
    echo "UUID=${uuid} ${mountpoint} ${fstype} ${opts} 0 2" >>/etc/fstab
  fi
  mount "${mountpoint}"
  log "Mounted ${mapper} -> ${mountpoint} (${fstype}, ${opts})"
}

generate_cluster_key() {
  if [[ -z "${WAZUH_CLUSTER_KEY}" ]]; then
    WAZUH_CLUSTER_KEY="$(openssl rand -hex 16)"
    export WAZUH_CLUSTER_KEY
    log "Generated WAZUH_CLUSTER_KEY"
  fi
}

run_or_dry() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY_RUN: $*"
  else
    log "EXEC: $*"
    "$@"
  fi
}

mark_done() {
  local stamp_dir="/var/lib/wazuh-k8s-install"
  mkdir -p "${stamp_dir}"
  touch "${stamp_dir}/$1.done"
  log "Marked complete: $1"
}

already_done() {
  [[ -f "/var/lib/wazuh-k8s-install/$1.done" ]]
}
