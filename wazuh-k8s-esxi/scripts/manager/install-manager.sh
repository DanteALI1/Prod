#!/usr/bin/env bash
# Deploy Wazuh Indexer + Manager into the cluster (run on CP / admin host)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config

BACKUP_ONLY=false
for arg in "$@"; do
  case "${arg}" in
    --backup-only) BACKUP_ONLY=true ;;
  esac
done

require_root_or_kube() {
  if [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -f /etc/kubernetes/admin.conf ]]; then
      export KUBECONFIG=/etc/kubernetes/admin.conf
    elif [[ -f "${HOME}/.kube/config" ]]; then
      export KUBECONFIG="${HOME}/.kube/config"
    fi
  fi
  if [[ ! -f "${KUBECONFIG:-/dev/null}" ]]; then
    die "Need valid kubeconfig (set KUBECONFIG or run on control-plane)"
  fi
  require_cmd kubectl
}

preflight() {
  kubectl cluster-info >/dev/null || die "kubectl cannot reach cluster"
  local idx_count
  idx_count="$(kubectl get nodes -l wazuh.role=indexer --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if (( idx_count < 3 )); then
    die "Need 3 nodes labeled wazuh.role=indexer (have ${idx_count}). Run scripts/common/label-nodes.sh first."
  fi
  local wrk
  wrk="$(kubectl get nodes -l wazuh.role=general --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if (( wrk < 1 )); then
    warn "No nodes with wazuh.role=general — labeling non-indexer workers"
    local cp_name
    cp_name="$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    while read -r n; do
      n="${n#node/}"
      [[ -z "${n}" ]] && continue
      local role
      role="$(kubectl get node "${n}" -o jsonpath='{.metadata.labels.wazuh\.role}' 2>/dev/null || true)"
      if [[ "${role}" == "indexer" ]]; then
        continue
      fi
      if [[ -n "${cp_name}" && "${n}" == "${cp_name}" ]]; then
        continue
      fi
      kubectl label node "${n}" wazuh.role=general --overwrite || true
    done < <(kubectl get nodes -o name)
  fi
  kubectl get ns "${WAZUH_NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${WAZUH_NAMESPACE}"
  generate_cluster_key
  log "Preflight OK (indexer nodes=${idx_count})"
}

ensure_helm() {
  if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  require_cmd helm
}

ensure_git() {
  if ! command -v git >/dev/null 2>&1; then
    detect_os
    # shellcheck disable=SC2086
    install_packages git || warn "git not installed — official repo git-fetch will be skipped"
  fi
}

# -----------------------------------------------------------------------------
# Скачивание официального wazuh/wazuh-kubernetes БЕЗ отпечатка .git на диске
# ПОМЕТКА: по умолчанию — tarball с GitHub (нет remote, нет .git, нет credentials).
#   WAZUH_K8S_FETCH_METHOD=tarball|git|skip
#   work dir: /var/tmp/wazuh-kubernetes (см. WAZUH_K8S_WORKDIR)
# -----------------------------------------------------------------------------
_wazuh_k8s_tag_ref() {
  # v4.9.2 → tags/v4.9.2 ; main → heads не используем — ждём тег
  local tag="${WAZUH_K8S_TAG:-v4.9.2}"
  echo "${tag}"
}

fetch_wazuh_kubernetes_tarball() {
  local work="$1"
  local tag
  tag="$(_wazuh_k8s_tag_ref)"
  local url="https://github.com/wazuh/wazuh-kubernetes/archive/refs/tags/${tag}.tar.gz"
  local tmp
  tmp="$(mktemp /var/tmp/wazuh-k8s-XXXXXX.tar.gz)"
  log "Скачивание upstream Wazuh (tarball, без .git): ${url}"
  if ! curl -fsSL "${url}" -o "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  rm -rf "${work}"
  mkdir -p "${work}"
  # archive root: wazuh-kubernetes-4.9.2/ (без префикса v в имени каталога часто)
  if ! tar -xzf "${tmp}" -C "${work}" --strip-components=1; then
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
  # страховка: никогда не оставляем .git от tarball (его там и нет)
  rm -rf "${work}/.git"
  log "Upstream Wazuh распакован в ${work} (без .git)"
  return 0
}

fetch_wazuh_kubernetes_git() {
  local work="$1"
  ensure_git
  command -v git >/dev/null 2>&1 || return 1
  local tag
  tag="$(_wazuh_k8s_tag_ref)"
  log "Скачивание upstream Wazuh через git clone --depth 1 (ветка/тег ${tag})"
  # ПОМЕТКА: URL только публичный https://... без токена в строке
  if [[ -d "${work}/.git" ]]; then
    log "Каталог ${work} уже с .git — обновление не делаем (идемпотентность)"
  else
    rm -rf "${work}"
    git clone --depth 1 --branch "${tag}" "${WAZUH_K8S_GIT}" "${work}" || return 1
  fi
  # Снять отпечаток: remote + сам .git (на prod история upstream не нужна)
  if [[ "${WAZUH_K8S_STRIP_GIT:-true}" == "true" ]]; then
    rm -rf "${work}/.git"
    log "Удалён ${work}/.git — отпечатка git remote на диске нет"
  else
    git -C "${work}" remote remove origin 2>/dev/null \
      || git -C "${work}" remote set-url origin "https://github.com/wazuh/wazuh-kubernetes.git" 2>/dev/null \
      || true
    warn "WAZUH_K8S_STRIP_GIT=false — .git оставлен (только для отладки)"
  fi
  return 0
}

fetch_wazuh_kubernetes() {
  local work="${WAZUH_K8S_WORKDIR:-/var/tmp/wazuh-kubernetes}"
  local method="${WAZUH_K8S_FETCH_METHOD:-tarball}"

  case "${method}" in
    skip|none|local)
      log "WAZUH_K8S_FETCH_METHOD=${method} — upstream не скачивается, только локальные manifests"
      return 0
      ;;
    tarball|tar|archive)
      if [[ -d "${work}" && ! -d "${work}/.git" && -f "${work}/README.md" ]]; then
        log "Upstream уже есть без .git: ${work} — skip download"
        return 0
      fi
      if fetch_wazuh_kubernetes_tarball "${work}"; then
        return 0
      fi
      warn "Tarball upstream не скачался — пробуем git clone"
      fetch_wazuh_kubernetes_git "${work}" || warn "Clone upstream failed — дальше только локальные manifests"
      ;;
    git|clone)
      fetch_wazuh_kubernetes_git "${work}" || warn "Clone upstream failed — дальше только локальные manifests"
      ;;
    *)
      die "Unknown WAZUH_K8S_FETCH_METHOD=${method} (tarball|git|skip)"
      ;;
  esac
}

apply_storage() {
  log "Applying StorageClass / PV manifests (hostnames from cluster.env)"
  local out
  out="$(render_storage_pvs)"
  kubectl apply -f "${out}/"
  if [[ -d "${ROOT_DIR}/manifests/network" ]]; then
    log "Applying NetworkPolicies (review agent CIDR before production)"
    kubectl apply -f "${ROOT_DIR}/manifests/network/" || warn "NetworkPolicy apply failed (CNI may lack support)"
  fi
}

create_secrets() {
  if kubectl -n "${WAZUH_NAMESPACE}" get secret wazuh-credentials >/dev/null 2>&1; then
    log "Secret wazuh-credentials exists — skip create"
  else
    # cluster-key → env WAZUH_CLUSTER_KEY в подах (образ подставит в ossec.conf)
    kubectl -n "${WAZUH_NAMESPACE}" create secret generic wazuh-credentials \
      --from-literal=indexer-user="${INDEXER_ADMIN_USER}" \
      --from-literal=indexer-password="${INDEXER_ADMIN_PASSWORD}" \
      --from-literal=api-user="${WAZUH_API_USER}" \
      --from-literal=api-password="${WAZUH_API_PASSWORD}" \
      --from-literal=dashboard-password="${DASHBOARD_PASSWORD}" \
      --from-literal=cluster-key="${WAZUH_CLUSTER_KEY}"
  fi
}

# ConfigMap wazuh-conf: master.conf + worker.conf с блоком <cluster>
# Источник: upstream tarball (если скачан) или вендор в manifests/manager/wazuh_conf/
apply_manager_cluster_configmap() {
  local work="${WAZUH_K8S_WORKDIR:-/var/tmp/wazuh-kubernetes}"
  local out="${ROOT_DIR}/manifests/.rendered/wazuh_conf"
  local src_master src_worker
  mkdir -p "${out}"

  if [[ -f "${work}/wazuh/wazuh_managers/wazuh_conf/master.conf" ]]; then
    log "ossec.conf: берём из upstream tarball ${work}"
    src_master="${work}/wazuh/wazuh_managers/wazuh_conf/master.conf"
    src_worker="${work}/wazuh/wazuh_managers/wazuh_conf/worker.conf"
  else
    log "ossec.conf: берём вендор manifests/manager/wazuh_conf/ (upstream не скачан)"
    src_master="${ROOT_DIR}/manifests/manager/wazuh_conf/master.conf"
    src_worker="${ROOT_DIR}/manifests/manager/wazuh_conf/worker.conf"
  fi
  [[ -f "${src_master}" && -f "${src_worker}" ]] \
    || die "Нет master.conf/worker.conf — кластер Manager не собрать"

  # DNS master в <nodes>: wazuh-manager-master-0.wazuh-cluster.<ns>
  sed -e "s/wazuh-manager-master-0\.wazuh-cluster\.wazuh/wazuh-manager-master-0.wazuh-cluster.${WAZUH_NAMESPACE}/g" \
      -e "s/wazuh-manager-master-0\.wazuh-cluster\.__NAMESPACE__/wazuh-manager-master-0.wazuh-cluster.${WAZUH_NAMESPACE}/g" \
      "${src_master}" >"${out}/master.conf"
  sed -e "s/wazuh-manager-master-0\.wazuh-cluster\.wazuh/wazuh-manager-master-0.wazuh-cluster.${WAZUH_NAMESPACE}/g" \
      -e "s/wazuh-manager-master-0\.wazuh-cluster\.__NAMESPACE__/wazuh-manager-master-0.wazuh-cluster.${WAZUH_NAMESPACE}/g" \
      "${src_worker}" >"${out}/worker.conf"

  # Ключ остаётся to_be_replaced_by_cluster_key — подставит entrypoint образа из WAZUH_CLUSTER_KEY
  grep -q 'to_be_replaced_by_cluster_key' "${out}/master.conf" \
    || warn "В master.conf нет placeholder ключа — проверьте <cluster><key>"
  grep -q '<node_type>master</node_type>' "${out}/master.conf" \
    || die "master.conf без node_type=master"
  grep -q '<node_type>worker</node_type>' "${out}/worker.conf" \
    || die "worker.conf без node_type=worker"

  kubectl -n "${WAZUH_NAMESPACE}" create configmap wazuh-conf \
    --from-file=master.conf="${out}/master.conf" \
    --from-file=worker.conf="${out}/worker.conf" \
    --dry-run=client -o yaml | kubectl apply -f -
  log "ConfigMap wazuh-conf применён (сбор Manager-кластера по ossec.conf + WAZUH_CLUSTER_KEY)"
}

render_and_apply_manifests() {
  local out="${ROOT_DIR}/manifests/.rendered"
  mkdir -p "${out}"
  local f
  for f in \
    "${ROOT_DIR}/manifests/indexer/statefulset-indexer.yaml" \
    "${ROOT_DIR}/manifests/manager/statefulset-manager-master.yaml" \
    "${ROOT_DIR}/manifests/manager/statefulset-manager-worker.yaml" \
    "${ROOT_DIR}/manifests/manager/services.yaml"
  do
    [[ -f "${f}" ]] || die "Missing manifest ${f}"
    local base
    base="$(basename "${f}")"
    sed \
      -e "s|__NAMESPACE__|${WAZUH_NAMESPACE}|g" \
      -e "s|__WAZUH_VERSION__|${WAZUH_VERSION}|g" \
      -e "s|__CLUSTER_KEY__|${WAZUH_CLUSTER_KEY}|g" \
      -e "s|__INDEXER_PASSWORD__|${INDEXER_ADMIN_PASSWORD}|g" \
      -e "s|__API_PASSWORD__|${WAZUH_API_PASSWORD}|g" \
      "${f}" >"${out}/${base}"
    # Защита: в STS должен быть WAZUH_CLUSTER_KEY, не устаревший CLUSTER_KEY
    if [[ "${base}" == statefulset-manager-*.yaml ]]; then
      grep -q 'name: WAZUH_CLUSTER_KEY' "${out}/${base}" \
        || die "${base}: нет env WAZUH_CLUSTER_KEY — кластер Manager не соберётся"
      grep -q 'wazuh-conf' "${out}/${base}" \
        || die "${base}: нет mount ConfigMap wazuh-conf"
    fi
    kubectl apply -f "${out}/${base}"
  done
}

deploy_via_official_repo() {
  # ПОМЕТКА: tarball upstream нужен для эталонных ossec.conf (блок <cluster>).
  # Сами STS/SVC — локальные hardened manifests. См. docs/cluster-assembly.md
  local work="${WAZUH_K8S_WORKDIR:-/var/tmp/wazuh-kubernetes}"
  fetch_wazuh_kubernetes
  if [[ -d "${work}/.git" ]]; then
    warn "Внимание: ${work}/.git на диске. Задайте WAZUH_K8S_STRIP_GIT=true"
  elif [[ -d "${work}/wazuh" ]]; then
    log "Upstream at ${work} (без .git) — conf для Manager-кластера доступен"
  fi
  apply_storage
  create_secrets
  apply_manager_cluster_configmap
  render_and_apply_manifests
}

wait_ready() {
  log "Waiting for Indexer pods..."
  kubectl -n "${WAZUH_NAMESPACE}" rollout status statefulset/wazuh-indexer --timeout=600s || die "Indexer not Ready"
  log "Waiting for Manager master..."
  kubectl -n "${WAZUH_NAMESPACE}" rollout status statefulset/wazuh-manager-master --timeout=600s || die "Manager master not Ready"
  log "Waiting for Manager worker..."
  kubectl -n "${WAZUH_NAMESPACE}" rollout status statefulset/wazuh-manager-worker --timeout=600s || warn "Manager worker not Ready yet"
}

backup_manager_config() {
  local dest="${1:-/var/backups/wazuh}"
  mkdir -p "${dest}"
  local ts file pod
  ts="$(date +%Y%m%d-%H%M%S)"
  file="${dest}/wazuh-manager-conf-${ts}.tgz"
  pod="$(kubectl -n "${WAZUH_NAMESPACE}" get pods -l app=wazuh-manager,node-type=master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod}" ]]; then
    pod="$(kubectl -n "${WAZUH_NAMESPACE}" get pods -o name 2>/dev/null | grep manager-master | head -1 | cut -d/ -f2 || true)"
  fi
  [[ -n "${pod}" ]] || die "Manager master pod not found"
  if kubectl -n "${WAZUH_NAMESPACE}" exec "${pod}" -- \
      tar czf - -C / var/ossec/etc/rules var/ossec/etc/decoders var/ossec/etc/shared var/ossec/etc/ossec.conf \
      >"${file}" 2>/tmp/wazuh-bk.err; then
    log "Backup written: ${file}"
  else
    # Paths inside image may differ — try absolute with ignore-failed
    kubectl -n "${WAZUH_NAMESPACE}" exec "${pod}" -- \
      sh -c 'tar czf - /var/ossec/etc/rules /var/ossec/etc/decoders /var/ossec/etc/shared /var/ossec/etc/ossec.conf 2>/dev/null' \
      >"${file}" || die "Backup failed: $(cat /tmp/wazuh-bk.err 2>/dev/null || true)"
    log "Backup written: ${file}"
  fi
  rm -f /tmp/wazuh-bk.err
}

# --- main ---
require_root_or_kube
if [[ "${BACKUP_ONLY}" == "true" ]]; then
  backup_manager_config
  exit 0
fi
preflight
ensure_helm
deploy_via_official_repo
wait_ready
backup_manager_config
log "Manager + Indexer deploy finished"
log "Next: scripts/dashboard/install-dashboard.sh && scripts/archiving/setup-archiving.sh"
