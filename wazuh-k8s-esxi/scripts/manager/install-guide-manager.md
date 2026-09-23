# Install Guide — Wazuh Manager (кластер master + worker)

Роль выполняется **с admin-хоста / control-plane** (нужен `kubectl` + Helm). Поды планируются на **general worker** ноды.

## Целевая топология Manager

| Pod | Replicas | Node pool | Ресурсы (request/limit) |
|-----|----------|-----------|-------------------------|
| `wazuh-manager-master` | 1 | `wazuh.role=general` | 2–4 CPU / 4–8 GiB |
| `wazuh-manager-worker` | 1 | `wazuh.role=general` | 2–4 CPU / 4–8 GiB |

Для **200 агентов** связка **1 master + 1 worker** достаточна (официальные ориентиры Wazuh: один менеджер тянет сотни агентов; worker добавляет горизонтальное принятие событий и HA enrollment при корректном LB).

Отдельная гипервизорная «Manager VM» **не нужна** — ресурсы уже заложены в Worker ×2 (8 vCPU / 16 GiB).

## PVC

| Volume | Size | StorageClass |
|--------|------|--------------|
| master data (`/var/ossec/data` etc.) | 50 GiB | `wazuh-general` |
| worker data | 50 GiB | `wazuh-general` |

## TLS и cluster key

Скрипт:

1. Клонирует `wazuh/wazuh-kubernetes` tag `WAZUH_K8S_TAG` **или** применяет локальные manifests.  
2. Генерирует `WAZUH_CLUSTER_KEY` (32 hex), если пуст.  
3. Создаёт secrets (indexer creds, API password, certs).  
4. Деплоит Indexer StatefulSet (3) + Manager через overlays/Helm values `helm/values-wazuh.yaml`.

> **Почему не «чистый» сторонний chart без оговорок:** официальный путь Wazuh — репозиторий [wazuh-kubernetes](https://github.com/wazuh/wazuh-kubernetes) (kustomize/helm). Пакет использует его как базу + наши values/overlays (ISM, nodeSelector, local PV). Это снижает drift от upstream security patches.

## Пошагово

### Preconditions

```bash
kubectl get nodes
# Ready: cp, 2 worker, 3 indexer
kubectl get nodes -l wazuh.role=indexer
kubectl get pv,sc
```

Static PV для Indexer уже применены (`manifests/storage/`).

### Запуск

```bash
export WAZUH_K8S_ENV=/etc/wazuh-k8s/cluster.env
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo -E bash scripts/manager/install-manager.sh
```

| Шаг | Смысл |
|-----|-------|
| Preflight | kubectl context, ноды indexer=3, namespace |
| Certs/secrets | TLS Indexer↔Manager, пароли |
| Apply storage + indexer STS | 3 пода на tainted nodes |
| Apply manager master/worker | Deployment/STS на general workers |
| Wait Ready | timeout 600s |
| cluster_control | проверка связки master↔worker |

### Балансировка агентов

Снаружи публикуйте Service `wazuh` типа LoadBalancer/NodePort:

- `1514` → events  
- `1515` → enrollment  

Оба manager pods должны быть в backend (cluster mode). Пример: MetalLB на ESXi или NSX LB / HAProxy на двух VIP.

### Бэкап конфигурации Manager

После стабилизации:

```bash
kubectl -n wazuh exec wazuh-manager-master-0 -- tar czf - \
  /var/ossec/etc/rules /var/ossec/etc/decoders /var/ossec/etc/shared \
  /var/ossec/api/configuration >/backup/wazuh-manager-conf-$(date +%F).tgz
```

Автоматизация — функция в конце `install-manager.sh` (`--backup-only`).

## Проверки

```bash
kubectl -n wazuh get pods -l app=wazuh-manager -o wide
kubectl -n wazuh exec -it wazuh-manager-master-0 -- /var/ossec/bin/cluster_control -l
kubectl -n wazuh exec -it wazuh-manager-master-0 -- /var/ossec/bin/cluster_control -i
```

Ожидание: master + worker Connected; агенты появятся после enrollment.
