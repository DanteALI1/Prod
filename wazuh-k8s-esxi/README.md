# Wazuh on Kubernetes — ESXi Production Package

Полный пакет документации и идемпотентных скриптов для развёртывания **Wazuh 4.9.x** в **Kubernetes 1.30** на **VMware ESXi** под нагрузку **до 200 агентов**.

Целевая ОС ВМ: **Ubuntu 22.04 LTS**. Оркестрация: **kubeadm + containerd + Calico** (обоснование — `docs/architecture.md`).

## Состав решения (6 ВМ)

| Роль | Кол-во | vCPU | RAM | Диски | Скрипт |
|------|--------|------|-----|-------|--------|
| K8s Control-Plane | 1 | 4 | 8 GiB | 100 GiB OS + 100 GiB containerd | `scripts/control-plane/install-control-plane.sh` |
| K8s Worker | 2 | 8 | 16 GiB | 100 GiB OS + 200 GiB containerd | `scripts/worker/install-worker.sh` |
| Wazuh Indexer Node | 3 | 8 | 32 GiB | 100 OS + 100 containerd + **2 TiB data** | `scripts/indexer/install-indexer.sh` |
| Wazuh Manager (pods) | 1 master + 1 worker | на Worker | — | PVC 50 GiB ×2 | `scripts/manager/install-manager.sh` |
| Wazuh Dashboard (pod) | 1 | на Worker | — | — | `scripts/dashboard/install-dashboard.sh` |

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
│   ├── cluster.env          # единый конфиг (IP, retention, пароли)
│   └── ism-policy.json      # ISM policy 14d hot / 90d snapshot
├── docs/
│   ├── architecture.md
│   ├── network-security.md
│   ├── disk-layout.md
│   └── checklist.md
├── helm/values-wazuh.yaml
├── manifests/               # StatefulSet/Deployment/StorageClass overlays
└── scripts/
    ├── common/lib.sh
    ├── control-plane/
    ├── worker/
    ├── indexer/
    ├── manager/
    ├── dashboard/
    └── archiving/           # setup-archiving.sh, restore-archive.sh, restore-guide.md
```

## Порядок выполнения (строго)

На **каждой** ВМ заранее:

1. Установить Ubuntu 22.04 LTS (minimal).
2. Прописать DNS или `/etc/hosts` на все узлы кластера.
3. Скопировать пакет и `config/cluster.env`, заполнить IP/пароли/диски.
4. `export WAZUH_K8S_ENV=/path/to/cluster.env`

| Шаг | Где | Команда |
|-----|-----|---------|
| 1 | `k8s-cp-01` | `sudo -E bash scripts/control-plane/install-control-plane.sh` |
| 2 | Сохранить join-команду из вывода CP (`kubeadm token create --print-join-command`) → вписать `KUBEADM_TOKEN` / `KUBEADM_HASH` в `cluster.env` |
| 3 | `k8s-worker-01`, `k8s-worker-02` | `sudo -E bash scripts/worker/install-worker.sh` |
| 4 | `k8s-indexer-01..03` | `sudo -E bash scripts/indexer/install-indexer.sh` |
| 5 | `k8s-cp-01` (или admin host с kubeconfig) | `sudo -E bash scripts/manager/install-manager.sh` |
| 6 | тот же admin host | `sudo -E bash scripts/dashboard/install-dashboard.sh` |
| 7 | admin host (после Ready подов Indexer) | `sudo -E bash scripts/archiving/setup-archiving.sh` |
| 8 | | Пройти `docs/checklist.md` |

Инструкции для человека (пошагово с объяснениями) лежат рядом со скриптами: `install-guide-*.md`.

## Кастомизация

Все скрипты читают переменные из:

1. `$WAZUH_K8S_ENV`, иначе
2. `./config/cluster.env`, иначе
3. `/etc/wazuh-k8s/cluster.env`

Не правьте скрипты построчно — меняйте `cluster.env` (`HOT_RETENTION_DAYS`, `DELETE_AFTER_DAYS`, IP, устройства дисков, пароли).

`DRY_RUN=true` — только лог действий без изменений.

## Сеть, TLS, StorageClass

См. **[docs/network-security.md](docs/network-security.md)** и **[docs/disk-layout.md](docs/disk-layout.md)**.

Кратко:

- Агенты → Manager: `1514/tcp` (events), `1515/tcp` (enrollment), API `55000/tcp`.
- Indexer: `9200` (HTTP/TLS), `9300` (transport).
- Storage Indexer: **local PV** (hostPath/local-static-provisioner) на XFS noatime.
- Archive: NFS или S3-compatible (MinIO/vSAN file service).
- TLS между Indexer/Manager/Dashboard — сертификаты из официального `wazuh-kubernetes` (скрипты генерируют/подставляют).

## Архивы и restore

- Политика: `scripts/archiving/setup-archiving.sh` + `config/ism-policy.json`.
- Восстановление: `scripts/archiving/restore-guide.md` + `restore-archive.sh`.

## Мониторинг здоровья (шпаргалка)

```bash
kubectl -n wazuh get pods -o wide
kubectl -n wazuh exec -it wazuh-indexer-0 -- curl -sk -u admin:$INDEXER_ADMIN_PASSWORD \
  https://localhost:9200/_cluster/health?pretty
kubectl -n wazuh exec -it wazuh-manager-master-0 -- /var/ossec/bin/cluster_control -l
```

Полный чеклист: **[docs/checklist.md](docs/checklist.md)**.

## Отказ от ответственности

Пароли по умолчанию в `cluster.env` — **заглушки**. Смените до production. Пакет не заменяет hardening CIS/STIG и политики вашей ИБ.
