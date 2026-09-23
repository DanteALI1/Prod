# Install Guide — K8s Control-Plane

Роль: **единая control-plane нода** (`k8s-cp-01`) для кластера Wazuh на ESXi.

## Требования к ВМ (vSphere)

| Параметр | Значение |
|----------|----------|
| ОС | Ubuntu 22.04 LTS |
| vCPU | **4** (reservation ≥ 2 GHz) |
| RAM | **8 GiB** (full reservation) |
| `sda` | 100 GiB thin — ОС |
| `sdb` | 100 GiB thick lazy — `/var/lib/containerd` |
| Сеть | static IP, DNS или `/etc/hosts` на все узлы |
| Snapshot ВМ | сделать **до** `kubeadm init` |

Обоснование ресурсов: etcd + apiserver + controller-manager + scheduler + Calico + CoreDNS укладываются в 4/8 при кластере ≤10 нод. Для HA см. приложение в `docs/architecture.md`.

## Разметка дисков

См. `docs/disk-layout.md` §1. Скрипт автоматически:

1. Отключает swap.
2. Создаёт LVM `vg_container/lv_containerd` на `$CONTAINER_DISK` → `/var/lib/containerd`.
3. Выставляет `vm.max_map_count=262144`, `ip_forward`, br_netfilter.

## Пошагово

### 1. Подготовка ОС

```bash
sudo apt update && sudo apt -y upgrade
# Заполнить config/cluster.env: CP_IP, POD_CIDR, пароли и т.д.
sudo mkdir -p /etc/wazuh-k8s
sudo cp config/cluster.env /etc/wazuh-k8s/cluster.env
export WAZUH_K8S_ENV=/etc/wazuh-k8s/cluster.env
```

Пропишите все хосты кластера в DNS или `/etc/hosts`.

### 2. Запуск установки

```bash
cd wazuh-k8s-esxi
sudo -E bash scripts/control-plane/install-control-plane.sh
```

Скрипт выполняет:

| Шаг | Что делает | Зачем |
|-----|------------|-------|
| Preflight | Ubuntu 22.04, CPU≥4, RAM≥8, порты 6443/10250 свободны | Не начинать на слабой/чужой ВМ |
| Disk | LVM под containerd | Отделить image store от OS |
| Runtime | containerd + kubelet/kubeadm/kubectl `K8S_VERSION` | CRI + control plane tools |
| `kubeadm init` | Control plane + certs | API endpoint `${CP_IP}:6443` |
| kubeconfig | `/root/.kube/config` и копирование в `$HOME` вызывающего | Доступ kubectl |
| CNI | Calico (или Cilium) | Pod networking |
| Namespace | создаёт `wazuh` | Дальнейший деплой |

### 3. Сохранить join-данные

В конце скрипт печатает:

```bash
kubeadm token create --print-join-command
```

Перенесите token и `sha256` hash в `cluster.env`:

```bash
KUBEADM_TOKEN=...
KUBEADM_HASH=sha256:...
```

Без этого worker/indexer скрипты не смогут присоединиться автоматически.

### 4. Проверка

```bash
kubectl get nodes
kubectl -n kube-system get pods
kubectl get ns wazuh
```

Ожидание: нода `Ready` после установки CNI; поды coredns Running.

## Типовые ошибки

| Симптом | Причина | Действие |
|---------|---------|----------|
| `kubeadm init` hang | swap / br_netfilter | Перезапустить скрипт (идемпотентные проверки) |
| NotReady | CNI не встал | `kubectl -n kube-system logs -l k8s-app=calico-node` |
| Порт 6443 busy | повторный init | `kubeadm reset -f` только если осознанно |

## Что дальше

1. `install-worker.sh` на worker-нодах  
2. `install-indexer.sh` на Indexer-нодах
