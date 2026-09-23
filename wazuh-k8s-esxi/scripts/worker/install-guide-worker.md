# Install Guide — K8s Worker

Роль: **general worker** (`k8s-worker-01`, `k8s-worker-02`) для подов Wazuh Manager, Dashboard, ingress, monitoring.

## Требования к ВМ

| Параметр | Значение |
|----------|----------|
| ОС | РЕД ОС 8 / Astra Linux / Ubuntu 22.04 |
| vCPU | **8** |
| RAM | **16 GiB** (reservation) |
| `sda` | 100 GiB thin — ОС |
| `sdb` | **200 GiB** thick lazy — `/var/lib/containerd` |
| vSphere | VM-VM anti-affinity между двумя worker |

**Почему 8/16:** на паре worker размещаются Manager master+worker (~8–16 GiB суммарно с limits), Dashboard, CoreDNS replicas, ingress. Запас под rolling updates images.

## Разметка дисков

См. `docs/disk-layout.md` §2. Swap off. LVM containerd на `$CONTAINER_DISK`.

## Пошагово

### 1. Зависимости

Control-plane уже установлен. В `cluster.env` заполнены:

```bash
CP_IP=10.10.10.10
KUBEADM_TOKEN=xxxxxx.xxxxxxxxxxxxxxxx
KUBEADM_HASH=sha256:................................
CONTAINER_DISK=/dev/sdb
```

### 2. Установка

```bash
export WAZUH_K8S_ENV=/etc/wazuh-k8s/cluster.env
sudo -E bash scripts/worker/install-worker.sh
```

| Шаг | Действие | Зачем |
|-----|----------|-------|
| Preflight | CPU≥8, RAM≥16, OS, порты 10250 | Соответствие роли |
| Disk/runtime | как на CP | Единый CRI |
| `kubeadm join` | присоединение к API | Node Ready |
| Labels | `node-role.kubernetes.io/worker=`, `wazuh.role=general` | Селекторы деплоя |
| Taints | нет | Manager/Dashboard могут планироваться сюда |

### 3. Проверка (с CP)

```bash
kubectl get nodes -o wide
kubectl describe node k8s-worker-01 | grep -A5 Labels
```

Ожидание: `Ready`, label `wazuh.role=general`.

## Важно

- **Не** вешайте taint Indexer на worker.
- PVC Manager лучше на CSI/vSAN StorageClass `wazuh-general`, не на локальный диск Indexer.

## Дальше

Indexer-ноды → `install-indexer.sh`, затем с admin host `install-manager.sh`.
