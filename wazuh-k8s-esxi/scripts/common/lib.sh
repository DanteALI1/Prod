#!/usr/bin/env bash
# Shared helpers for wazuh-k8s-esxi install scripts. Source only — do not execute.
# Supports: RED OS 8 (rpm/dnf), Astra Linux (deb/apt), Ubuntu 22.04 (deb/apt).
# shellcheck disable=SC2034,SC2155

set -o errtrace

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "${_LIB_DIR}/../.." && pwd)"

# Detected at runtime by detect_os()
OS_FAMILY=""          # rpm | deb
OS_ID=""              # redos | astra | ubuntu | rhel | centos | rocky | almalinux | debian
OS_VERSION_ID=""
OS_PRETTY=""
PKG_MGR=""            # dnf | yum | apt

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
      set -a
      source "${f}"
      set +a
      loaded=true
      echo "[INFO] Loaded config: ${f}"
      break
    fi
  done
  if [[ "${loaded}" != "true" ]]; then
    echo "[WARN] No cluster.env found; using script defaults / environment"
  fi
  # Defaults needed before first log() when config is missing
  export LOG_DIR="${LOG_DIR:-/var/log/wazuh-k8s-install}"
  export LOG_FILE="${LOG_FILE:-${LOG_DIR}/install-$(date +%Y%m%d).log}"
  mkdir -p "${LOG_DIR}"
  touch "${LOG_FILE}"
  normalize_kubeadm_hash
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

# kubeadm expects discovery-token-ca-cert-hash as sha256:<hex>
normalize_kubeadm_hash() {
  if [[ -n "${KUBEADM_HASH:-}" && "${KUBEADM_HASH}" != sha256:* ]]; then
    export KUBEADM_HASH="sha256:${KUBEADM_HASH}"
    log "Normalized KUBEADM_HASH with sha256: prefix"
  fi
}

# -----------------------------------------------------------------------------
# OS detection — RED OS 8, Astra Linux, Ubuntu 22.04 (+ RHEL-like)
# -----------------------------------------------------------------------------
detect_os() {
  [[ -f /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)"
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-unknown}"

  # RED OS: ID=redos (sometimes redos or RED); also check /etc/red-release
  if [[ -f /etc/red-release ]] || [[ "${OS_ID}" == "redos" ]] || [[ "${OS_ID}" == "RED" ]] \
     || echo "${OS_PRETTY}" | grep -qiE 'red[[:space:]]*os|редос|ред ос'; then
    OS_ID="redos"
    OS_FAMILY="rpm"
  elif [[ "${OS_ID}" == "astra" ]] || echo "${OS_PRETTY}" | grep -qi 'astra'; then
    OS_ID="astra"
    OS_FAMILY="deb"
  elif [[ "${OS_ID}" == "ubuntu" ]]; then
    OS_FAMILY="deb"
  elif [[ "${OS_ID}" == "debian" ]]; then
    OS_FAMILY="deb"
  elif [[ "${OS_ID}" =~ ^(rhel|centos|rocky|almalinux|fedora|ol)$ ]]; then
    OS_FAMILY="rpm"
  else
    # Fallback: package manager presence
    if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
      OS_FAMILY="rpm"
    elif command -v apt-get >/dev/null 2>&1; then
      OS_FAMILY="deb"
    else
      die "Unsupported OS: ${OS_PRETTY}. Supported: RED OS 8, Astra Linux, Ubuntu 22.04."
    fi
  fi

  if [[ "${OS_FAMILY}" == "rpm" ]]; then
    if command -v dnf >/dev/null 2>&1; then
      PKG_MGR="dnf"
    else
      PKG_MGR="yum"
    fi
  else
    PKG_MGR="apt"
  fi

  # Optional override from cluster.env
  if [[ -n "${TARGET_OS:-}" ]]; then
    case "${TARGET_OS}" in
      redos|REDOS|red-os) OS_ID="redos"; OS_FAMILY="rpm"; PKG_MGR="${PKG_MGR:-dnf}" ;;
      astra|ASTRA) OS_ID="astra"; OS_FAMILY="deb"; PKG_MGR="apt" ;;
      ubuntu|UBUNTU) OS_ID="ubuntu"; OS_FAMILY="deb"; PKG_MGR="apt" ;;
    esac
  fi

  export OS_FAMILY OS_ID OS_VERSION_ID OS_PRETTY PKG_MGR
  log "OS detected: ${OS_PRETTY} (id=${OS_ID}, family=${OS_FAMILY}, pkg=${PKG_MGR})"
}

check_supported_os() {
  detect_os
  case "${OS_ID}" in
    redos)
      # Accept 7.x / 8.x
      log "Target OS OK: RED OS (${OS_VERSION_ID})"
      ;;
    astra)
      log "Target OS OK: Astra Linux (${OS_VERSION_ID})"
      ;;
    ubuntu)
      if [[ "${OS_VERSION_ID}" != "22.04" && "${OS_VERSION_ID}" != "24.04" ]]; then
        warn "Ubuntu ${OS_VERSION_ID} is not the primary target (22.04); continuing"
      fi
      log "Target OS OK: Ubuntu ${OS_VERSION_ID}"
      ;;
    rhel|centos|rocky|almalinux)
      warn "RHEL-like ${OS_ID} ${OS_VERSION_ID}: scripts use RED OS (rpm) path"
      ;;
    debian)
      warn "Debian ${OS_VERSION_ID}: scripts use Astra/deb path"
      ;;
    *)
      if [[ "${ALLOW_UNSUPPORTED_OS:-false}" == "true" ]]; then
        warn "Unsupported OS ${OS_PRETTY} — ALLOW_UNSUPPORTED_OS=true, continuing"
      else
        die "Unsupported OS: ${OS_PRETTY}. Set TARGET_OS=redos|astra|ubuntu or ALLOW_UNSUPPORTED_OS=true"
      fi
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Package management (bare metal / from scratch)
# -----------------------------------------------------------------------------
pkg_update() {
  case "${PKG_MGR}" in
    dnf) run_or_dry dnf -y makecache ;;
    yum) run_or_dry yum -y makecache ;;
    apt)
      run_or_dry apt-get update -y
      ;;
    *) die "Unknown PKG_MGR=${PKG_MGR}" ;;
  esac
}

install_packages() {
  [[ $# -gt 0 ]] || return 0
  case "${PKG_MGR}" in
    dnf) run_or_dry dnf -y install "$@" ;;
    yum) run_or_dry yum -y install "$@" ;;
    apt)
      run_or_dry env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    *) die "Unknown PKG_MGR=${PKG_MGR}" ;;
  esac
}

# Map logical package names to OS-specific packages
resolve_pkg_list() {
  local out=()
  local p
  for p in "$@"; do
    case "${p}" in
      curl)
        out+=(curl) ;;
      ca-certificates)
        if [[ "${OS_FAMILY}" == "rpm" ]]; then out+=(ca-certificates); else out+=(ca-certificates); fi ;;
      gnupg)
        if [[ "${OS_FAMILY}" == "rpm" ]]; then out+=(gnupg2); else out+=(gnupg); fi ;;
      jq)
        out+=(jq) ;;
      lvm2)
        out+=(lvm2) ;;
      xfsprogs)
        out+=(xfsprogs) ;;
      e2fsprogs)
        out+=(e2fsprogs) ;;
      iproute)
        if [[ "${OS_FAMILY}" == "rpm" ]]; then out+=(iproute); else out+=(iproute2); fi ;;
      iptables)
        out+=(iptables) ;;
      openssl)
        out+=(openssl) ;;
      tar)
        out+=(tar) ;;
      wget)
        out+=(wget) ;;
      tar-extra)
        ;; # noop placeholder
      yum-utils|dnf-plugins)
        if [[ "${OS_FAMILY}" == "rpm" ]]; then
          if [[ "${PKG_MGR}" == "dnf" ]]; then out+=(dnf-plugins-core); else out+=(yum-utils); fi
        fi
        ;;
      apt-transport-https)
        if [[ "${OS_FAMILY}" == "deb" ]]; then out+=(apt-transport-https); fi ;;
      lsb-release)
        if [[ "${OS_FAMILY}" == "deb" ]]; then out+=(lsb-release); fi ;;
      conntrack)
        if [[ "${OS_FAMILY}" == "rpm" ]]; then out+=(conntrack-tools); else out+=(conntrack); fi ;;
      socat)
        out+=(socat) ;;
      nfs-utils)
        if [[ "${OS_FAMILY}" == "rpm" ]]; then out+=(nfs-utils); else out+=(nfs-common); fi ;;
      firewalld)
        if [[ "${OS_FAMILY}" == "rpm" ]]; then out+=(firewalld); fi ;;
      container-selinux)
        if [[ "${OS_FAMILY}" == "rpm" ]]; then out+=(container-selinux); fi ;;
      *)
        out+=("${p}") ;;
    esac
  done
  # Deduplicate while preserving order
  local seen="|" uniq=()
  for p in "${out[@]}"; do
    [[ -z "${p}" ]] && continue
    if [[ "${seen}" != *"|${p}|"* ]]; then
      uniq+=("${p}")
      seen="${seen}${p}|"
    fi
  done
  echo "${uniq[*]}"
}

# First step on empty servers: install tools required by later preflight
bootstrap_host_tools() {
  detect_os
  log "Bootstrapping base tools on empty host (${OS_ID})..."
  pkg_update || warn "pkg_update returned non-zero — continuing if cache exists"

  local wanted
  wanted="$(resolve_pkg_list curl ca-certificates gnupg jq lvm2 xfsprogs e2fsprogs iproute openssl tar wget yum-utils apt-transport-https lsb-release conntrack socat nfs-utils)"
  # shellcheck disable=SC2086
  install_packages ${wanted} || die "Failed to install base packages: ${wanted}"

  if [[ "${OS_FAMILY}" == "rpm" ]]; then
    local rpm_extra
    rpm_extra="$(resolve_pkg_list container-selinux firewalld)"
    # shellcheck disable=SC2086
    install_packages ${rpm_extra} || warn "Optional rpm packages missing (container-selinux/firewalld)"
  fi

  require_cmd curl
  require_cmd openssl
  if ! command -v ss >/dev/null 2>&1; then
    die "ss not found after bootstrap — install iproute/iproute2"
  fi
  log "Bootstrap tools OK"
}

idempotent_apt_update() {
  # Back-compat name used by older scripts
  pkg_update
}

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
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
  if ! command -v ss >/dev/null 2>&1; then
    warn "ss missing — skip port ${port} check"
    return 0
  fi
  if ss -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}\$"; then
    return 1
  fi
  log "Port ${port} is free"
  return 0
}

assert_port_free_or_k8s() {
  # For control-plane 6443: free OR already initialized
  local port="$1"
  if check_port_free "${port}"; then
    return 0
  fi
  if [[ "${port}" == "6443" && -f /etc/kubernetes/admin.conf ]]; then
    log "Port ${port} in use — control-plane already present"
    return 0
  fi
  die "Port ${port} is already in use"
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

# -----------------------------------------------------------------------------
# Kernel / swap / SELinux / firewall
# -----------------------------------------------------------------------------
disable_swap() {
  if [[ "${SWAP_ENABLED}" == "true" ]]; then
    warn "SWAP_ENABLED=true — leaving swap as-is (not recommended for K8s)"
    return 0
  fi
  swapoff -a || true
  if [[ -f /etc/fstab ]] && grep -Eq '^\s*[^#].+\s+swap\s' /etc/fstab; then
    sed -ri 's/^(\s*[^#].+\s+swap\s)/#\1/' /etc/fstab
    log "Commented swap entries in /etc/fstab"
  fi
  log "Swap disabled"
}

ensure_kernel_modules() {
  modprobe overlay || die "Cannot load overlay module"
  modprobe br_netfilter || die "Cannot load br_netfilter module"
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

configure_selinux() {
  # RED OS / RHEL-like: kubeadm needs permissive or container-selinux policies
  if [[ "${OS_FAMILY}" != "rpm" ]]; then
    return 0
  fi
  if ! command -v getenforce >/dev/null 2>&1; then
    return 0
  fi
  local mode="${SELINUX_MODE:-permissive}"
  case "${mode}" in
    enforcing)
      setenforce 1 2>/dev/null || warn "Cannot setenforce 1"
      sed -ri 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null || true
      warn "SELINUX_MODE=enforcing — ensure container-selinux policies are correct"
      ;;
    disabled)
      setenforce 0 2>/dev/null || true
      sed -ri 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true
      warn "SELinux disabled (reboot may be required for full disable)"
      ;;
    permissive|*)
      setenforce 0 2>/dev/null || true
      sed -ri 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
      log "SELinux set to permissive (recommended for initial kubeadm on RED OS)"
      ;;
  esac
}

open_firewall_ports() {
  # role: control-plane | worker | indexer
  local role="${1:-worker}"
  if [[ "${FIREWALL_MANAGE:-true}" != "true" ]]; then
    log "FIREWALL_MANAGE=false — skip firewall changes"
    return 0
  fi

  local ports=()
  case "${role}" in
    control-plane)
      ports=(6443/tcp 2379/tcp 2380/tcp 10250/tcp 10257/tcp 10259/tcp 179/tcp)
      ;;
    worker)
      ports=(10250/tcp 30000-32767/tcp 1514/tcp 1515/tcp 55000/tcp 179/tcp)
      ;;
    indexer)
      ports=(10250/tcp 9200/tcp 9300/tcp 179/tcp)
      ;;
    *)
      ports=(10250/tcp)
      ;;
  esac

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    for p in "${ports[@]}"; do
      firewall-cmd --permanent --add-port="${p}" >/dev/null 2>&1 || true
    done
    # Calico IPIP / VXLAN
    firewall-cmd --permanent --add-protocol=ipip >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    log "firewalld ports opened for role=${role}"
    return 0
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'active'; then
    for p in "${ports[@]}"; do
      ufw allow "${p}" >/dev/null 2>&1 || true
    done
    log "ufw ports opened for role=${role}"
    return 0
  fi

  log "No active firewalld/ufw — ensure upstream firewall allows K8s/Wazuh ports for role=${role}"
}

# -----------------------------------------------------------------------------
# Disks (LVM)
# -----------------------------------------------------------------------------
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
  require_cmd "mkfs.${fstype}"

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
  [[ -n "${uuid}" ]] || die "Cannot read UUID of ${mapper}"
  if ! grep -q "UUID=${uuid}" /etc/fstab 2>/dev/null; then
    echo "UUID=${uuid} ${mountpoint} ${fstype} ${opts} 0 2" >>/etc/fstab
  fi
  mount "${mountpoint}"
  log "Mounted ${mapper} -> ${mountpoint} (${fstype}, ${opts})"
}

# -----------------------------------------------------------------------------
# containerd + Kubernetes packages
# -----------------------------------------------------------------------------
_k8s_minor() {
  # From 1.30.4-1.1 or 1.30.4 → 1.30
  echo "${K8S_VERSION}" | cut -d. -f1,2 | cut -d- -f1
}

_k8s_semver() {
  # From 1.30.4-1.1 → 1.30.4
  echo "${K8S_VERSION}" | cut -d- -f1
}

configure_containerd_systemd_cgroup() {
  mkdir -p /etc/containerd
  if [[ ! -f /etc/containerd/config.toml ]] || [[ ! -s /etc/containerd/config.toml ]]; then
    containerd config default >/etc/containerd/config.toml
  fi
  # Robust enable of SystemdCgroup (works on containerd 1.6/1.7)
  if grep -q 'SystemdCgroup' /etc/containerd/config.toml; then
    sed -i 's/SystemdCgroup\s*=\s*false/SystemdCgroup = true/g' /etc/containerd/config.toml
  else
    # Insert under [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    if grep -q 'runtimes.runc.options' /etc/containerd/config.toml; then
      sed -i '/runtimes\.runc\.options]/a/SystemdCgroup = true/' /etc/containerd/config.toml
    else
      warn "Could not find runc.options in containerd config — verify SystemdCgroup manually"
    fi
  fi
  # Ensure sandbox image is pullable (pause)
  sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.9"|' /etc/containerd/config.toml || true
}

install_containerd_from_binary() {
  local ver="${CONTAINERD_VERSION:-1.7.22}"
  local runc_ver="${RUNC_VERSION:-1.1.14}"
  local arch="amd64"
  local tmp
  tmp="$(mktemp -d)"
  log "Installing containerd ${ver} + runc ${runc_ver} from official binaries"
  curl -fsSL "https://github.com/containerd/containerd/releases/download/v${ver}/containerd-${ver}-linux-${arch}.tar.gz" \
    -o "${tmp}/containerd.tgz"
  tar -C /usr/local -xzf "${tmp}/containerd.tgz"
  curl -fsSL "https://github.com/opencontainers/runc/releases/download/v${runc_ver}/runc.${arch}" \
    -o /usr/local/sbin/runc
  chmod 755 /usr/local/sbin/runc
  # CNI plugins (required for pod networking stack with kubelet)
  local cni_ver="${CNI_PLUGINS_VERSION:-1.5.1}"
  mkdir -p /opt/cni/bin
  curl -fsSL "https://github.com/containernetworking/plugins/releases/download/v${cni_ver}/cni-plugins-linux-${arch}-v${cni_ver}.tgz" \
    -o "${tmp}/cni.tgz"
  tar -C /opt/cni/bin -xzf "${tmp}/cni.tgz"
  if [[ ! -f /etc/systemd/system/containerd.service ]]; then
    curl -fsSL "https://raw.githubusercontent.com/containerd/containerd/v${ver}/containerd.service" \
      -o /etc/systemd/system/containerd.service
    # Prefer /usr/local/bin path from tarball
    sed -i 's|/usr/local/bin/containerd|/usr/local/bin/containerd|' /etc/systemd/system/containerd.service || true
  fi
  rm -rf "${tmp}"
  configure_containerd_systemd_cgroup
  systemctl daemon-reload
  systemctl enable --now containerd
  log "containerd binary install complete"
}

install_containerd_runtime() {
  if already_done containerd; then
    log "containerd stamp present — skip install"
    systemctl enable --now containerd
    return 0
  fi

  local method="${CONTAINERD_INSTALL_METHOD:-auto}"
  # auto: deb → apt package first; rpm → binaries (repos often missing on RED OS)
  if [[ "${method}" == "auto" ]]; then
    if [[ "${OS_FAMILY}" == "deb" ]]; then
      method="package"
    else
      method="binary"
    fi
  fi

  case "${method}" in
    package)
      if [[ "${OS_FAMILY}" == "deb" ]]; then
        install_packages containerd || {
          warn "apt containerd failed — falling back to binary"
          install_containerd_from_binary
          mark_done containerd
          return 0
        }
        configure_containerd_systemd_cgroup
        systemctl enable --now containerd
      else
        # Try dnf module / package then binary
        if install_packages containerd; then
          configure_containerd_systemd_cgroup
          systemctl enable --now containerd
        else
          install_containerd_from_binary
        fi
      fi
      ;;
    binary)
      install_containerd_from_binary
      ;;
    *)
      die "Unknown CONTAINERD_INSTALL_METHOD=${method}"
      ;;
  esac
  mark_done containerd
}

install_kubernetes_pkgs() {
  if already_done k8s-pkgs; then
    log "k8s packages stamp present"
    systemctl enable --now kubelet || true
    return 0
  fi

  local ver_minor semver
  ver_minor="$(_k8s_minor)"
  semver="$(_k8s_semver)"

  if [[ "${OS_FAMILY}" == "deb" ]]; then
    mkdir -p /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
      curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${ver_minor}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    fi
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${ver_minor}/deb/ /" \
      >/etc/apt/sources.list.d/kubernetes.list
    pkg_update
    local deb_ver="${K8S_VERSION}"
    # Astra sometimes needs unhold/allow
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "kubelet=${deb_ver}" "kubeadm=${deb_ver}" "kubectl=${deb_ver}"; then
      warn "Exact version ${deb_ver} failed — trying ${semver}-*"
      DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl \
        || die "Cannot install kubelet/kubeadm/kubectl from pkgs.k8s.io"
    fi
    apt-mark hold kubelet kubeadm kubectl || true
  else
    # RPM path (RED OS 8 / RHEL-like)
    cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${ver_minor}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${ver_minor}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni-plugins
EOF
    pkg_update
    local rpm_ver="${K8S_VERSION_RPM:-${semver}}"
    if ! ${PKG_MGR} -y install \
        "kubelet-${rpm_ver}" "kubeadm-${rpm_ver}" "kubectl-${rpm_ver}" \
        --disableexcludes=kubernetes; then
      warn "Pinned rpm ${rpm_ver} failed — installing latest from kubernetes repo"
      ${PKG_MGR} -y install kubelet kubeadm kubectl --disableexcludes=kubernetes \
        || die "Cannot install kubelet/kubeadm/kubectl (rpm)"
    fi
    # Hold-like: keep exclude in repo; versions already installed
  fi

  systemctl enable --now kubelet
  mark_done k8s-pkgs
  log "Kubernetes packages installed (minor v${ver_minor})"
}

generate_cluster_key() {
  if [[ -z "${WAZUH_CLUSTER_KEY:-}" ]]; then
    WAZUH_CLUSTER_KEY="$(openssl rand -hex 16)"
    export WAZUH_CLUSTER_KEY
    log "Generated WAZUH_CLUSTER_KEY"
  fi
  # Wazuh expects 32 hex chars
  if [[ ! "${WAZUH_CLUSTER_KEY}" =~ ^[0-9a-fA-F]{32}$ ]]; then
    die "WAZUH_CLUSTER_KEY must be 32 hex characters"
  fi
}

run_or_dry() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
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

# Substitute INDEXER/WORKER hostnames into PV YAML (from cluster.env)
render_storage_pvs() {
  local src_dir="${_ROOT_DIR}/manifests/storage"
  local out_dir="${_ROOT_DIR}/manifests/.rendered/storage"
  mkdir -p "${out_dir}"
  local idx_hosts=(${INDEXER_HOSTS})
  local wrk_hosts=(${WORKER_HOSTS})
  local f base
  for f in "${src_dir}"/*.yaml; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    cp "${f}" "${out_dir}/${base}"
  done
  # Replace default hostnames if present
  if [[ ${#idx_hosts[@]} -ge 3 ]]; then
    sed -i \
      -e "s/k8s-indexer-01/${idx_hosts[0]}/g" \
      -e "s/k8s-indexer-02/${idx_hosts[1]}/g" \
      -e "s/k8s-indexer-03/${idx_hosts[2]}/g" \
      "${out_dir}/pv-indexer.yaml" 2>/dev/null || true
  fi
  if [[ ${#wrk_hosts[@]} -ge 1 ]]; then
    sed -i "s/k8s-worker-01/${wrk_hosts[0]}/g" "${out_dir}/pv-manager-lab.yaml" 2>/dev/null || true
  fi
  if [[ ${#wrk_hosts[@]} -ge 2 ]]; then
    sed -i "s/k8s-worker-02/${wrk_hosts[1]}/g" "${out_dir}/pv-manager-lab.yaml" 2>/dev/null || true
  fi
  echo "${out_dir}"
}
