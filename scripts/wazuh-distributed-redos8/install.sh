#!/usr/bin/env bash
# Interactive Wazuh distributed (multi-node) installer for RED OS 8 / RHEL-compatible.
# Wraps the official wazuh-install.sh assisted method (no Kubernetes).
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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
  # ask "Prompt" "default" -> sets REPLY
  local prompt="$1" default="${2:-}"
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
  local hint="y/n"
  [[ "${default}" == "y" ]] && hint="Y/n"
  [[ "${default}" == "n" ]] && hint="y/N"
  read -r -p "$(printf '%b' "${prompt} [${hint}]: ")" REPLY
  REPLY="${REPLY:-${default}}"
  [[ "${REPLY}" =~ ^[YyДд] ]]
}

pause() {
  read -r -p "Нажмите Enter для продолжения..." _
}

detect_primary_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
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

  if [[ -f "${TAR_FILE}" ]]; then
    local idx_ip admin_pw
    idx_ip="$(get_state LAST_INDEXER_IP "")"
    if [[ -z "${idx_ip}" ]] && [[ -f "${CONFIG_FILE}" ]]; then
      idx_ip="$(awk '/indexer:/{f=1} f&&/ip:/{gsub(/[" ]/,""); sub(/ip:/,""); print; exit}' "${CONFIG_FILE}" || true)"
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

# More reliable password extract matching Wazuh format:
#   # Password for wazuh API user
#   ...
#   # Admin user for the web user interface and Wazuh indexer
#   indexer_username: 'admin'
#   indexer_password: 'XXXX'
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
    local user pass
    user="$(awk -F"'" '/indexer_username:/{print $2; exit}' "${pw_file}")"
    pass="$(awk -F"'" '/indexer_password:/{print $2; exit}' "${pw_file}")"
    [[ -z "${user}" ]] && user="admin"
    echo "DASHBOARD_URL=https://$(get_state DASHBOARD_IP "$(detect_primary_ip)")"
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
# Prep
# ---------------------------------------------------------------------------
prepare_host() {
  hdr "Подготовка хоста (РЕД ОС 8 / RHEL-compatible)"
  info "Установка базовых пакетов и sysctl для Indexer..."

  if command -v dnf >/dev/null; then
    dnf -y install curl tar openssl firewalld chrony procps-ng 2>&1 | tee -a "${LOG_DIR}/prep.log"
  elif command -v yum >/dev/null; then
    yum -y install curl tar openssl firewalld chrony procps-ng 2>&1 | tee -a "${LOG_DIR}/prep.log"
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

  ask "Задать hostname для этой машины?" "$(hostname)"
  local hn="${REPLY}"
  if [[ -n "${hn}" ]]; then
    hostnamectl set-hostname "${hn}"
    ok "hostname = ${hn}"
  fi

  save_state PREP_DONE 1
  ok "Подготовка завершена"
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
  echo "4) Всё сразу (если роли совмещены — не рекомендуется)"
  ask "Выбор" "1"
  case "${REPLY}" in
    1)
      firewall-cmd --permanent --add-port=9200/tcp
      firewall-cmd --permanent --add-port=9300-9400/tcp
      ;;
    2)
      firewall-cmd --permanent --add-port=1514/tcp
      firewall-cmd --permanent --add-port=1515/tcp
      firewall-cmd --permanent --add-port=1516/tcp
      firewall-cmd --permanent --add-port=55000/tcp
      ;;
    3)
      firewall-cmd --permanent --add-port=443/tcp
      ask "Порт Dashboard если не 443" "443"
      firewall-cmd --permanent --add-port="${REPLY}/tcp"
      ;;
    4)
      firewall-cmd --permanent --add-port=9200/tcp
      firewall-cmd --permanent --add-port=9300-9400/tcp
      firewall-cmd --permanent --add-port=1514/tcp
      firewall-cmd --permanent --add-port=1515/tcp
      firewall-cmd --permanent --add-port=1516/tcp
      firewall-cmd --permanent --add-port=55000/tcp
      firewall-cmd --permanent --add-port=443/tcp
      ;;
    *) err "Неизвестный выбор"; return 1 ;;
  esac
  firewall-cmd --reload
  ok "Правила firewalld применены"
  firewall-cmd --list-ports || true
}

# ---------------------------------------------------------------------------
# Download assistant + wizard config.yml
# ---------------------------------------------------------------------------
download_assistant() {
  hdr "Скачивание официального Wazuh installation assistant (${WAZUH_MAJOR})"
  ensure_dirs
  cd "${WORKDIR}"
  ask "Базовый URL пакетов" "${PKG_BASE}"
  PKG_BASE="${REPLY}"
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
  echo "  1) Минимальная: 1 indexer + 1 server + 1 dashboard   (3 сервера)"
  echo "  2) Рекомендуемая HA: 3 indexer + 2 server + 1 dashboard (6 серверов)"
  echo "  3) Свой набор (укажете количество узлов)"
  ask "Топология" "2"
  local topo="${REPLY}"

  local n_idx=1 n_srv=1 n_dash=1
  case "${topo}" in
    1) n_idx=1; n_srv=1; n_dash=1 ;;
    2) n_idx=3; n_srv=2; n_dash=1 ;;
    3)
      ask "Сколько Indexer-узлов" "3"
      n_idx="${REPLY}"
      ask "Сколько Server-узлов" "2"
      n_srv="${REPLY}"
      ask "Сколько Dashboard-узлов" "1"
      n_dash="${REPLY}"
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
    ask "IP indexer #${i} (${idx_names[-1]})" "${def_ip}"
    idx_ips+=("${REPLY}")
  done

  hdr "Server (manager) узлы"
  for ((i=1; i<=n_srv; i++)); do
    ask "Имя server #${i}" "wazuh-${i}"
    srv_names+=("${REPLY}")
    ask "IP server #${i} (${srv_names[-1]})" "${def_ip}"
    srv_ips+=("${REPLY}")
    if (( n_srv > 1 )); then
      if (( i == 1 )); then
        ask "node_type для ${srv_names[-1]}" "master"
      else
        ask "node_type для ${srv_names[-1]}" "worker"
      fi
      srv_types+=("${REPLY}")
    else
      srv_types+=("")
    fi
  done

  hdr "Dashboard узлы"
  for ((i=1; i<=n_dash; i++)); do
    ask "Имя dashboard #${i}" "dashboard"
    dash_names+=("${REPLY}")
    ask "IP dashboard #${i} (${dash_names[-1]})" "${def_ip}"
    dash_ips+=("${REPLY}")
  done

  # Write config.yml
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

  # Optional /etc/hosts helper
  if ask_yn "Добавить эти имена/IP в /etc/hosts на ЭТОМ сервере?" "y"; then
    local marker="# wazuh-distributed-begin"
    local endmark="# wazuh-distributed-end"
    if grep -q "${marker}" /etc/hosts 2>/dev/null; then
      sed -i "/${marker}/,/${endmark}/d" /etc/hosts
    fi
    {
      echo "${marker}"
      for ((i=0; i<n_idx; i++)); do echo "${idx_ips[$i]}  ${idx_names[$i]}"; done
      for ((i=0; i<n_srv; i++)); do echo "${srv_ips[$i]}  ${srv_names[$i]}"; done
      for ((i=0; i<n_dash; i++)); do echo "${dash_ips[$i]}  ${dash_names[$i]}"; done
      echo "${endmark}"
    } >> /etc/hosts
    ok "/etc/hosts обновлён (блок wazuh-distributed)"
  fi

  warn "Скопируйте тот же блок /etc/hosts на остальные узлы (или настройте DNS)."
}

generate_config_files() {
  hdr "Генерация сертификатов и паролей (--generate-config-files)"
  cd "${WORKDIR}"
  [[ -f "${CONFIG_FILE}" ]] || { err "Сначала создайте config.yml (пункт меню)"; return 1; }
  [[ -f "${ASSISTANT}" ]] || { err "Нет wazuh-install.sh"; return 1; }

  if [[ -f "${TAR_FILE}" ]]; then
    warn "Уже есть ${TAR_FILE}"
    ask_yn "Перегенерировать? Старые сертификаты станут недействительны для уже установленных узлов." "n" || return 0
  fi

  bash "${ASSISTANT}" --generate-config-files 2>&1 | tee "${LOG_DIR}/generate-config-files.log"
  [[ -f "${TAR_FILE}" ]] || { err "Архив не создан"; return 1; }
  extract_passwords_to_credfile
  save_state GENERATED 1
  ok "Готово: ${TAR_FILE}"
  warn "Скопируйте на ВСЕ узлы кластера:"
  echo "  scp ${ASSISTANT} ${TAR_FILE} root@<OTHER_HOST>:${WORKDIR}/"
}

copy_hint() {
  hdr "Как разнести файлы на другие серверы"
  cat <<EOF
На ЭТОМ сервере уже должно быть:
  ${ASSISTANT}
  ${TAR_FILE}

На каждом другом узле:
  mkdir -p ${WORKDIR}
  # с машины где генерировали:
  scp ${ASSISTANT} ${TAR_FILE} root@IP_ДРУГОГО_УЗЛА:${WORKDIR}/

Либо скопируйте скрипт install.sh тоже:
  scp $(realpath "$0" 2>/dev/null || echo install.sh) root@IP:${WORKDIR}/

Затем на каждом узле:
  cd ${WORKDIR}
  bash install.sh
  → выберите роль этого сервера
EOF
}

# ---------------------------------------------------------------------------
# Install roles (current host)
# ---------------------------------------------------------------------------
install_indexer() {
  hdr "Установка Wazuh Indexer на ЭТОМ хосте"
  cd "${WORKDIR}"
  require_tar_and_assistant || return 1

  list_names_from_config indexer
  ask "Имя этого indexer-узла (как в config.yml)" "$(get_state THIS_INDEXER_NAME "node-1")"
  local name="${REPLY}"
  save_state THIS_INDEXER_NAME "${name}"
  save_state THIS_ROLE indexer

  if ask_yn "Открыть порты firewalld для Indexer?" "y"; then
    systemctl is-active --quiet firewalld && {
      firewall-cmd --permanent --add-port=9200/tcp
      firewall-cmd --permanent --add-port=9300-9400/tcp
      firewall-cmd --reload
    } || true
  fi

  info "Запуск: bash wazuh-install.sh --wazuh-indexer ${name}"
  bash "${ASSISTANT}" --wazuh-indexer "${name}" 2>&1 | tee "${LOG_DIR}/install-indexer-${name}.log"
  save_state INDEXER_INSTALLED 1
  ok "Indexer ${name} установлен"
  systemctl status wazuh-indexer --no-pager -l | head -20 || true
}

start_indexer_cluster() {
  hdr "Инициализация Indexer cluster (--start-cluster) — ОДИН раз на любом indexer"
  cd "${WORKDIR}"
  require_tar_and_assistant || return 1

  if ! systemctl is-active --quiet wazuh-indexer; then
    warn "wazuh-indexer не active на этой машине. Обычно --start-cluster запускают на indexer-узле."
    ask_yn "Продолжить всё равно?" "n" || return 1
  fi

  bash "${ASSISTANT}" --start-cluster 2>&1 | tee "${LOG_DIR}/start-cluster.log"
  save_state CLUSTER_STARTED 1
  extract_passwords_to_credfile || true

  local ip admin_pw
  ip="$(get_state LAST_INDEXER_IP "$(detect_primary_ip)")"
  ask "IP Indexer для проверки" "${ip}"
  ip="${REPLY}"
  admin_pw=""
  if [[ -f "${CRED_FILE}" ]]; then
    admin_pw="$(awk -F= '/^INDEXER_ADMIN_PASSWORD=/{print $2; exit}' "${CRED_FILE}")"
  fi
  if [[ -z "${admin_pw}" ]]; then
    admin_pw="$(extract_admin_password || true)"
  fi
  if [[ -z "${admin_pw}" ]]; then
    ask "Пароль admin (из ${CRED_FILE})" ""
    admin_pw="${REPLY}"
  fi
  info "curl https://${ip}:9200"
  curl -sk -u "admin:${admin_pw}" "https://${ip}:9200" | tee "${LOG_DIR}/indexer-health.json" || true
  echo
  curl -sk -u "admin:${admin_pw}" "https://${ip}:9200/_cat/nodes?v" | tee "${LOG_DIR}/indexer-nodes.txt" || true
  ok "start-cluster выполнен"
}

install_server() {
  hdr "Установка Wazuh Server (manager + Filebeat) на ЭТОМ хосте"
  cd "${WORKDIR}"
  require_tar_and_assistant || return 1

  list_names_from_config server
  ask "Имя этого server-узла (как в config.yml)" "$(get_state THIS_SERVER_NAME "wazuh-1")"
  local name="${REPLY}"
  save_state THIS_SERVER_NAME "${name}"
  save_state THIS_ROLE server

  if ask_yn "Открыть порты firewalld для Server?" "y"; then
    systemctl is-active --quiet firewalld && {
      firewall-cmd --permanent --add-port=1514/tcp
      firewall-cmd --permanent --add-port=1515/tcp
      firewall-cmd --permanent --add-port=1516/tcp
      firewall-cmd --permanent --add-port=55000/tcp
      firewall-cmd --reload
    } || true
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
  hdr "Установка Wazuh Dashboard на ЭТОМ хосте"
  cd "${WORKDIR}"
  require_tar_and_assistant || return 1

  list_names_from_config dashboard
  ask "Имя этого dashboard-узла (как в config.yml)" "$(get_state THIS_DASHBOARD_NAME "dashboard")"
  local name="${REPLY}"
  ask "TCP-порт UI" "443"
  local port="${REPLY}"
  save_state THIS_DASHBOARD_NAME "${name}"
  save_state THIS_ROLE dashboard
  save_state DASHBOARD_PORT "${port}"

  if ask_yn "Открыть порт ${port}/tcp в firewalld?" "y"; then
    systemctl is-active --quiet firewalld && {
      firewall-cmd --permanent --add-port="${port}/tcp"
      firewall-cmd --reload
    } || true
  fi

  info "Запуск: bash wazuh-install.sh --wazuh-dashboard ${name} -p ${port}"
  bash "${ASSISTANT}" --wazuh-dashboard "${name}" -p "${port}" 2>&1 | tee "${LOG_DIR}/install-dashboard-${name}.log"
  save_state DASHBOARD_INSTALLED 1
  extract_passwords_to_credfile || true

  local dip
  dip="$(detect_primary_ip)"
  save_state DASHBOARD_IP "${dip}"
  ok "Dashboard установлен"
  echo
  ok "Откройте: https://${dip}:${port}"
  if [[ -f "${CRED_FILE}" ]]; then
    grep -E '^(DASHBOARD_|INDEXER_ADMIN_)' "${CRED_FILE}" || true
    info "Полные креды: ${CRED_FILE}"
  fi
  systemctl status wazuh-dashboard --no-pager -l | head -15 || true
}

disable_repo() {
  hdr "Отключить автообновления репозитория Wazuh"
  if [[ -f /etc/yum.repos.d/wazuh.repo ]]; then
    sed -i "s/^enabled=1/enabled=0/" /etc/yum.repos.d/wazuh.repo
    ok "wazuh.repo: enabled=0"
    grep -E 'enabled=' /etc/yum.repos.d/wazuh.repo || true
  else
    warn "Файл /etc/yum.repos.d/wazuh.repo не найден (пакеты ещё не ставились?)"
  fi
  save_state REPO_DISABLED 1
}

require_tar_and_assistant() {
  [[ -f "${ASSISTANT}" ]] || { err "Нет ${ASSISTANT}. Сначала скачайте / скопируйте."; return 1; }
  [[ -f "${TAR_FILE}" ]] || { err "Нет ${TAR_FILE}. Сгенерируйте на первом узле и скопируйте сюда."; return 1; }
  return 0
}

list_names_from_config() {
  local section="$1"
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    warn "config.yml нет на этом узле (для установки роли не обязателен, нужен tar). Имя возьмите из вашего config.yml."
    return 0
  fi
  info "Имена из config.yml (секция ${section}):"
  awk -v sec="${section}" '
    $1 == sec":" { insec=1; next }
    insec && /^  [a-zA-Z]/ { exit }
    insec && /name:/ {
      line=$0
      sub(/.*name:[ \t]*/, "", line)
      gsub(/["'\'']/, "", line)
      gsub(/[ \t]/, "", line)
      print "  - " line
    }
  ' "${CONFIG_FILE}"
}

export_credentials_menu() {
  hdr "Сохранить / показать креды"
  if [[ ! -f "${TAR_FILE}" ]]; then
    err "Нет ${TAR_FILE}"
    return 1
  fi
  extract_passwords_to_credfile
  echo
  if ask_yn "Показать ${CRED_FILE} на экране?" "n"; then
    cat "${CRED_FILE}"
  else
    info "Файл: ${CRED_FILE} (chmod 600)"
  fi
}

full_checklist() {
  hdr "Чеклист: заработает ли «сразу»?"
  cat <<EOF
По официальной документации Wazuh assisted install — ДА, если соблюдены условия:

  1. На ВСЕХ узлах один и тот же wazuh-install-files.tar (из одного --generate-config-files)
  2. Имена при --wazuh-indexer / --wazuh-server / --wazuh-dashboard = name из config.yml
  3. Порядок:
       generate → (скопировать tar) → ВСЕ indexer → --start-cluster (1 раз)
       → все server → dashboard
  4. Сеть: порты открыты между узлами (см. docs)
  5. Интернет до packages.wazuh.com (или offline-пакеты)
  6. Достаточно RAM/CPU (Indexer рекомендуется 16 GiB)

НЕ заработает «само» одним кликом на все 6 серверов:
  скрипт ставит роль на ТЕКУЩИЙ хост. На каждом сервере — свой запуск меню.

РЕД ОС 8: официально в списке Wazuh — RHEL 8. РЕД ОС совместим как RHEL-like;
  редко возможны отличия зависимостей/SELinux — смотрите логи в ${LOG_DIR}/

После Dashboard UI откроется сразу; агенты — отдельный шаг (Deploy new agent).
EOF
  show_status
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
print_banner() {
  cat <<EOF
${BOLD}
╔══════════════════════════════════════════════════════════╗
║  Wazuh distributed installer — РЕД ОС 8 / RHEL-like     ║
║  Official assistant wrapper (без Kubernetes)             ║
║  Packages: ${WAZUH_MAJOR}                                           ║
╚══════════════════════════════════════════════════════════╝
${NC}
WORKDIR: ${WORKDIR}
CREDENTIALS FILE: ${CRED_FILE}
EOF
}

main_menu() {
  print_banner
  cat <<EOF

 ${BOLD}Подготовка (обычно на первом indexer / админ-хосте)${NC}
  1) Подготовить хост (пакеты, chrony, sysctl, hostname)
  2) Скачать wazuh-install.sh + config.yml
  3) Мастер: заполнить config.yml (имена/IP узлов)
  4) Сгенерировать сертификаты и пароли (--generate-config-files)
  5) Подсказка: как скопировать файлы на другие серверы
  6) Настроить firewalld под роль

 ${BOLD}Установка роли на ЭТОМ сервере${NC}
  7) Установить Indexer (--wazuh-indexer)
  8) Инициализировать Indexer cluster (--start-cluster)  ← один раз
  9) Установить Server/Manager (--wazuh-server)
 10) Установить Dashboard (--wazuh-dashboard)

 ${BOLD}После установки${NC}
 11) Сохранить креды в отдельный файл
 12) Отключить репозиторий Wazuh (анти-автоапгрейд)
 13) Показать статус
 14) Чеклист «заработает ли сразу?»

  0) Выход
EOF
  ask "Пункт меню" "13"
}

main() {
  # Non-interactive shortcuts (до проверки root)
  case "${1:-}" in
    --help|-h)
      echo "Usage: sudo bash $0"
      echo "Env: WAZUH_MAJOR=4.14 WAZUH_WORKDIR=/root/wazuh-install"
      echo "     sudo bash $0 --status"
      exit 0
      ;;
  esac

  need_root
  ensure_dirs
  cd "${WORKDIR}"

  case "${1:-}" in
    --status) show_status; exit 0 ;;
  esac

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
      0) ok "Выход"; exit 0 ;;
      *) warn "Неизвестный пункт" ;;
    esac
  done
}

main "$@"
