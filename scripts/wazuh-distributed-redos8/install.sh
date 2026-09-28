#!/usr/bin/env bash
# Interactive Wazuh distributed (multi-node) installer for RED OS 8 / RHEL-compatible.
# Wraps the official wazuh-install.sh assisted method (no Kubernetes).
# Supports local role install AND remote install over SSH (choose server + role).
# Docs: https://documentation.wazuh.com/current/installation-guide/
set -euo pipefail

WAZUH_MAJOR="${WAZUH_MAJOR:-4.14}"
PKG_BASE="https://packages.wazuh.com/${WAZUH_MAJOR}"
WORKDIR="${WAZUH_WORKDIR:-/root/wazuh-install}"
STATE_FILE="${WORKDIR}/.install-state"
CRED_FILE="${WORKDIR}/wazuh-credentials.txt"
CONFIG_FILE="${WORKDIR}/config.yml"
ASSISTANT="${WORKDIR}/wazuh-install.sh"
TAR_FILE="${WORKDIR}/wazuh-install-files.tar"
LOG_DIR="${WORKDIR}/logs"
SSH_CONF="${WORKDIR}/.ssh-settings"
SELF_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

# Non-interactive / remote child flags
AUTO_ROLE=""
AUTO_NODE_NAME=""
AUTO_PORT="443"
AUTO_HOSTNAME=""
AUTO_OPEN_FW="1"
AUTO_YES="0"

SSH_USER="root"
SSH_PORT="22"
SSH_IDENTITY=""
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Inventory arrays (filled from config.yml)
INV_ROLE=()
INV_NAME=()
INV_IP=()
INV_TYPE=()

log()  { printf '%b\n' "$*"; }
ok()   { log "${GREEN}[OK]${NC} $*"; }
warn() { log "${YELLOW}[!]${NC} $*"; }
err()  { log "${RED}[ERR]${NC} $*" >&2; }
info() { log "${CYAN}[--]${NC} $*"; }
hdr()  { log ""; log "${BOLD}=== $* ===${NC}"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Запустите от root: sudo -i  или  sudo bash $0"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "${WORKDIR}" "${LOG_DIR}"
  chmod 700 "${WORKDIR}"
}

save_state() {
  local key="$1" value="$2"
  touch "${STATE_FILE}"
  if grep -q "^${key}=" "${STATE_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${STATE_FILE}"
  else
    echo "${key}=${value}" >> "${STATE_FILE}"
  fi
}

get_state() {
  local key="$1" default="${2:-}"
  if [[ -f "${STATE_FILE}" ]] && grep -q "^${key}=" "${STATE_FILE}"; then
    grep "^${key}=" "${STATE_FILE}" | head -1 | cut -d= -f2-
  else
    echo "${default}"
  fi
}

ask() {
  local prompt="$1" default="${2:-}"
  if [[ "${AUTO_YES}" == "1" && -n "${default}" ]]; then
    REPLY="${default}"
    return 0
  fi
  if [[ -n "${default}" ]]; then
    read -r -p "$(printf '%b' "${prompt} [${default}]: ")" REPLY
    REPLY="${REPLY:-${default}}"
  else
    while true; do
      read -r -p "$(printf '%b' "${prompt}: ")" REPLY
      [[ -n "${REPLY}" ]] && break
      warn "Значение обязательно."
    done
  fi
}

ask_yn() {
  local prompt="$1" default="${2:-y}"
  if [[ "${AUTO_YES}" == "1" ]]; then
    [[ "${default}" =~ ^[YyДд] ]]
    return $?
  fi
  local hint="y/n"
  [[ "${default}" == "y" ]] && hint="Y/n"
  [[ "${default}" == "n" ]] && hint="y/N"
  read -r -p "$(printf '%b' "${prompt} [${hint}]: ")" REPLY
  REPLY="${REPLY:-${default}}"
  [[ "${REPLY}" =~ ^[YyДд] ]]
}

pause() {
  [[ "${AUTO_YES}" == "1" ]] && return 0
  read -r -p "Нажмите Enter для продолжения..." _
}

detect_primary_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

load_ssh_settings() {
  [[ -f "${SSH_CONF}" ]] || return 0
  # shellcheck disable=SC1090
  source "${SSH_CONF}"
  rebuild_ssh_opts
}

save_ssh_settings() {
  umask 077
  cat > "${SSH_CONF}" <<EOF
SSH_USER="${SSH_USER}"
SSH_PORT="${SSH_PORT}"
SSH_IDENTITY="${SSH_IDENTITY}"
EOF
  ok "SSH-настройки: ${SSH_CONF}"
}

rebuild_ssh_opts() {
  SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "${SSH_PORT}")
  if [[ -n "${SSH_IDENTITY}" ]]; then
    SSH_OPTS+=(-i "${SSH_IDENTITY}")
  fi
}

configure_ssh_settings() {
  hdr "Параметры SSH для удалённой установки"
  load_ssh_settings
  ask "SSH user" "${SSH_USER}"
  SSH_USER="${REPLY}"
  ask "SSH port" "${SSH_PORT}"
  SSH_PORT="${REPLY}"
  ask "Путь к приватному ключу (пусто = ssh-agent / default)" "${SSH_IDENTITY}"
  SSH_IDENTITY="${REPLY}"
  rebuild_ssh_opts
  save_ssh_settings
  info "Проверка: нужен доступ без пароля (ключ). Пример: ssh-copy-id -i ... ${SSH_USER}@HOST"
}

ssh_cmd() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

scp_to() {
  local host="$1"; shift
  scp "${SSH_OPTS[@]}" "$@" "${SSH_USER}@${host}:${WORKDIR}/"
}

# ---------------------------------------------------------------------------
# Inventory from config.yml
# ---------------------------------------------------------------------------
parse_inventory() {
  INV_ROLE=(); INV_NAME=(); INV_IP=(); INV_TYPE=()
  [[ -f "${CONFIG_FILE}" ]] || return 1

  local tmp
  tmp="$(mktemp)"
  awk '
    function flush() {
      if (name != "" && ip != "") print sec "|" name "|" ip "|" type
      name=""; ip=""; type=""
    }
    /^[[:space:]]*indexer:[[:space:]]*$/ { flush(); sec="indexer"; next }
    /^[[:space:]]*server:[[:space:]]*$/ { flush(); sec="server"; next }
    /^[[:space:]]*dashboard:[[:space:]]*$/ { flush(); sec="dashboard"; next }
    /^[a-zA-Z]/ && $0 !~ /^nodes:/ { flush(); sec=""; next }
    sec=="" { next }
    /name:/ {
      flush()
      name=$0; sub(/.*name:[ \t]*/,"",name); gsub(/["'\'' ]/,"",name)
      next
    }
    /ip:/ {
      ip=$0; sub(/.*ip:[ \t]*/,"",ip); gsub(/["'\'' ]/,"",ip)
      next
    }
    /node_type:/ {
      type=$0; sub(/.*node_type:[ \t]*/,"",type); gsub(/["'\'' ]/,"",type)
      next
    }
    END { flush() }
  ' "${CONFIG_FILE}" > "${tmp}"

  while IFS='|' read -r r n i t; do
    [[ -z "${r}" ]] && continue
    INV_ROLE+=("${r}")
    INV_NAME+=("${n}")
    INV_IP+=("${i}")
    INV_TYPE+=("${t}")
  done < "${tmp}"
  rm -f "${tmp}"

  ((${#INV_NAME[@]} > 0))
}

show_inventory() {
  hdr "Инвентарь узлов из config.yml"
  if ! parse_inventory; then
    err "Нет ${CONFIG_FILE} или он пустой. Сначала пункт «Мастер config.yml»."
    return 1
  fi
  printf '%-4s %-12s %-20s %-16s %s\n' "#" "Роль" "Имя" "IP" "node_type"
  printf '%-4s %-12s %-20s %-16s %s\n' "----" "------------" "--------------------" "----------------" "---------"
  local i
  for i in "${!INV_NAME[@]}"; do
    printf '%-4s %-12s %-20s %-16s %s\n' "$((i+1))" "${INV_ROLE[$i]}" "${INV_NAME[$i]}" "${INV_IP[$i]}" "${INV_TYPE[$i]:--}"
  done
}

pick_inventory_node() {
  # Sets PICK_IDX PICK_ROLE PICK_NAME PICK_IP PICK_TYPE
  show_inventory || return 1
  echo
  ask "Номер узла из списка" "1"
  local num="${REPLY}"
  if ! [[ "${num}" =~ ^[0-9]+$ ]] || (( num < 1 || num > ${#INV_NAME[@]} )); then
    err "Неверный номер"
    return 1
  fi
  PICK_IDX=$((num-1))
  PICK_ROLE="${INV_ROLE[$PICK_IDX]}"
  PICK_NAME="${INV_NAME[$PICK_IDX]}"
  PICK_IP="${INV_IP[$PICK_IDX]}"
  PICK_TYPE="${INV_TYPE[$PICK_IDX]}"
  ok "Выбран: ${PICK_ROLE} / ${PICK_NAME} / ${PICK_IP}"
}

is_local_ip() {
  local target="$1" local_ips
  local_ips="$(hostname -I 2>/dev/null || true)"
  [[ " ${local_ips} " == *" ${target} "* ]] || [[ "${target}" == "127.0.0.1" ]]
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
  hdr "Статус установки на этом хосте"
  info "WORKDIR: ${WORKDIR}"
  info "Hostname: $(hostname -f 2>/dev/null || hostname)"
  info "IP: $(detect_primary_ip || echo n/a)"
  info "OS: $(. /etc/os-release 2>/dev/null; echo "${NAME:-?} ${VERSION_ID:-?}")"

  echo
  printf '%-28s %s\n' "Компонент" "Состояние"
  printf '%-28s %s\n' "----------------------------" "----------"

  _svc() {
    local unit="$1"
    if systemctl list-unit-files "${unit}.service" &>/dev/null || systemctl status "${unit}" &>/dev/null; then
      if systemctl is-active --quiet "${unit}"; then
        printf '%-28s %b\n' "${unit}" "${GREEN}active${NC}"
      elif systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
        printf '%-28s %b\n' "${unit}" "${YELLOW}inactive (enabled)${NC}"
      else
        printf '%-28s %b\n' "${unit}" "${YELLOW}installed? / not active${NC}"
      fi
    else
      printf '%-28s %s\n' "${unit}" "не установлен"
    fi
  }

  _svc wazuh-indexer
  _svc wazuh-manager
  _svc filebeat
  _svc wazuh-dashboard

  echo
  [[ -f "${ASSISTANT}" ]] && ok "Есть wazuh-install.sh" || warn "Нет wazuh-install.sh"
  [[ -f "${CONFIG_FILE}" ]] && ok "Есть config.yml" || warn "Нет config.yml"
  [[ -f "${TAR_FILE}" ]] && ok "Есть wazuh-install-files.tar" || warn "Нет wazuh-install-files.tar"
  [[ -f "${CRED_FILE}" ]] && ok "Креды: ${CRED_FILE}" || warn "Файл кредов ещё не создан"

  if [[ -f "${STATE_FILE}" ]]; then
    echo
    info "Сохранённое состояние (.install-state):"
    cat "${STATE_FILE}"
  fi

  if [[ -f "${CONFIG_FILE}" ]]; then
    echo
    show_inventory || true
  fi

  if [[ -f "${TAR_FILE}" ]]; then
    local idx_ip admin_pw
    idx_ip="$(get_state LAST_INDEXER_IP "")"
    if [[ -z "${idx_ip}" ]] && parse_inventory; then
      local i
      for i in "${!INV_ROLE[@]}"; do
        if [[ "${INV_ROLE[$i]}" == "indexer" ]]; then idx_ip="${INV_IP[$i]}"; break; fi
      done
    fi
    if [[ -n "${idx_ip}" ]] && command -v curl >/dev/null; then
      admin_pw="$(extract_admin_password || true)"
      if [[ -n "${admin_pw}" ]]; then
        echo
        info "Проверка Indexer https://${idx_ip}:9200 ..."
        if curl -sk -u "admin:${admin_pw}" --connect-timeout 3 "https://${idx_ip}:9200" >/dev/null 2>&1; then
          ok "Indexer API отвечает"
          curl -sk -u "admin:${admin_pw}" "https://${idx_ip}:9200/_cat/nodes?v" 2>/dev/null || true
        else
          warn "Indexer API не отвечает (ещё не установлен / firewall / другой IP)"
        fi
      fi
    fi
  fi

  if command -v /var/ossec/bin/cluster_control >/dev/null 2>&1; then
    echo
    info "Wazuh server cluster:"
    /var/ossec/bin/cluster_control -l 2>/dev/null || warn "cluster_control недоступен"
  fi
}

extract_admin_password() {
  [[ -f "${TAR_FILE}" ]] || return 1
  local tmp pw_file
  tmp="$(mktemp -d)"
  tar -xf "${TAR_FILE}" -C "${tmp}" 2>/dev/null || { rm -rf "${tmp}"; return 1; }
  pw_file="$(find "${tmp}" -name 'wazuh-passwords.txt' | head -1)"
  if [[ -z "${pw_file}" ]]; then
    rm -rf "${tmp}"
    return 1
  fi
  awk -F"'" '/indexer_password:/{print $2; exit}' "${pw_file}"
  rm -rf "${tmp}"
}

extract_passwords_to_credfile() {
  [[ -f "${TAR_FILE}" ]] || { err "Нет ${TAR_FILE}"; return 1; }

  local tmp pw_file
  tmp="$(mktemp -d)"
  tar -xf "${TAR_FILE}" -C "${tmp}"
  pw_file="$(find "${tmp}" -name 'wazuh-passwords.txt' | head -1)"
  if [[ -z "${pw_file}" ]]; then
    err "В архиве нет wazuh-passwords.txt"
    rm -rf "${tmp}"
    return 1
  fi

  umask 077
  {
    echo "# Wazuh credentials — сгенерировано $(date -Is)"
    echo "# Хост: $(hostname) | WORKDIR: ${WORKDIR}"
    echo "# Храните файл в секрете. Права: 600."
    echo "#"
    echo "# Источник: wazuh-install-files/wazuh-passwords.txt"
    echo
    cat "${pw_file}"
    echo
    echo "# ---- Быстрый доступ ----"
    local user pass dip dport
    user="$(awk -F"'" '/indexer_username:/{print $2; exit}' "${pw_file}")"
    pass="$(awk -F"'" '/indexer_password:/{print $2; exit}' "${pw_file}")"
    [[ -z "${user}" ]] && user="admin"
    dip="$(get_state DASHBOARD_IP "$(detect_primary_ip)")"
    dport="$(get_state DASHBOARD_PORT "443")"
    echo "DASHBOARD_URL=https://${dip}:${dport}"
    echo "DASHBOARD_USER=${user}"
    echo "DASHBOARD_PASSWORD=${pass}"
    echo "INDEXER_ADMIN_USER=${user}"
    echo "INDEXER_ADMIN_PASSWORD=${pass}"
  } > "${CRED_FILE}"
  chmod 600 "${CRED_FILE}"
  rm -rf "${tmp}"
  ok "Креды сохранены: ${CRED_FILE}"
}

# ---------------------------------------------------------------------------
# Prep / firewall
# ---------------------------------------------------------------------------
prepare_host() {
  hdr "Подготовка хоста (РЕД ОС 8 / RHEL-compatible)"
  info "Установка базовых пакетов и sysctl для Indexer..."

  if command -v dnf >/dev/null; then
    dnf -y install curl tar openssl firewalld chrony procps-ng openssh-clients 2>&1 | tee -a "${LOG_DIR}/prep.log"
  elif command -v yum >/dev/null; then
    yum -y install curl tar openssl firewalld chrony procps-ng openssh-clients 2>&1 | tee -a "${LOG_DIR}/prep.log"
  else
    err "Нет dnf/yum — это не RHEL-подобная система?"
    return 1
  fi

  systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true
  timedatectl set-ntp true 2>/dev/null || true

  if ! grep -q 'vm.max_map_count' /etc/sysctl.conf 2>/dev/null; then
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
  fi
  sysctl -w vm.max_map_count=262144 >/dev/null
  ok "vm.max_map_count=262144"

  systemctl enable --now firewalld 2>/dev/null || warn "firewalld не запущен (настройте вручную)"

  local hn_default
  hn_default="${AUTO_HOSTNAME:-$(hostname)}"
  if [[ -n "${AUTO_ROLE}" ]]; then
    if [[ -n "${AUTO_HOSTNAME}" ]]; then
      hostnamectl set-hostname "${AUTO_HOSTNAME}"
      ok "hostname = ${AUTO_HOSTNAME}"
    fi
  else
    ask "Задать hostname для этой машины?" "${hn_default}"
    local hn="${REPLY}"
    if [[ -n "${hn}" ]]; then
      hostnamectl set-hostname "${hn}"
      ok "hostname = ${hn}"
    fi
  fi

  save_state PREP_DONE 1
  ok "Подготовка завершена"
}

open_firewall_role() {
  local role="$1" port="${2:-443}"
  systemctl is-active --quiet firewalld || return 0
  case "${role}" in
    indexer)
      firewall-cmd --permanent --add-port=9200/tcp
      firewall-cmd --permanent --add-port=9300-9400/tcp
      ;;
    server)
      firewall-cmd --permanent --add-port=1514/tcp
      firewall-cmd --permanent --add-port=1515/tcp
      firewall-cmd --permanent --add-port=1516/tcp
      firewall-cmd --permanent --add-port=55000/tcp
      ;;
    dashboard)
      firewall-cmd --permanent --add-port="${port}/tcp"
      ;;
  esac
  firewall-cmd --reload || true
}

configure_firewall_for_role() {
  hdr "Firewall (firewalld) под роль"
  if ! systemctl is-active --quiet firewalld; then
    warn "firewalld не active — пропускаю (откройте порты сами)"
    return 0
  fi

  echo "1) Indexer (9200, 9300-9400)"
  echo "2) Server/Manager (1514, 1515, 1516, 55000)"
  echo "3) Dashboard (443)"
  echo "4) Всё сразу"
  ask "Выбор" "1"
  case "${REPLY}" in
    1) open_firewall_role indexer ;;
    2) open_firewall_role server ;;
    3)
      ask "Порт Dashboard" "443"
      open_firewall_role dashboard "${REPLY}"
      ;;
    4)
      open_firewall_role indexer
      open_firewall_role server
      open_firewall_role dashboard 443
      ;;
    *) err "Неизвестный выбор"; return 1 ;;
  esac
  ok "Правила firewalld применены"
  firewall-cmd --list-ports || true
}

# ---------------------------------------------------------------------------
# Download + config wizard
# ---------------------------------------------------------------------------
download_assistant() {
  hdr "Скачивание официального Wazuh installation assistant (${WAZUH_MAJOR})"
  ensure_dirs
  cd "${WORKDIR}"
  if [[ -z "${AUTO_ROLE}" ]]; then
    ask "Базовый URL пакетов" "${PKG_BASE}"
    PKG_BASE="${REPLY}"
  fi
  curl -fsSL -O "${PKG_BASE}/wazuh-install.sh"
  curl -fsSL -O "${PKG_BASE}/config.yml"
  chmod +x wazuh-install.sh
  ok "Скачано в ${WORKDIR}"
  bash "${ASSISTANT}" -V 2>&1 | tee -a "${LOG_DIR}/version.log" || true
  save_state PKG_BASE "${PKG_BASE}"
}

wizard_config_yml() {
  hdr "Мастер config.yml (имена и IP всех узлов)"
  ensure_dirs
  cd "${WORKDIR}"

  if [[ ! -f "${ASSISTANT}" ]]; then
    warn "Assistant ещё не скачан — скачиваю..."
    download_assistant
  fi
  [[ -f "${WORKDIR}/config.yml" ]] || curl -fsSL -o "${CONFIG_FILE}" "$(get_state PKG_BASE "${PKG_BASE}")/config.yml"

  warn "Имена узлов после генерации сертификатов МЕНЯТЬ НЕЛЬЗЯ."
  echo
  echo "Выберите топологию:"
  echo "  1) Минимальная: 1 indexer + 1 server + 1 dashboard"
  echo "  2) Рекомендуемая HA: 3 indexer + 2 server + 1 dashboard"
  echo "  3) Свой набор"
  ask "Топология" "2"
  local topo="${REPLY}"

  local n_idx=1 n_srv=1 n_dash=1
  case "${topo}" in
    1) n_idx=1; n_srv=1; n_dash=1 ;;
    2) n_idx=3; n_srv=2; n_dash=1 ;;
    3)
      ask "Сколько Indexer-узлов" "3"; n_idx="${REPLY}"
      ask "Сколько Server-узлов" "2"; n_srv="${REPLY}"
      ask "Сколько Dashboard-узлов" "1"; n_dash="${REPLY}"
      ;;
    *) err "Неверный выбор"; return 1 ;;
  esac

  local -a idx_names idx_ips srv_names srv_ips srv_types dash_names dash_ips
  local i def_ip
  def_ip="$(detect_primary_ip)"

  hdr "Indexer узлы"
  for ((i=1; i<=n_idx; i++)); do
    ask "Имя indexer #${i}" "node-${i}"
    idx_names+=("${REPLY}")
    ask "IP indexer #${i} (${idx_names[$((i-1))]})" "${def_ip}"
    idx_ips+=("${REPLY}")
  done

  hdr "Server (manager) узлы"
  for ((i=1; i<=n_srv; i++)); do
    ask "Имя server #${i}" "wazuh-${i}"
    srv_names+=("${REPLY}")
    ask "IP server #${i} (${srv_names[$((i-1))]})" "${def_ip}"
    srv_ips+=("${REPLY}")
    if (( n_srv > 1 )); then
      if (( i == 1 )); then ask "node_type для ${srv_names[$((i-1))]}" "master"
      else ask "node_type для ${srv_names[$((i-1))]}" "worker"; fi
      srv_types+=("${REPLY}")
    else
      srv_types+=("")
    fi
  done

  hdr "Dashboard узлы"
  for ((i=1; i<=n_dash; i++)); do
    ask "Имя dashboard #${i}" "dashboard"
    dash_names+=("${REPLY}")
    ask "IP dashboard #${i} (${dash_names[$((i-1))]})" "${def_ip}"
    dash_ips+=("${REPLY}")
  done

  {
    echo "nodes:"
    echo "  # Wazuh indexer nodes"
    echo "  indexer:"
    for ((i=0; i<n_idx; i++)); do
      echo "    - name: ${idx_names[$i]}"
      echo "      ip: \"${idx_ips[$i]}\""
    done
    echo
    echo "  # Wazuh server nodes"
    echo "  server:"
    for ((i=0; i<n_srv; i++)); do
      echo "    - name: ${srv_names[$i]}"
      echo "      ip: \"${srv_ips[$i]}\""
      if [[ -n "${srv_types[$i]}" ]]; then
        echo "      node_type: ${srv_types[$i]}"
      fi
    done
    echo
    echo "  # Wazuh dashboard nodes"
    echo "  dashboard:"
    for ((i=0; i<n_dash; i++)); do
      echo "    - name: ${dash_names[$i]}"
      echo "      ip: \"${dash_ips[$i]}\""
    done
  } > "${CONFIG_FILE}"

  ok "Записан ${CONFIG_FILE}"
  echo
  cat "${CONFIG_FILE}"
  echo
  save_state LAST_INDEXER_IP "${idx_ips[0]}"
  save_state DASHBOARD_IP "${dash_ips[0]}"
  save_state CONFIG_READY 1

  if ask_yn "Добавить эти имена/IP в /etc/hosts на ЭТОМ сервере?" "y"; then
    write_hosts_block
  fi

  warn "Тот же блок /etc/hosts нужен на остальных узлах (или DNS). Пункт удалённой установки может разнести hosts."
  show_inventory || true
}

write_hosts_block() {
  parse_inventory || return 1
  local marker="# wazuh-distributed-begin"
  local endmark="# wazuh-distributed-end"
  if grep -q "${marker}" /etc/hosts 2>/dev/null; then
    sed -i "/${marker}/,/${endmark}/d" /etc/hosts
  fi
  {
    echo "${marker}"
    local i
    for i in "${!INV_NAME[@]}"; do
      echo "${INV_IP[$i]}  ${INV_NAME[$i]}"
    done
    echo "${endmark}"
  } >> /etc/hosts
  ok "/etc/hosts обновлён"
}

hosts_block_text() {
  parse_inventory || return 1
  echo "# wazuh-distributed-begin"
  local i
  for i in "${!INV_NAME[@]}"; do
    echo "${INV_IP[$i]}  ${INV_NAME[$i]}"
  done
  echo "# wazuh-distributed-end"
}

generate_config_files() {
  hdr "Генерация сертификатов и паролей (--generate-config-files)"
  cd "${WORKDIR}"
  [[ -f "${CONFIG_FILE}" ]] || { err "Сначала создайте config.yml"; return 1; }
  [[ -f "${ASSISTANT}" ]] || { err "Нет wazuh-install.sh"; return 1; }

  if [[ -f "${TAR_FILE}" && -z "${AUTO_ROLE}" ]]; then
    warn "Уже есть ${TAR_FILE}"
    ask_yn "Перегенерировать? Старые сертификаты станут недействительны." "n" || return 0
  fi

  bash "${ASSISTANT}" --generate-config-files 2>&1 | tee "${LOG_DIR}/generate-config-files.log"
  [[ -f "${TAR_FILE}" ]] || { err "Архив не создан"; return 1; }
  extract_passwords_to_credfile
  save_state GENERATED 1
  ok "Готово: ${TAR_FILE}"
  warn "Дальше: меню «Удалённая установка» или скопируйте tar на узлы."
}

copy_hint() {
  hdr "Как разнести файлы"
  cat <<EOF
Рекомендуется пункт меню «Удалённая установка по SSH» — скрипт сам:
  • покажет список серверов из config.yml
  • спросит, на какой ставить какую роль
  • скопирует файлы и запустит установку по SSH

Вручную:
  scp ${ASSISTANT} ${TAR_FILE} ${SELF_SCRIPT} root@IP:${WORKDIR}/
EOF
}

# ---------------------------------------------------------------------------
# Local role install
# ---------------------------------------------------------------------------
install_indexer() {
  local name="${1:-}"
  hdr "Установка Wazuh Indexer"
  cd "${WORKDIR}"
  require_tar_and_assistant || return 1

  if [[ -z "${name}" ]]; then
    list_names_from_config indexer
    ask "Имя этого indexer-узла (как в config.yml)" "$(get_state THIS_INDEXER_NAME "node-1")"
    name="${REPLY}"
  fi
  save_state THIS_INDEXER_NAME "${name}"
  save_state THIS_ROLE indexer

  if [[ "${AUTO_OPEN_FW}" == "1" ]]; then
    if [[ -n "${AUTO_ROLE}" ]] || ask_yn "Открыть порты firewalld для Indexer?" "y"; then
      open_firewall_role indexer
    fi
  fi

  info "Запуск: bash wazuh-install.sh --wazuh-indexer ${name}"
  bash "${ASSISTANT}" --wazuh-indexer "${name}" 2>&1 | tee "${LOG_DIR}/install-indexer-${name}.log"
  save_state INDEXER_INSTALLED 1
  ok "Indexer ${name} установлен"
  systemctl status wazuh-indexer --no-pager -l | head -20 || true
}

start_indexer_cluster() {
  hdr "Инициализация Indexer cluster (--start-cluster)"
  cd "${WORKDIR}"
  require_tar_and_assistant || return 1

  if ! systemctl is-active --quiet wazuh-indexer; then
    warn "wazuh-indexer не active на этой машине."
    if [[ -z "${AUTO_ROLE}" ]]; then
      ask_yn "Продолжить всё равно?" "n" || return 1
    fi
  fi

  bash "${ASSISTANT}" --start-cluster 2>&1 | tee "${LOG_DIR}/start-cluster.log"
  save_state CLUSTER_STARTED 1
  extract_passwords_to_credfile || true

  local ip admin_pw
  ip="$(get_state LAST_INDEXER_IP "$(detect_primary_ip)")"
  if [[ -z "${AUTO_ROLE}" ]]; then
    ask "IP Indexer для проверки" "${ip}"
    ip="${REPLY}"
  fi
  admin_pw=""
  if [[ -f "${CRED_FILE}" ]]; then
    admin_pw="$(awk -F= '/^INDEXER_ADMIN_PASSWORD=/{print $2; exit}' "${CRED_FILE}")"
  fi
  [[ -z "${admin_pw}" ]] && admin_pw="$(extract_admin_password || true)"
  if [[ -n "${admin_pw}" ]]; then
    info "curl https://${ip}:9200"
    curl -sk -u "admin:${admin_pw}" "https://${ip}:9200" | tee "${LOG_DIR}/indexer-health.json" || true
    echo
    curl -sk -u "admin:${admin_pw}" "https://${ip}:9200/_cat/nodes?v" | tee "${LOG_DIR}/indexer-nodes.txt" || true
  fi
  ok "start-cluster выполнен"
}

install_server() {
  local name="${1:-}"
  hdr "Установка Wazuh Server (manager + Filebeat)"
  cd "${WORKDIR}"
  require_tar_and_assistant || return 1

  if [[ -z "${name}" ]]; then
    list_names_from_config server
    ask "Имя этого server-узла (как в config.yml)" "$(get_state THIS_SERVER_NAME "wazuh-1")"
    name="${REPLY}"
  fi
  save_state THIS_SERVER_NAME "${name}"
  save_state THIS_ROLE server

  if [[ "${AUTO_OPEN_FW}" == "1" ]]; then
    if [[ -n "${AUTO_ROLE}" ]] || ask_yn "Открыть порты firewalld для Server?" "y"; then
      open_firewall_role server
    fi
  fi

  info "Запуск: bash wazuh-install.sh --wazuh-server ${name}"
  bash "${ASSISTANT}" --wazuh-server "${name}" 2>&1 | tee "${LOG_DIR}/install-server-${name}.log"
  save_state SERVER_INSTALLED 1
  ok "Server ${name} установлен"
  systemctl status wazuh-manager --no-pager -l | head -15 || true
  systemctl status filebeat --no-pager -l | head -10 || true
  if [[ -x /var/ossec/bin/cluster_control ]]; then
    /var/ossec/bin/cluster_control -l || true
  fi
}

install_dashboard() {
  local name="${1:-}" port="${2:-}"
  hdr "Установка Wazuh Dashboard"
  cd "${WORKDIR}"
  require_tar_and_assistant || return 1

  if [[ -z "${name}" ]]; then
    list_names_from_config dashboard
    ask "Имя этого dashboard-узла" "$(get_state THIS_DASHBOARD_NAME "dashboard")"
    name="${REPLY}"
  fi
  if [[ -z "${port}" ]]; then
    if [[ -n "${AUTO_ROLE}" ]]; then
      port="${AUTO_PORT}"
    else
      ask "TCP-порт UI" "443"
      port="${REPLY}"
    fi
  fi
  save_state THIS_DASHBOARD_NAME "${name}"
  save_state THIS_ROLE dashboard
  save_state DASHBOARD_PORT "${port}"

  if [[ "${AUTO_OPEN_FW}" == "1" ]]; then
    if [[ -n "${AUTO_ROLE}" ]] || ask_yn "Открыть порт ${port}/tcp в firewalld?" "y"; then
      open_firewall_role dashboard "${port}"
    fi
  fi

  info "Запуск: bash wazuh-install.sh --wazuh-dashboard ${name} -p ${port}"
  bash "${ASSISTANT}" --wazuh-dashboard "${name}" -p "${port}" 2>&1 | tee "${LOG_DIR}/install-dashboard-${name}.log"
  save_state DASHBOARD_INSTALLED 1
  extract_passwords_to_credfile || true

  local dip
  dip="$(detect_primary_ip)"
  save_state DASHBOARD_IP "${dip}"
  ok "Dashboard установлен → https://${dip}:${port}"
  if [[ -f "${CRED_FILE}" ]]; then
    grep -E '^(DASHBOARD_|INDEXER_ADMIN_)' "${CRED_FILE}" || true
  fi
  systemctl status wazuh-dashboard --no-pager -l | head -15 || true
}

disable_repo() {
  hdr "Отключить автообновления репозитория Wazuh"
  if [[ -f /etc/yum.repos.d/wazuh.repo ]]; then
    sed -i "s/^enabled=1/enabled=0/" /etc/yum.repos.d/wazuh.repo
    ok "wazuh.repo: enabled=0"
  else
    warn "wazuh.repo не найден"
  fi
  save_state REPO_DISABLED 1
}

require_tar_and_assistant() {
  [[ -f "${ASSISTANT}" ]] || { err "Нет ${ASSISTANT}"; return 1; }
  [[ -f "${TAR_FILE}" ]] || { err "Нет ${TAR_FILE}"; return 1; }
  return 0
}

list_names_from_config() {
  local section="$1"
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    warn "config.yml нет на этом узле. Имя возьмите из вашего config.yml."
    return 0
  fi
  info "Имена из config.yml (секция ${section}):"
  parse_inventory || return 0
  local i
  for i in "${!INV_ROLE[@]}"; do
    [[ "${INV_ROLE[$i]}" == "${section}" ]] && echo "  - ${INV_NAME[$i]} (${INV_IP[$i]})"
  done
}

export_credentials_menu() {
  hdr "Сохранить / показать креды"
  [[ -f "${TAR_FILE}" ]] || { err "Нет ${TAR_FILE}"; return 1; }
  extract_passwords_to_credfile
  echo
  if ask_yn "Показать ${CRED_FILE} на экране?" "n"; then
    cat "${CRED_FILE}"
  else
    info "Файл: ${CRED_FILE} (chmod 600)"
  fi
}

# ---------------------------------------------------------------------------
# Remote SSH orchestration
# ---------------------------------------------------------------------------
remote_push_bundle() {
  local host="$1"
  hdr "Копирование файлов → ${SSH_USER}@${host}:${WORKDIR}"
  require_tar_and_assistant || return 1
  [[ -f "${SELF_SCRIPT}" ]] || { err "Не найден путь к install.sh"; return 1; }

  ssh_cmd "${host}" "mkdir -p '${WORKDIR}/logs' && chmod 700 '${WORKDIR}'"

  local files=("${ASSISTANT}" "${TAR_FILE}" "${SELF_SCRIPT}")
  [[ -f "${CONFIG_FILE}" ]] && files+=("${CONFIG_FILE}")
  [[ -f "${CRED_FILE}" ]] && files+=("${CRED_FILE}")

  scp "${SSH_OPTS[@]}" "${files[@]}" "${SSH_USER}@${host}:${WORKDIR}/"
  ssh_cmd "${host}" "cd '${WORKDIR}' && mv -f '$(basename "${SELF_SCRIPT}")' install.sh && chmod +x wazuh-install.sh install.sh"
  ok "Файлы на ${host} готовы"
}

remote_apply_hosts() {
  local host="$1"
  parse_inventory || return 1
  local block
  block="$(hosts_block_text)"
  ssh_cmd "${host}" "bash -s" <<EOF
set -e
marker='# wazuh-distributed-begin'
endmark='# wazuh-distributed-end'
if grep -q "\$marker" /etc/hosts 2>/dev/null; then
  sed -i "/\$marker/,/\$endmark/d" /etc/hosts
fi
cat >> /etc/hosts <<'HOSTS'
${block}
HOSTS
echo 'hosts updated'
EOF
}

remote_run_auto() {
  local host="$1"
  shift
  # remaining: args to remote install.sh
  info "SSH ${host}: bash install.sh $*"
  ssh_cmd "${host}" "cd '${WORKDIR}' && bash ./install.sh $*"
}

ensure_ssh_ready() {
  load_ssh_settings
  rebuild_ssh_opts
  if ! command -v ssh >/dev/null || ! command -v scp >/dev/null; then
    err "Нужны ssh и scp (openssh-clients)"
    return 1
  fi
}

test_ssh_host() {
  local host="$1"
  if ssh_cmd "${host}" "echo OK" >/dev/null 2>&1; then
    ok "SSH ${SSH_USER}@${host} — OK"
    return 0
  fi
  err "Нет SSH-доступа к ${SSH_USER}@${host} (нужен ключ / ssh-copy-id)"
  return 1
}

install_on_target() {
  # role name ip [port]
  local role="$1" name="$2" ip="$3" port="${4:-443}"
  hdr "Установка: роль=${role} имя=${name} сервер=${ip}"

  if is_local_ip "${ip}"; then
    info "IP ${ip} — локальный, ставлю без SSH"
    case "${role}" in
      indexer) prepare_host; install_indexer "${name}" ;;
      server) prepare_host; install_server "${name}" ;;
      dashboard) prepare_host; install_dashboard "${name}" "${port}" ;;
      start-cluster) start_indexer_cluster ;;
      *) err "Неизвестная роль ${role}"; return 1 ;;
    esac
    return 0
  fi

  ensure_ssh_ready || return 1
  test_ssh_host "${ip}" || return 1
  remote_push_bundle "${ip}" || return 1
  if ask_yn "Прописать /etc/hosts на ${ip} из config.yml?" "y"; then
    remote_apply_hosts "${ip}" || warn "hosts не обновлены"
  fi

  case "${role}" in
    indexer)
      remote_run_auto "${ip}" --auto-role prep --hostname "${name}"
      remote_run_auto "${ip}" --auto-role indexer --node-name "${name}"
      ;;
    server)
      remote_run_auto "${ip}" --auto-role prep --hostname "${name}"
      remote_run_auto "${ip}" --auto-role server --node-name "${name}"
      ;;
    dashboard)
      remote_run_auto "${ip}" --auto-role prep --hostname "${name}"
      remote_run_auto "${ip}" --auto-role dashboard --node-name "${name}" --port "${port}"
      save_state DASHBOARD_IP "${ip}"
      ;;
    start-cluster)
      remote_run_auto "${ip}" --auto-role start-cluster
      ;;
    *) err "Роль ${role}"; return 1 ;;
  esac
  ok "Готово на ${ip} (${role}/${name})"
}

menu_remote_one() {
  hdr "Удалённая установка: выбрать сервер и роль"
  ensure_ssh_ready || return 1
  pick_inventory_node || return 1

  echo
  echo "Действие для ${PICK_NAME} (${PICK_IP}):"
  echo "  1) Установить роль из config.yml (${PICK_ROLE})"
  echo "  2) Только подготовка хоста (пакеты/sysctl)"
  echo "  3) Только скопировать файлы (assistant+tar+script)"
  echo "  4) --start-cluster (только если это indexer)"
  echo "  5) Отключить wazuh.repo на узле"
  echo "  6) Проверить SSH"
  ask "Действие" "1"
  local act="${REPLY}"

  case "${act}" in
    1)
      local port=443
      if [[ "${PICK_ROLE}" == "dashboard" ]]; then
        ask "Порт Dashboard" "443"
        port="${REPLY}"
      fi
      ask_yn "Начать установку ${PICK_ROLE} на ${PICK_IP}?" "y" || return 0
      install_on_target "${PICK_ROLE}" "${PICK_NAME}" "${PICK_IP}" "${port}"
      ;;
    2)
      test_ssh_host "${PICK_IP}" || return 1
      remote_push_bundle "${PICK_IP}"
      remote_run_auto "${PICK_IP}" --auto-role prep --hostname "${PICK_NAME}"
      ;;
    3)
      test_ssh_host "${PICK_IP}" || return 1
      remote_push_bundle "${PICK_IP}"
      ;;
    4)
      [[ "${PICK_ROLE}" == "indexer" ]] || warn "Обычно start-cluster на indexer"
      ask_yn "Запустить --start-cluster на ${PICK_IP}?" "y" || return 0
      install_on_target start-cluster "${PICK_NAME}" "${PICK_IP}"
      ;;
    5)
      test_ssh_host "${PICK_IP}" || return 1
      remote_push_bundle "${PICK_IP}"
      remote_run_auto "${PICK_IP}" --auto-role disable-repo
      ;;
    6)
      test_ssh_host "${PICK_IP}"
      ;;
    *) err "Неверный выбор" ;;
  esac
}

menu_remote_full() {
  hdr "Установка всего кластера по SSH (по порядку из config.yml)"
  ensure_ssh_ready || return 1
  parse_inventory || return 1
  require_tar_and_assistant || return 1

  show_inventory
  echo
  warn "Порядок: все indexer → start-cluster на первом indexer → все server → dashboard"
  ask_yn "Продолжить?" "y" || return 0

  ask "Порт Dashboard" "443"
  local dport="${REPLY}"

  local i first_indexer_ip="" first_indexer_name=""
  for i in "${!INV_ROLE[@]}"; do
    if [[ "${INV_ROLE[$i]}" == "indexer" ]]; then
      install_on_target indexer "${INV_NAME[$i]}" "${INV_IP[$i]}"
      if [[ -z "${first_indexer_ip}" ]]; then
        first_indexer_ip="${INV_IP[$i]}"
        first_indexer_name="${INV_NAME[$i]}"
      fi
    fi
  done

  [[ -n "${first_indexer_ip}" ]] || { err "Нет indexer в config.yml"; return 1; }
  hdr "start-cluster на ${first_indexer_name} (${first_indexer_ip})"
  install_on_target start-cluster "${first_indexer_name}" "${first_indexer_ip}"

  for i in "${!INV_ROLE[@]}"; do
    if [[ "${INV_ROLE[$i]}" == "server" ]]; then
      install_on_target server "${INV_NAME[$i]}" "${INV_IP[$i]}"
    fi
  done

  for i in "${!INV_ROLE[@]}"; do
    if [[ "${INV_ROLE[$i]}" == "dashboard" ]]; then
      install_on_target dashboard "${INV_NAME[$i]}" "${INV_IP[$i]}" "${dport}"
    fi
  done

  for i in "${!INV_IP[@]}"; do
    if ! is_local_ip "${INV_IP[$i]}"; then
      remote_run_auto "${INV_IP[$i]}" --auto-role disable-repo || true
    else
      disable_repo || true
    fi
  done

  extract_passwords_to_credfile || true
  ok "Кластер установлен по инвентарю config.yml"
  show_status
}

menu_remote_hub() {
  hdr "Удалённая установка / выбор сервера"
  cat <<EOF
  a) Показать инвентарь (серверы из config.yml)
  b) Настроить SSH (user / port / ключ)
  c) Выбрать ОДИН сервер и действие (роль / prep / copy / start-cluster)
  d) Установить ВЕСЬ кластер удалённо по порядку
  e) Назад
EOF
  ask "Выбор" "c"
  case "${REPLY}" in
    a) show_inventory ;;
    b) configure_ssh_settings ;;
    c) menu_remote_one ;;
    d) menu_remote_full ;;
    e) return 0 ;;
    *) warn "Неизвестно" ;;
  esac
}

full_checklist() {
  hdr "Чеклист: заработает ли «сразу»?"
  cat <<EOF
По официальной документации Wazuh assisted install — ДА, если:

  1. Один wazuh-install-files.tar на всех узлах
  2. Имена = name из config.yml
  3. Порядок: generate → все indexer → --start-cluster → server → dashboard
  4. Порты / DNS или /etc/hosts
  5. Интернет до packages.wazuh.com (или offline)
  6. RAM Indexer ~16 GiB

Скрипт умеет:
  • локальную установку роли на текущем хосте
  • удалённую: выбор сервера из config.yml + роль, либо весь кластер по SSH

Агенты ставятся отдельно после Dashboard.
EOF
  show_status
}

# ---------------------------------------------------------------------------
# Auto mode (called over SSH)
# ---------------------------------------------------------------------------
run_auto_role() {
  AUTO_YES=1
  case "${AUTO_ROLE}" in
    prep) prepare_host ;;
    indexer)
      [[ -n "${AUTO_NODE_NAME}" ]] || { err "--node-name обязателен"; exit 1; }
      install_indexer "${AUTO_NODE_NAME}"
      ;;
    server)
      [[ -n "${AUTO_NODE_NAME}" ]] || { err "--node-name обязателен"; exit 1; }
      install_server "${AUTO_NODE_NAME}"
      ;;
    dashboard)
      [[ -n "${AUTO_NODE_NAME}" ]] || { err "--node-name обязателен"; exit 1; }
      install_dashboard "${AUTO_NODE_NAME}" "${AUTO_PORT}"
      ;;
    start-cluster) start_indexer_cluster ;;
    disable-repo) disable_repo ;;
    *) err "Неизвестная --auto-role ${AUTO_ROLE}"; exit 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
print_banner() {
  cat <<EOF
${BOLD}
╔══════════════════════════════════════════════════════════╗
║  Wazuh distributed installer — РЕД ОС 8 / RHEL-like     ║
║  Local + Remote SSH (выбор сервера и роли)               ║
║  Packages: ${WAZUH_MAJOR}                                           ║
╚══════════════════════════════════════════════════════════╝
${NC}
WORKDIR: ${WORKDIR}
CREDENTIALS: ${CRED_FILE}
SSH: ${SSH_USER}@… port ${SSH_PORT}
EOF
}

main_menu() {
  print_banner
  cat <<EOF

 ${BOLD}Подготовка (на админ / первом узле)${NC}
  1) Подготовить ЭТОТ хост
  2) Скачать wazuh-install.sh + config.yml
  3) Мастер config.yml (имена/IP всех серверов)
  4) Сгенерировать сертификаты и пароли
  5) Подсказка по копированию файлов
  6) Firewalld на ЭТОМ хосте

 ${BOLD}Установка на ЭТОМ сервере${NC}
  7) Indexer
  8) start-cluster (один раз)
  9) Server/Manager
 10) Dashboard

 ${BOLD}Удалённо: выбор сервера → что ставить${NC}
 15) Меню удалённой установки (SSH)
 16) Показать инвентарь серверов

 ${BOLD}После установки${NC}
 11) Сохранить креды в файл
 12) Отключить репо Wazuh (этот хост)
 13) Статус
 14) Чеклист

  0) Выход
EOF
  ask "Пункт меню" "15"
}

usage() {
  cat <<EOF
Usage:
  sudo bash $0                          # интерактивное меню
  sudo bash $0 --status
  sudo bash $0 --auto-role indexer --node-name node-1
  sudo bash $0 --auto-role server --node-name wazuh-1
  sudo bash $0 --auto-role dashboard --node-name dashboard --port 443
  sudo bash $0 --auto-role start-cluster
  sudo bash $0 --auto-role prep [--hostname NAME]
  sudo bash $0 --auto-role disable-repo

Env: WAZUH_MAJOR=4.14 WAZUH_WORKDIR=/root/wazuh-install
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --status) shift; need_root; ensure_dirs; load_ssh_settings; show_status; exit 0 ;;
      --auto-role) AUTO_ROLE="$2"; shift 2 ;;
      --node-name) AUTO_NODE_NAME="$2"; shift 2 ;;
      --port) AUTO_PORT="$2"; shift 2 ;;
      --hostname) AUTO_HOSTNAME="$2"; shift 2 ;;
      --no-firewall) AUTO_OPEN_FW=0; shift ;;
      *) err "Неизвестный аргумент: $1"; usage; exit 1 ;;
    esac
  done

  need_root
  ensure_dirs
  load_ssh_settings
  cd "${WORKDIR}"

  if [[ -n "${AUTO_ROLE}" ]]; then
    run_auto_role
    exit 0
  fi

  while true; do
    main_menu
    case "${REPLY}" in
      1) prepare_host; pause ;;
      2) download_assistant; pause ;;
      3) wizard_config_yml; pause ;;
      4) generate_config_files; pause ;;
      5) copy_hint; pause ;;
      6) configure_firewall_for_role; pause ;;
      7) install_indexer; pause ;;
      8) start_indexer_cluster; pause ;;
      9) install_server; pause ;;
      10) install_dashboard; pause ;;
      11) export_credentials_menu; pause ;;
      12) disable_repo; pause ;;
      13) show_status; pause ;;
      14) full_checklist; pause ;;
      15) menu_remote_hub; pause ;;
      16) show_inventory; pause ;;
      0) ok "Выход"; exit 0 ;;
      *) warn "Неизвестный пункт" ;;
    esac
  done
}

main "$@"
