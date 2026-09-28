# Как собирается кластер (K8s + Wazuh)

Два разных «кластера». Tarball/`git` upstream **не** склеивает ноды сам по себе —
сборка идёт через kubeadm и через manifests + `ossec.conf`.

---

## 1. Kubernetes-кластер (6 ВМ)

| Шаг | Роль `install.sh` | Что происходит |
|-----|-------------------|----------------|
| 1 | `control-plane` | `kubeadm init`, Calico, печатаются `KUBEADM_TOKEN` / `KUBEADM_HASH` |
| 2 | `worker` ×2 | `kubeadm join` к CP |
| 3 | `indexer` ×3 | `kubeadm join` + диск данных |
| 4 | `labels` | `wazuh.role=general\|indexer`, taint на indexer |

Проверка: `kubectl get nodes` → 6 Ready.

**От tarball Wazuh это не зависит.**

---

## 2. Wazuh Indexer-кластер (OpenSearch, 3 пода)

Роль `manager` применяет `manifests/indexer/statefulset-indexer.yaml`:

- headless Service `wazuh-indexer`
- STS replicas=3, `discovery.seed_hosts` = `wazuh-indexer-{0,1,2}.wazuh-indexer`
- `cluster.initial_cluster_manager_nodes` = те же три имени
- scheduling: `wazuh.role=indexer` + taint

Ноды находят друг друга по DNS headless Service внутри namespace.

Проверка:

```bash
kubectl -n wazuh exec wazuh-indexer-0 -- curl -sk -u admin:$INDEXER_ADMIN_PASSWORD \
  https://localhost:9200/_cluster/health?pretty
# number_of_nodes: 3
```

---

## 3. Wazuh Manager-кластер (master + worker)

Это место, которое раньше было **сломано** в пакете:

| Было неверно | Как нужно (сейчас) |
|--------------|-------------------|
| env `CLUSTER_KEY` | образ читает **`WAZUH_CLUSTER_KEY`** |
| env `CLUSTER_NODE_TYPE` / `CLUSTER_MASTER_IP` | образ их **игнорирует** |
| нет `ossec.conf` с `<cluster>` | ConfigMap `wazuh-conf` → mount `/wazuh-config-mount/etc/ossec.conf` |

### Цепочка сборки Manager

```
install-manager.sh
  ├─ generate_cluster_key → secret wazuh-credentials.cluster-key
  ├─ fetch tarball wazuh-kubernetes (без .git)     # эталон conf
  ├─ ConfigMap wazuh-conf  (master.conf + worker.conf)
  │     <cluster>
  │       <node_type>master|worker</node_type>
  │       <key>to_be_replaced_by_cluster_key</key>
  │       <nodes><node>wazuh-manager-master-0.wazuh-cluster.<ns></node>
  ├─ STS master/worker + headless Service wazuh-cluster :1516
  └─ при старте пода entrypoint образа:
        sed key ← $WAZUH_CLUSTER_KEY
        sed node_name ← $HOSTNAME  (для worker)
```

Worker стучится на master по DNS:

`wazuh-manager-master-0.wazuh-cluster.<namespace>` (порт **1516**).

Проверка:

```bash
kubectl -n wazuh get pods -l app=wazuh-manager -o wide
kubectl -n wazuh exec wazuh-manager-master-0 -- /var/ossec/bin/cluster_control -l
# оба узла Connected
```

### Откуда берётся `ossec.conf`

1. Если скачан tarball → `…/wazuh_managers/wazuh_conf/{master,worker}.conf`
2. Иначе вендор в пакете: `manifests/manager/wazuh_conf/`
3. Режим `WAZUH_K8S_FETCH_METHOD=skip` тоже ок — используется вендор

Tarball **не** применяется целиком через kustomize; из него нужен именно conf для кластера.

---

## 4. Dashboard и архивы

| Шаг | Роль | Связь |
|-----|------|--------|
| `dashboard` | под UI → API `wazuh-manager-master:55000`, Indexer |
| `archiving` | ISM + snapshot repo на Indexer-кластере |

---

## 5. Что НЕ влияет на сборку нод

- Наличие / отсутствие каталога `.git` у upstream
- `git clone` vs `tarball` — меняет только способ доставки файлов conf
- Clone вашего репо `Prod` на ВМ

---

## Порядок одной строкой

```text
CP → workers → indexers → labels
  → manager (Indexer STS + Manager STS + wazuh-conf + secret key)
  → dashboard → archiving
```

Подробности fetch без отпечатка: `docs/wazuh-upstream-fetch.md`.  
Чеклист: `docs/checklist.md` (§B, §D, §E).
