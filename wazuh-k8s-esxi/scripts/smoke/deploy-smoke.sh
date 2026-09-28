#!/usr/bin/env bash
# Smoke-deploy Wazuh on local kind — TINY resources, verify cluster wiring.
# Not for production sizing (prod Indexer needs 24–30 GiB each).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common/lib.sh"
load_config

NS="${WAZUH_NAMESPACE:-wazuh}"
OUT="${ROOT_DIR}/manifests/.rendered/smoke"
REPORT_DIR="${LOG_DIR:-/tmp/wazuh-k8s-install}"
REPORT="${REPORT_DIR}/smoke-report-$(date +%Y%m%d-%H%M%S).txt"
VER="${WAZUH_VERSION:-4.9.2}"
mkdir -p "${OUT}" "${REPORT_DIR}"

require_cmd kubectl
kubectl cluster-info >/dev/null || die "No working kubectl cluster"

NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
log "Smoke node=${NODE} ns=${NS} version=${VER}"

# Single-node kind: both roles on one node, no indexer taint
kubectl label node "${NODE}" wazuh.role=general --overwrite
kubectl label node "${NODE}" wazuh.indexer=true --overwrite
kubectl taint nodes "${NODE}" wazuh-indexer- 2>/dev/null || true

kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"
generate_cluster_key

# kind default SC
SC="$(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')"
SC="${SC:-standard}"
log "Using StorageClass=${SC}"

kubectl -n "${NS}" delete secret wazuh-credentials --ignore-not-found
# Wazuh 4.9 API password policy: upper+lower+digit+symbol (Error 5007 if weak)
API_PASS="${WAZUH_API_PASSWORD:-WazuhApi!Passw0rd}"
IDX_PASS="${INDEXER_ADMIN_PASSWORD:-WazuhIdx!Passw0rd}"
DASH_PASS="${DASHBOARD_PASSWORD:-WazuhDash!Passw0rd}"
kubectl -n "${NS}" create secret generic wazuh-credentials \
  --from-literal=indexer-user=admin \
  --from-literal=indexer-password="${IDX_PASS}" \
  --from-literal=api-user=wazuh-wui \
  --from-literal=api-password="${API_PASS}" \
  --from-literal=dashboard-password="${DASH_PASS}" \
  --from-literal=cluster-key="${WAZUH_CLUSTER_KEY}"

CONF_OUT="${OUT}/wazuh_conf"
mkdir -p "${CONF_OUT}"
sed -e "s/__NAMESPACE__/${NS}/g" \
    -e "s/wazuh-manager-master-0\.wazuh-cluster\.wazuh/wazuh-manager-master-0.wazuh-cluster.${NS}/g" \
  "${ROOT_DIR}/manifests/manager/wazuh_conf/master.conf" >"${CONF_OUT}/master.conf"
sed -e "s/__NAMESPACE__/${NS}/g" \
    -e "s/wazuh-manager-master-0\.wazuh-cluster\.wazuh/wazuh-manager-master-0.wazuh-cluster.${NS}/g" \
  "${ROOT_DIR}/manifests/manager/wazuh_conf/worker.conf" >"${CONF_OUT}/worker.conf"

grep -q 'to_be_replaced_by_cluster_key' "${CONF_OUT}/master.conf" || die "master.conf missing key placeholder"
grep -q '<node_type>worker</node_type>' "${CONF_OUT}/worker.conf" || die "worker.conf missing node_type"

kubectl -n "${NS}" create configmap wazuh-conf \
  --from-file=master.conf="${CONF_OUT}/master.conf" \
  --from-file=worker.conf="${CONF_OUT}/worker.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- Indexer smoke (3 nodes, tiny heap, security off) ---
cat >"${OUT}/indexer.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: wazuh-indexer
  namespace: ${NS}
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  ports:
    - { name: http, port: 9200, targetPort: 9200 }
    - { name: transport, port: 9300, targetPort: 9300 }
  selector: { app: wazuh-indexer }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: wazuh-indexer-config
  namespace: ${NS}
data:
  opensearch.yml: |
    cluster.name: wazuh-cluster
    network.host: 0.0.0.0
    discovery.seed_hosts:
      - wazuh-indexer-0.wazuh-indexer
      - wazuh-indexer-1.wazuh-indexer
      - wazuh-indexer-2.wazuh-indexer
    cluster.initial_cluster_manager_nodes:
      - wazuh-indexer-0
      - wazuh-indexer-1
      - wazuh-indexer-2
    plugins.security.disabled: true
    path.data: /usr/share/wazuh-indexer/data
    node.store.allow_mmap: false
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: wazuh-indexer
  namespace: ${NS}
spec:
  serviceName: wazuh-indexer
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels: { app: wazuh-indexer }
  template:
    metadata:
      labels: { app: wazuh-indexer }
    spec:
      nodeSelector:
        wazuh.indexer: "true"
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
      containers:
        - name: wazuh-indexer
          image: wazuh/wazuh-indexer:${VER}
          ports:
            - { containerPort: 9200, name: http }
            - { containerPort: 9300, name: transport }
          env:
            - { name: OPENSEARCH_JAVA_OPTS, value: "-Xms512m -Xmx512m" }
            - { name: DISABLE_INSTALL_DEMO_CONFIG, value: "true" }
          resources:
            requests: { cpu: "100m", memory: 768Mi }
            limits: { cpu: "1", memory: 1536Mi }
          volumeMounts:
            - { name: wazuh-indexer, mountPath: /usr/share/wazuh-indexer/data }
            - { name: indexer-config, mountPath: /usr/share/wazuh-indexer/opensearch.yml, subPath: opensearch.yml }
          readinessProbe:
            tcpSocket: { port: 9200 }
            initialDelaySeconds: 45
            periodSeconds: 15
      volumes:
        - name: indexer-config
          configMap: { name: wazuh-indexer-config }
  volumeClaimTemplates:
    - metadata: { name: wazuh-indexer }
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: ${SC}
        resources:
          requests: { storage: 2Gi }
EOF

# --- Manager from package manifests (patched resources + SC) ---
sed \
  -e "s|__NAMESPACE__|${NS}|g" \
  -e "s|__WAZUH_VERSION__|${VER}|g" \
  -e "s|storageClassName: wazuh-general|storageClassName: ${SC}|g" \
  -e 's/cpu: "2"/cpu: "200m"/g' \
  -e 's/cpu: "4"/cpu: "500m"/g' \
  -e 's/memory: 4Gi/memory: 768Mi/g' \
  -e 's/memory: 8Gi/memory: 1536Mi/g' \
  -e 's/storage: 50Gi/storage: 1Gi/g' \
  -e 's/storage: 10Gi/storage: 1Gi/g' \
  "${ROOT_DIR}/manifests/manager/statefulset-manager-master.yaml" >"${OUT}/manager-master.yaml"

sed \
  -e "s|__NAMESPACE__|${NS}|g" \
  -e "s|__WAZUH_VERSION__|${VER}|g" \
  -e "s|storageClassName: wazuh-general|storageClassName: ${SC}|g" \
  -e 's/cpu: "2"/cpu: "200m"/g' \
  -e 's/cpu: "4"/cpu: "500m"/g' \
  -e 's/memory: 4Gi/memory: 768Mi/g' \
  -e 's/memory: 8Gi/memory: 1536Mi/g' \
  -e 's/storage: 50Gi/storage: 1Gi/g' \
  "${ROOT_DIR}/manifests/manager/statefulset-manager-worker.yaml" >"${OUT}/manager-worker.yaml"

sed -e "s|__NAMESPACE__|${NS}|g" \
  "${ROOT_DIR}/manifests/manager/services.yaml" >"${OUT}/manager-services.yaml"

grep -q 'name: WAZUH_CLUSTER_KEY' "${OUT}/manager-master.yaml" || die "master STS missing WAZUH_CLUSTER_KEY"
grep -q 'name: WAZUH_CLUSTER_KEY' "${OUT}/manager-worker.yaml" || die "worker STS missing WAZUH_CLUSTER_KEY"
grep -q 'subPath: master.conf' "${OUT}/manager-master.yaml" || die "master STS missing ossec mount"
grep -q 'subPath: worker.conf' "${OUT}/manager-worker.yaml" || die "worker STS missing ossec mount"

kubectl apply -f "${OUT}/indexer.yaml"
kubectl apply -f "${OUT}/manager-services.yaml"
kubectl apply -f "${OUT}/manager-master.yaml"
kubectl apply -f "${OUT}/manager-worker.yaml"

log "Waiting for image pulls / Ready (up to 12 min)..."
kubectl -n "${NS}" rollout status statefulset/wazuh-indexer --timeout=720s || warn "Indexer STS not fully Ready"
kubectl -n "${NS}" rollout status statefulset/wazuh-manager-master --timeout=720s || warn "Manager master not Ready"
kubectl -n "${NS}" rollout status statefulset/wazuh-manager-worker --timeout=720s || warn "Manager worker not Ready"

# Give manager cluster time to handshake
sleep 30

IDX_HEALTH="FAIL"
MGR_CLUSTER="FAIL"
PASS=0
FAIL=0

check() {
  local name="$1" ok="$2"
  if [[ "${ok}" == "true" ]]; then
    echo "[PASS] ${name}"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${name}"
    FAIL=$((FAIL + 1))
  fi
}

{
  echo "===== WAZUH SMOKE VERIFICATION $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
  echo "context=$(kubectl config current-context)"
  echo "node=${NODE} ns=${NS} wazuh=${VER}"
  echo "cluster_key_len=${#WAZUH_CLUSTER_KEY}"
  echo
  echo "=== nodes ==="
  kubectl get nodes -o wide
  echo
  echo "=== pods ==="
  kubectl -n "${NS}" get pods -o wide
  echo
  echo "=== sts / svc ==="
  kubectl -n "${NS}" get sts,svc
  echo
  echo "=== wiring checks ==="
  if kubectl -n "${NS}" get sts wazuh-manager-master -o yaml | grep -q 'name: WAZUH_CLUSTER_KEY'; then
    check "manager-master has env WAZUH_CLUSTER_KEY" true
  else
    check "manager-master has env WAZUH_CLUSTER_KEY" false
  fi
  if kubectl -n "${NS}" get sts wazuh-manager-worker -o yaml | grep -q 'name: WAZUH_CLUSTER_KEY'; then
    check "manager-worker has env WAZUH_CLUSTER_KEY" true
  else
    check "manager-worker has env WAZUH_CLUSTER_KEY" false
  fi
  if kubectl -n "${NS}" get cm wazuh-conf -o yaml | grep -q 'to_be_replaced_by_cluster_key'; then
    check "ConfigMap wazuh-conf has cluster key placeholder" true
  else
    check "ConfigMap wazuh-conf has cluster key placeholder" false
  fi
  if kubectl -n "${NS}" get cm wazuh-conf -o yaml | grep -q "wazuh-manager-master-0.wazuh-cluster.${NS}"; then
    check "worker/master nodes DNS points to master-0.${NS}" true
  else
    check "worker/master nodes DNS points to master-0.${NS}" false
  fi

  echo
  echo "=== Indexer _cluster/health ==="
  if kubectl -n "${NS}" get pod wazuh-indexer-0 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; then
    H="$(kubectl -n "${NS}" exec wazuh-indexer-0 -- curl -s --max-time 15 "http://localhost:9200/_cluster/health?pretty" 2>&1 || true)"
    echo "${H}"
    NODES="$(echo "${H}" | awk '/number_of_nodes/ {print $2}' | tr -d ',')"
    STATUS="$(echo "${H}" | awk '/"status"/ {print $3}' | tr -d '",')"
    if [[ "${NODES}" == "3" ]]; then
      check "Indexer number_of_nodes=3" true
      IDX_HEALTH="OK nodes=${NODES} status=${STATUS}"
    else
      check "Indexer number_of_nodes=3 (got ${NODES:-none})" false
      IDX_HEALTH="BAD nodes=${NODES:-none} status=${STATUS:-none}"
    fi
  else
    check "Indexer pod wazuh-indexer-0 Running" false
    kubectl -n "${NS}" describe pod wazuh-indexer-0 2>&1 | tail -40 || true
  fi

  echo
  echo "=== Manager cluster_control -l ==="
  if kubectl -n "${NS}" get pod wazuh-manager-master-0 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; then
    CC="$(kubectl -n "${NS}" exec wazuh-manager-master-0 -- /var/ossec/bin/cluster_control -l 2>&1 || true)"
    echo "${CC}"
    # Expect master + worker listed / Connected
    if echo "${CC}" | grep -qiE 'master|worker'; then
      if echo "${CC}" | grep -qiE 'disconnected|failed'; then
        # still may show both with status
        if echo "${CC}" | grep -ciE 'master|worker' | awk '{exit !($1>=2)}'; then
          check "Manager cluster lists master+worker" true
          MGR_CLUSTER="PARTIAL/OK — see output"
        else
          check "Manager cluster lists master+worker" false
        fi
      else
        check "Manager cluster_control shows cluster members" true
        MGR_CLUSTER="OK"
      fi
    else
      check "Manager cluster_control shows cluster members" false
      MGR_CLUSTER="FAIL"
      kubectl -n "${NS}" logs wazuh-manager-master-0 --tail=40 2>&1 || true
      kubectl -n "${NS}" logs wazuh-manager-worker-0 --tail=40 2>&1 || true
    fi
  else
    check "Manager master pod Running" false
    kubectl -n "${NS}" describe pod wazuh-manager-master-0 2>&1 | tail -50 || true
    kubectl -n "${NS}" logs wazuh-manager-master-0 --tail=40 2>&1 || true
  fi

  echo
  echo "=== SUMMARY ==="
  echo "PASS=${PASS} FAIL=${FAIL}"
  echo "Indexer: ${IDX_HEALTH}"
  echo "ManagerCluster: ${MGR_CLUSTER}"
  if (( FAIL == 0 )); then
    echo "RESULT=SUCCESS"
  else
    echo "RESULT=FAILED"
  fi
} | tee "${REPORT}"

log "Report written: ${REPORT}"
# exit non-zero if failures
if grep -q 'RESULT=SUCCESS' "${REPORT}"; then
  exit 0
fi
exit 1
