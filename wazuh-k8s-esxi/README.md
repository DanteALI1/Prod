# Wazuh on Kubernetes — ESXi Production Package

Полный пакет документации и идемпотентных скриптов для развёртывания **Wazuh 4.9.x** в **Kubernetes 1.30** на **VMware ESXi** под нагрузку **до 200 агентов**.

**Целевые ОС ВМ (серверы с нуля, без предустановленного ПО):**

- **РЕД ОС 8** (RPM / dnf)
- **Astra Linux** (DEB / apt)
- также Ubuntu 22.04 (совместимость)

Оркестрация: **kubeadm + containerd + Calico**. Обоснование — `docs/architecture.md`.

## Простыми словами: сколько и куда

Читайте сначала → **[docs/pods-resources-simple.md](docs/pods-resources-simple.md)**  
(ВМ vs поды, CPU/RAM/диск на каждый под, схема размещения.)

Установка на РЕД ОС / Astra → **[docs/os-redos-astra.md](docs/os-redos-astra.md)**

## Состав решения (6 ВМ)

| Роль | Кол-во | vCPU | RAM | Диски | Скрипт |
|------|--------|------|-----|-------|--------|
| K8s Control-Plane | 1 | 4 | 8 GiB | 100 GiB OS + 100 GiB containerd | `scripts/control-plane/install-control-plane.sh` |
| K8s Worker | 2 | 8 | 16 GiB | 100 GiB OS + 200 GiB containerd | `scripts/worker/install-worker.sh` |
| Wazuh Indexer Node | 3 | 8 | 32 GiB | 100 OS + 100 containerd + **2 TiB data** | `scripts/indexer/install-indexer.sh` |
| Wazuh Manager (pods) | 1 master + 1 worker | на Worker | — | PVC 50 GiB (+10 GiB etc) | `scripts/manager/install-manager.sh` |
| Wazuh Dashboard (pod) | 1 | на Worker | — | — | `scripts/dashboard/install-dashboard.sh` |

| Pod | Где | Requests → Limits |
|-----|-----|-------------------|
| `wazuh-indexer-*` ×3 | indexer ВМ | 4 CPU / 24 GiB → 7 CPU / 30 GiB + **2 TiB** диск |
| `wazuh-manager-master-0` | worker-01 | 2 CPU / 4 GiB → 4 CPU / 8 GiB |
| `wazuh-manager-worker-0` | worker-02 | 2 CPU / 4 GiB → 4 CPU / 8 GiB |
| `wazuh-dashboard` | worker | 0.5 CPU / 1 GiB → 2 CPU / 4 GiB |

Подробный расчёт EPS/дисков/ISM: **[docs/architecture.md](docs/architecture.md)**.

### Ключевые цифры (консервативный baseline)

| Метрика | Значение |
|---------|----------|
| Событий/агент/день | 100 000 |
| Средний EPS | **≈ 231** |
| Пиковый EPS (×4) | **≈ 924** |
| Суточный прирост primary | **≈ 22.9 GiB/day** |
| Online 90 дней (с replica +25%) | **≈ 5.0 TiB** |
| Archive snapshots (90 дней) | **≈ 1.4 TiB** (репо ≥ 3 TiB) |
| Hot searchable | **14 дней** |
| Snapshot + delete | **90 дней** |

## Структура каталогов

```
wazuh-k8s-esxi/
├── README.md
├── config/
│   ├── cluster.env          # единый конфиг (IP, retention, ОС, пароли)
│   └── ism-policy.json
├── docs/
│   ├── pods-resources-simple.md   # ← начните здесь
│   ├── os-redos-astra.md          # РЕД ОС 8 / Astra с нуля
│   ├── architecture.md
│   ├── network-security.md
│   ├── disk-layout.md
│   └── checklist.md
├── helm/values-wazuh.yaml
├── manifests/
└── scripts/
    ├── common/lib.sh          # multi-OS: redos | astra | ubuntu
    ├── control-plane|worker|indexer|manager|dashboard|archiving/
```

## Порядок выполнения (строго)

На **каждой** ВМ:

1. Установить **РЕД ОС 8** или **Astra Linux** (minimal), либо Ubuntu 22.04.
2. Прописать DNS или `/etc/hosts` на все узлы.
3. Скопировать пакет, заполнить `config/cluster.env` (IP/пароли/диски).
4. `export WAZUH_K8S_ENV=/etc/wazuh-k8s/cluster.env`

| Шаг | Где | Команда |
|-----|-----|---------|
| 1 | `k8s-cp-01` | `sudo -E bash scripts/control-plane/install-control-plane.sh` |
| 2 | Сохранить `KUBEADM_TOKEN` / `KUBEADM_HASH` из вывода в `cluster.env` |
| 3 | `k8s-worker-01`, `k8s-worker-02` | `sudo -E bash scripts/worker/install-worker.sh` |
| 4 | `k8s-indexer-01..03` | `sudo -E bash scripts/indexer/install-indexer.sh` |
| 5 | `k8s-cp-01` | `sudo -E bash scripts/common/label-nodes.sh` |
| 6 | CP | `sudo -E bash scripts/manager/install-manager.sh` |
| 7 | CP | `sudo -E bash scripts/dashboard/install-dashboard.sh` |
| 8 | CP | `sudo -E bash scripts/archiving/setup-archiving.sh` |
| 9 | | Пройти `docs/checklist.md` |

Скрипты на пустой ОС сами ставят curl, lvm2, jq, containerd, kubeadm и открывают firewall-порты.

## Кастомизация

1. `$WAZUH_K8S_ENV`, иначе
2. `./config/cluster.env`, иначе
3. `/etc/wazuh-k8s/cluster.env`

Важные переменные для российских ОС: `TARGET_OS`, `SELINUX_MODE`, `K8S_VERSION_RPM`, `CONTAINERD_INSTALL_METHOD`, `FIREWALL_MANAGE`.

`DRY_RUN=true` — только лог действий без изменений.

## Сеть, TLS, StorageClass

См. **[docs/network-security.md](docs/network-security.md)** и **[docs/disk-layout.md](docs/disk-layout.md)**.

- Агенты → Manager: `1514/tcp`, `1515/tcp`, API `55000/tcp`.
- Indexer: `9200`, `9300`.
- Storage Indexer: **local PV** на XFS noatime.
- Archive: NFS или S3-compatible ≥ 3 TiB.

## Архивы и restore

- `scripts/archiving/setup-archiving.sh` + `config/ism-policy.json`
- `scripts/archiving/restore-guide.md` + `restore-archive.sh`

## Мониторинг здоровья

```bash
kubectl -n wazuh get pods -o wide
kubectl -n wazuh exec -it wazuh-indexer-0 -- curl -sk -u admin:$INDEXER_ADMIN_PASSWORD \
  https://localhost:9200/_cluster/health?pretty
kubectl -n wazuh exec -it wazuh-manager-master-0 -- /var/ossec/bin/cluster_control -l
```

## Исправления в скриптах (этот релиз)

- Поддержка **РЕД ОС 8** и **Astra Linux** с bootstrap «с нуля»
- `KUBEADM_HASH` без префикса `sha256:` дополняется автоматически
- Исправлена передача JSON в Indexer API (`curl` через `kubectl exec -i`)
- Исправлена логика бэкапа конфига Manager
- PV hostnames подставляются из `cluster.env`
- Порты: корректная проверка free/in-use; firewalld/ufw
- SELinux permissive на RPM-системах; containerd binary на РЕД ОС

## Отказ от ответственности

Пароли в `cluster.env` — **заглушки**. Смените до production. Пакет не заменяет hardening и политики ИБ вашей организации.
