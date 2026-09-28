#!/usr/bin/env bash
# =============================================================================
# Wazuh on Kubernetes (ESXi) — ОБЩИЙ скрипт установки с нуля
# =============================================================================
#
# Назначение
# ----------
# Единая точка входа для пустого сервера (только что развёрнутая ВМ с
# РЕД ОС 8 / Astra Linux / Ubuntu 22.04). В начале выбирается роль (под/нода),
# затем вызывается соответствующий идемпотентный скрипт из scripts/.
#
# Пометки (как пользоваться)
# --------------------------
# 1. На КАЖДОЙ ВМ заранее:
#    - поставить минимальную ОС;
#    - задать hostname + статический IP;
#    - прописать /etc/hosts (или DNS) на все 6 узлов;
#    - доставить пакет wazuh-k8s-esxi/ БЕЗ отпечатка GitHub-токена
#      (архив/scp без .git — см. docs/git-clone-clean.md);
#    - заполнить config/cluster.env (IP, пароли, диски /dev/sdb, /dev/sdc).
#
# 2. Рекомендуемый конфиг на узле:
#      sudo mkdir -p /etc/wazuh-k8s
#      sudo cp config/cluster.env /etc/wazuh-k8s/cluster.env
#      sudo nano /etc/wazuh-k8s/cluster.env
#      export WAZUH_K8S_ENV=/etc/wazuh-k8s/cluster.env
#
# 3. Запуск (интерактивное меню):
#      sudo -E bash scripts/install.sh
#
# 4. Запуск без меню (для автоматизации):
#      sudo -E bash scripts/install.sh --role control-plane
#      sudo -E bash scripts/install.sh -r worker
#      sudo -E bash scripts/install.sh indexer
#
# 5. Порядок ролей по кластеру (строго):
#      control-plane  →  worker ×2  →  indexer ×3
#      → labels  →  manager  →  dashboard  →  archiving
#
# 6. DRY_RUN=true — только лог действий, без изменений.
#
# Целевые ОС: РЕД ОС 8 | Astra Linux | Ubuntu 22.04
# Подробности: docs/os-redos-astra.md , docs/pods-resources-simple.md
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# -----------------------------------------------------------------------------
# Пометки: соответствие «роль в меню» → «где запускать» → «что ставится»
# -----------------------------------------------------------------------------
# control-plane  | ВМ k8s-cp-01              | kubeadm init, Calico, kubectl
# worker         | ВМ k8s-worker-01/02       | join в кластер (Manager/Dashboard)
# indexer        | ВМ k8s-indexer-01/02/03   | join + диск данных 2 ТиБ
# labels         | только с control-plane    | labels/taints на ноды
# manager        | только с control-plane    | поды Indexer×3 + Manager master/worker
# dashboard      | только с control-plane    | под wazuh-dashboard
# archiving      | только с control-plane    | ISM + snapshot repository
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Использование:
  sudo -E bash scripts/install.sh                 # меню выбора роли
  sudo -E bash scripts/install.sh --role <имя>    # без меню
  sudo -E bash scripts/install.sh -r <имя>
  sudo -E bash scripts/install.sh <имя>           # коротко
  sudo -E bash scripts/install.sh --list          # список ролей
  sudo -E bash scripts/install.sh --help

Роли (под / шаг установки):
  control-plane   — первая ВМ: Kubernetes API / etcd
  worker          — worker-ноды под поды Manager и Dashboard
  indexer         — dedicated-ноды под поды wazuh-indexer-*
  labels          — метки/taints после join всех нод (с CP)
  manager         — деплой подов Indexer + Manager (с CP)
  dashboard       — деплой пода Dashboard (с CP)
  archiving       — ISM / архивы (с CP)

Переменные окружения:
  WAZUH_K8S_ENV   — путь к cluster.env
  DRY_RUN=true    — только показать действия
  ASSUME_YES=true — без подтверждения [y/N]
EOF
}

list_roles() {
  cat <<'EOF'
Доступные роли:
  1) control-plane
  2) worker
  3) indexer
  4) labels
  5) manager
  6) dashboard
  7) archiving
EOF
}

# Ранний разбор --help/--list без root и без load_config (пометка: можно смотреть справку без sudo)
for _early in "$@"; do
  case "${_early}" in
    -h|--help|help) usage; exit 0 ;;
    -l|--list|list) list_roles; exit 0 ;;
  esac
done

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common/lib.sh"
load_config

# Печать краткой «карточки» роли перед запуском (пометки для оператора)
print_role_banner() {
  local role="$1"
  echo
  echo "================================================================="
  echo "  Роль: ${role}"
  echo "  Хост: $(hostname)   Дата: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "  Пакет: ${ROOT_DIR}"
  echo "  Конфиг: ${WAZUH_K8S_ENV:-авто (config/cluster.env или /etc/wazuh-k8s/)}"
  echo "  DRY_RUN=${DRY_RUN:-false}"
  echo "================================================================="
  case "${role}" in
    control-plane)
      cat <<'EOF'
  ПОМЕТКА: запускать ТОЛЬКО на k8s-cp-01 (4 vCPU / 8 GiB).
  Скрипт на пустой ОС поставит: curl, lvm2, containerd, kubeadm, Calico.
  После успеха СОХРАНИТЕ KUBEADM_TOKEN и KUBEADM_HASH в cluster.env
  (строки печатаются в конце install-control-plane.sh).
EOF
      ;;
    worker)
      cat <<'EOF'
  ПОМЕТКА: запускать на k8s-worker-01 и k8s-worker-02 (8 vCPU / 16 GiB).
  Нужны уже заполненные KUBEADM_TOKEN и KUBEADM_HASH в cluster.env.
  После join всех нод — с CP выполните роль «labels».
EOF
      ;;
    indexer)
      cat <<'EOF'
  ПОМЕТКА: запускать на k8s-indexer-01..03 (8 vCPU / 32 GiB + диск /dev/sdc).
  INDEXER_DATA_DISK в cluster.env должен указывать на data-диск (обычно /dev/sdc).
  После join — с CP роль «labels» (taint wazuh-indexer=true:NoSchedule).
EOF
      ;;
    labels)
      cat <<'EOF'
  ПОМЕТКА: только с control-plane, когда ВСЕ 5 worker/indexer уже в кластере.
  Ставит wazuh.role=general|indexer и taint на indexer-ноды.
EOF
      ;;
    manager)
      cat <<'EOF'
  ПОМЕТКА: только с control-plane. Деплоит поды:
    wazuh-indexer-0..2 , wazuh-manager-master-0 , wazuh-manager-worker-0
  Перед этим обязательна роль «labels».
EOF
      ;;
    dashboard)
      cat <<'EOF'
  ПОМЕТКА: только с control-plane, после успешного Manager/Indexer.
  Деплоит под wazuh-dashboard (NodePort 31443 по умолчанию).
EOF
      ;;
    archiving)
      cat <<'EOF'
  ПОМЕТКА: только с control-plane. Настраивает ISM (14д hot / 90д snapshot)
  и snapshot repository (NFS/S3 из cluster.env). См. docs + ism-policy.json.
EOF
      ;;
  esac
  echo "-----------------------------------------------------------------"
  echo
}

# Интерактивный выбор роли (под) в начале общего скрипта
select_role_menu() {
  # Если нет TTY (pipe/CI) — не зависаем, требуем --role
  if [[ ! -t 0 ]]; then
    die "Нет интерактивного терминала. Укажите роль: --role control-plane|worker|indexer|labels|manager|dashboard|archiving"
  fi

  cat <<'EOF'

╔══════════════════════════════════════════════════════════════════╗
║     Wazuh K8s (ESXi) — установка на пустой сервер                ║
║     Выберите роль / под для ЭТОЙ ВМ                              ║
╚══════════════════════════════════════════════════════════════════╝

  Порядок по кластеру:
    [1] control-plane  →  [2] worker  →  [3] indexer
    → [4] labels  →  [5] manager  →  [6] dashboard  →  [7] archiving

  1) control-plane   — ВМ управления Kubernetes (k8s-cp-01)
  2) worker          — worker-нода под Manager / Dashboard
  3) indexer         — нода под поды wazuh-indexer-* (+ data-диск)
  4) labels          — метки нод (запускать с CP)
  5) manager         — поды Indexer + Manager (с CP)
  6) dashboard       — под Dashboard (с CP)
  7) archiving       — ISM / архивы (с CP)
  0) выход

EOF
  local choice
  read -r -p "Номер или имя роли: " choice
  case "${choice}" in
    0|q|Q|exit|quit) log "Выход без изменений"; exit 0 ;;
    1|control-plane|cp) ROLE="control-plane" ;;
    2|worker|w)         ROLE="worker" ;;
    3|indexer|idx)      ROLE="indexer" ;;
    4|labels|label)     ROLE="labels" ;;
    5|manager|mgr)      ROLE="manager" ;;
    6|dashboard|dash)   ROLE="dashboard" ;;
    7|archiving|archive|ism) ROLE="archiving" ;;
    *)
      die "Неизвестный выбор: «${choice}». Используйте --list или --help"
      ;;
  esac
}

# Подтверждение перед разрушительными/долгими операциями на «голой» ОС
confirm_run() {
  local role="$1"
  if [[ "${ASSUME_YES:-false}" == "true" || "${YES:-false}" == "true" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    return 0
  fi
  local ans
  read -r -p "Запустить установку роли «${role}» на $(hostname)? [y/N]: " ans
  case "${ans}" in
    y|Y|yes|YES|д|Д|да|ДА) return 0 ;;
    *) die "Отменено оператором" ;;
  esac
}

# Диспетчер: делегируем в существующие идемпотентные скрипты
run_role() {
  local role="$1"
  local target=""

  case "${role}" in
    control-plane)
      target="${SCRIPT_DIR}/control-plane/install-control-plane.sh"
      ;;
    worker)
      target="${SCRIPT_DIR}/worker/install-worker.sh"
      ;;
    indexer)
      target="${SCRIPT_DIR}/indexer/install-indexer.sh"
      ;;
    labels)
      target="${SCRIPT_DIR}/common/label-nodes.sh"
      ;;
    manager)
      target="${SCRIPT_DIR}/manager/install-manager.sh"
      ;;
    dashboard)
      target="${SCRIPT_DIR}/dashboard/install-dashboard.sh"
      ;;
    archiving)
      target="${SCRIPT_DIR}/archiving/setup-archiving.sh"
      ;;
    *)
      die "Внутренняя ошибка: неизвестная роль «${role}»"
      ;;
  esac

  [[ -f "${target}" ]] || die "Скрипт не найден: ${target}"
  [[ -x "${target}" ]] || chmod +x "${target}" || true

  print_role_banner "${role}"
  confirm_run "${role}"

  log ">>> Старт: ${target}"
  # Передаём окружение (WAZUH_K8S_ENV, DRY_RUN, пароли) дочернему скрипту
  # shellcheck disable=SC2086
  bash "${target}" ${EXTRA_ARGS:-}
  log "<<< Готово: роль «${role}» на $(hostname)"
}

# -----------------------------------------------------------------------------
# Разбор аргументов
# -----------------------------------------------------------------------------
ROLE=""
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help)
      usage
      exit 0
      ;;
    -l|--list|list)
      list_roles
      exit 0
      ;;
    -r|--role)
      shift
      [[ $# -gt 0 ]] || die "--role требует значение"
      ROLE="$1"
      shift
      ;;
    -y|--yes)
      export ASSUME_YES=true
      shift
      ;;
    --)
      shift
      EXTRA_ARGS="$*"
      break
      ;;
    control-plane|worker|indexer|labels|manager|dashboard|archiving)
      ROLE="$1"
      shift
      ;;
    cp) ROLE="control-plane"; shift ;;
    w)  ROLE="worker"; shift ;;
    idx|indexer-node) ROLE="indexer"; shift ;;
    label) ROLE="labels"; shift ;;
    mgr) ROLE="manager"; shift ;;
    dash) ROLE="dashboard"; shift ;;
    archive|ism) ROLE="archiving"; shift ;;
    *)
      die "Неизвестный аргумент: $1 (см. --help)"
      ;;
  esac
done

# Нормализация синонимов
case "${ROLE}" in
  "" ) ;;
  control-plane|worker|indexer|labels|manager|dashboard|archiving) ;;
  cp) ROLE="control-plane" ;;
  *)
    die "Неизвестная роль: «${ROLE}». Допустимо: control-plane worker indexer labels manager dashboard archiving"
    ;;
esac

require_root

# Если роль не передана — меню выбора «конкретного пода» в начале
if [[ -z "${ROLE}" ]]; then
  select_role_menu
fi

run_role "${ROLE}"
