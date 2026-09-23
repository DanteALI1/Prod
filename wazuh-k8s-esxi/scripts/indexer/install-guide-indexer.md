# Install Guide — Wazuh Indexer Node

Роль: **dedicated Kubernetes worker** под OpenSearch (Wazuh Indexer). Три ноды: `k8s-indexer-01..03`.

## Требования к ВМ (критично)

| Параметр | Значение | Почему |
|----------|----------|--------|
| ОС | РЕД ОС 8 / Astra Linux / Ubuntu 22.04 | Единый sizing; см. `docs/os-redos-astra.md` |
| vCPU | **8** (reservation ≥ 4 GHz) | ~1000 EPS peak + merges |
| RAM | **32 GiB** (**full reservation**) | Heap 16 GiB + page cache |
| `sda` | 100 GiB thin | ОС |
| `sdb` | 100 GiB thick lazy | `/var/lib/containerd` |
| **`sdc`** | **2 TiB** **Thick Eager Zeroed SSD/NVMe** | `/var/lib/wazuh-indexer` (XFS) |
| vSphere | **Hard anti-affinity**: разные ESXi hosts | Потеря 1 host ≠ потеря кворума |
| Latency Sensitivity | High (опционально) | Снижение jitter |

### Расчёт диска (напоминание)

- 200 агентов × 100k events/day × 1.2 KiB ≈ **22.9 GiB/day** primary  
- ×2 (replica) ×90 ×1.25 ≈ **5.0 TiB** cluster → **~1.67 TiB/node** → диск **2 TiB**

## Разметка дисков

См. `docs/disk-layout.md` §3.

```
/dev/sdc → PV → VG vg_indexer → LV lv_data → XFS → /var/lib/wazuh-indexer
mount: noatime,nodiratime
chown 1000:1000
```

Swap **выключен**. `vm.max_map_count=262144` обязателен.

## Пошагово

### 1. vSphere

1. Создать 3 ВМ по таблице.  
2. Anti-affinity rule `wazuh-indexer-aa`.  
3. Подключить отдельный VMDK 2 TiB Eager Zeroed на каждый.  
4. Убедиться, что datastore не переполнен (thick требует реальное место).

### 2. Конфиг

```bash
INDEXER_DATA_DISK=/dev/sdc
KUBEADM_TOKEN=...
KUBEADM_HASH=sha256:...
MIN_DISK_GB_INDEXER_DATA=1800
```

### 3. Установка на каждой Indexer-ВМ

```bash
export WAZUH_K8S_ENV=/etc/wazuh-k8s/cluster.env
sudo -E bash scripts/indexer/install-indexer.sh
```

Скрипт:

1. Preflight (CPU/RAM/диск data ≥ 1.8 TiB free после mount).  
2. LVM + XFS data path.  
3. containerd + kubeadm join.  
4. Печатает команды labels/taints для выполнения с CP:

```bash
kubectl label node <name> wazuh.role=indexer --overwrite
kubectl taint nodes <name> wazuh-indexer=true:NoSchedule --overwrite
```

Taint гарантирует, что Manager/Dashboard **не** попадут на Indexer-ноды (CPU/IO изоляция).

### 4. Static PV (с control-plane)

После join всех трёх нод:

```bash
# На CP, из корня пакета
kubectl apply -f manifests/storage/storageclass-indexer-local.yaml
# Отредактируйте node names в pv-indexer-*.yaml при необходимости
kubectl apply -f manifests/storage/
```

Имена нод в PV `nodeAffinity` должны совпасть с `kubectl get nodes`.

### 5. Проверка ноды

```bash
df -h /var/lib/wazuh-indexer
kubectl get nodes -l wazuh.role=indexer
```

Деплой самих подов Indexer выполняется скриптом **Manager** (единый Helm/kustomize релиз Wazuh) либо отдельным apply StatefulSet — см. `install-guide-manager.md`.

## Эксплуатация диска

- Следите за watermark OpenSearch (`cluster.routing.allocation.disk.watermark`).  
- При 85%+ — расширяйте VMDK (runbook в `disk-layout.md`).  
- Никогда не кладите snapshot repository на тот же `sdc`.
