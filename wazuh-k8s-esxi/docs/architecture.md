# Архитектура и расчёт ресурсов — Wazuh on Kubernetes (ESXi)

Документ фиксирует **консервативные допущения**, формулы и итоговые цифры для целевой нагрузки **до 200 агентов**.

## 1. Допущения (явно)

| Параметр | Значение | Обоснование |
|----------|----------|-------------|
| Агенты | 200 | Целевая нагрузка |
| Профиль агентов | mixed Linux/Windows, FIM (scheduled), SCA, vulnerability detection (еженедельно), сбор syslog/Windows Event Log | Если FIM realtime на всех дисках Windows — EPS вырастет в 2–5×; пересчитайте |
| Событий / агент / сутки | **100 000** | Среднее для «средней» нагрузки SecOps; лёгкий профиль ~30–50k, тяжёлый ~200–500k |
| Средний размер события в индексе | **1.2 KiB** | JSON alert ~2 KiB → OpenSearch/Lucene после сжатия и накладных ~0.5–0.7× → берём 1.2 KiB с запасом |
| Реплики индексов | **1** (`number_of_replicas: 1`) | Минимум для переживания потери 1 Indexer-ноды |
| Накладные (segments, translog, merge) | **+25%** | Типичный запас для OpenSearch |
| Hot searchable | **0–14 дней** | Активный поиск/анализ |
| Warm searchable | **14–90 дней** | Поиск реже, диски те же (или slower tier) |
| Cold / archive | **snapshot на 90-й день**, затем delete из hot/warm | Restore по требованию |
| Пиковый запас по EPS | **×4** от среднего | Burst (массовый FIM, malware outbreak, flood логов) |

Если профиль логов неизвестен — используйте эти цифры как **baseline sizing**; после 2 недель production снимите фактический `docs.count` / `store.size` и скорректируйте диски.

## 2. Нагрузка (EPS и события)

### Средний EPS кластера

\[
EPS_{avg} = \frac{N_{agents} \times E_{agent/day}}{86400}
= \frac{200 \times 100000}{86400} \approx \mathbf{231\ EPS}
\]

### Пиковый EPS (проектный)

\[
EPS_{peak} = EPS_{avg} \times 4 \approx \mathbf{924\ EPS}
\]

Indexer и Manager должны комфортно держать **~1000 EPS** sustained short-term.

### Событий в сутки (кластер)

\[
E_{day} = 200 \times 100000 = \mathbf{20\,000\,000}\ \text{events/day}
\]

## 3. Дисковое пространство под индексы

### Суточный прирост primary

\[
S_{day,primary} = E_{day} \times 1.2\ \text{KiB}
= 20\times10^6 \times 1.2\ \text{KiB}
= 24\times10^6\ \text{KiB}
\approx \mathbf{22.9\ GiB/day}
\]

### С учётом реплики

\[
S_{day,total} = S_{day,primary} \times (1 + R) = 22.9 \times 2 = \mathbf{45.8\ GiB/day}
\]

### Hot-tier (14 дней, searchable, с репликой +25%)

\[
S_{hot} = 45.8 \times 14 \times 1.25 \approx \mathbf{802\ GiB}
\]

### Warm (дни 15–90 = 76 дней)

\[
S_{warm} = 45.8 \times 76 \times 1.25 \approx \mathbf{4\,351\ GiB} \approx \mathbf{4.25\ TiB}
\]

### Итого online (0–90 дней) до snapshot/delete

\[
S_{online90} = 45.8 \times 90 \times 1.25 \approx \mathbf{5\,153\ GiB} \approx \mathbf{5.0\ TiB}
\]

### Архивный tier (snapshots, без реплики OpenSearch)

Сжатие snapshot обычно даёт **0.6–0.8×** от primary size:

\[
S_{archive90} \approx 22.9 \times 90 \times 0.7 \approx \mathbf{1\,443\ GiB} \approx \mathbf{1.4\ TiB}
\]

Рекомендуемая ёмкость snapshot repository (NFS/S3): **≥ 3 TiB** (90 дней + запас на несколько restore-копий и рост).

### Распределение по 3 Indexer-нодам

При равномерном шардировании и 1 replica каждый узел держит ≈ ⅔ primary+replica данных:

\[
S_{node} \approx S_{online90} / 3 \approx 5.0 / 3 \approx \mathbf{1.67\ TiB}
\]

**Провижининг диска данных на ноду:** **2.0 TiB** thick (Eager Zeroed) SSD/NVMe + запас роста 20% → целевой заказ **2.4 TiB**, округляем до **2 TiB** при жёстком бюджете с обязательным мониторингом `disk.watermark` **или 3 TiB** для комфортного 12–18 мес. роста.

> **Рекомендация пакета:** data-disk **2 TiB × 3** + archive **3 TiB** NFS/S3. При фактическом EPS > 400 — немедленно расширять data-диски.

## 4. Выбор Kubernetes и ОС

| Вариант | Вердикт для 6–8 ВМ / 200 агентов |
|---------|----------------------------------|
| **kubeadm + containerd** | **Выбран.** Прозрачный control-plane, совпадает с большинством runbook Wazuh, нет vendor lock-in, достаточно для данного размера |
| RKE2 | Альтернатива, если нужен CIS out-of-the-box; чуть сложнее кастомные local PV |
| k3s | Не рекомендуем: упрощённый datastore/networking хуже стыкуется с тяжёлым OpenSearch StatefulSet и local disks |

- **Версия K8s:** `1.30.x` (проверена экосистемой Wazuh 4.9.x; перед апгрейдом сверяйте [wazuh-kubernetes](https://github.com/wazuh/wazuh-kubernetes) releases).
- **ОС:** **Ubuntu 22.04 LTS** — LTS до 2027, отличная поддержка containerd/kubeadm, совпадает с большинством playbook ESXi/SecOps. Rocky 8/9 допустим, но все скрипты пакета заточены под Ubuntu 22.04.
- **CNI:** **Calico** (по умолчанию) — предсказуемые NetworkPolicy. **Cilium** — если нужны Hubble/L7 policy.

## 5. Схема ВМ (роль → количество)

```
                    ┌─────────────────────────────────────┐
                    │  ESXi cluster / vSphere DRS         │
                    └─────────────────────────────────────┘
   k8s-cp-01 (CP)          k8s-worker-01/02              k8s-indexer-01/02/03
   control-plane           general workers               dedicated Indexer workers
   etcd + API              Manager, Dashboard,           taint: wazuh-indexer
                           ingress, monitoring           local PV на /var/lib/wazuh-indexer
```

| # | Роль | Hostname (пример) | Кол-во | Назначение |
|---|------|-------------------|--------|------------|
| 1 | K8s Control-Plane | `k8s-cp-01` | **1** | API, etcd, scheduler. Для HA см. приложение (3 CP) |
| 2 | K8s Worker | `k8s-worker-01`, `k8s-worker-02` | **2** | Wazuh Manager (master+worker), Dashboard, ingress |
| 3 | Wazuh Indexer Node | `k8s-indexer-01..03` | **3** | OpenSearch StatefulSet, local SSD |

**Итого: 6 ВМ.** Manager и Dashboard — **поды** на worker-нодах (не отдельные гипервизорные ВМ), но в пакете есть отдельные guide/script на **деплой роли** Manager/Dashboard.

### HA control-plane (опционально)

Для enterprise SLA добавьте `k8s-cp-02/03` (4 vCPU / 8 GiB / 100 GiB) + keepalived/LB VIP на `:6443`. Для 200 агентов **не обязательно** на старте.

## 6. Ресурсы ВМ и vSphere

| Роль | vCPU | RAM | OS disk | Extra disks | Provisioning | vSphere |
|------|------|-----|---------|-------------|--------------|---------|
| Control-Plane | **4** | **8 GiB** | 100 GiB | 100 GiB containerd (`sdb`) | OS thin OK; containerd thick lazy | Reservation CPU 2 GHz, RAM 8 GiB; anti-affinity с Indexer не критична |
| Worker ×2 | **8** | **16 GiB** | 100 GiB | 200 GiB containerd | thick lazy | VM-VM anti-affinity между worker-01/02; reservation RAM 16 GiB |
| Indexer ×3 | **8** | **32 GiB** | 100 GiB | 100 GiB containerd + **2 TiB data** | **data: Thick Eager Zeroed** | **Hard anti-affinity** (разные ESXi hosts); CPU reservation 4 GHz; **RAM reservation 32 GiB**; latency sensitivity High (опц.) |

### Почему 8/32 на Indexer

OpenSearch heap обычно **≤50% RAM и ≤32 GiB**. При 32 GiB RAM: heap **16 GiB**, остальное — OS page cache (критично для search). 8 vCPU закрывают ~1000 EPS с запасом на merge/refresh.

### Manager / Dashboard (pods)

| Компонент | Replicas | Requests | Limits | PVC |
|-----------|----------|----------|--------|-----|
| Manager master | 1 | 2 CPU / 4 GiB | 4 CPU / 8 GiB | 50 GiB (conf + queue) |
| Manager worker | 1 | 2 CPU / 4 GiB | 4 CPU / 8 GiB | 50 GiB |
| Dashboard | 1 | 500m / 1 GiB | 2 CPU / 4 GiB | — (или 10 GiB) |
| Indexer | 3 | 4 CPU / 24 GiB | 7 CPU / 30 GiB | 2 TiB local each |

## 7. ISM (Index State Management) — 90 дней

| Состояние | Условие | Действия |
|-----------|---------|----------|
| **hot** | age < 14d | 1 replica, force merge не делать часто |
| **warm** | age ≥ 14d | shrink/replicas→1 (уже), priority↓, optional force_merge |
| **cold archive** | age ≥ 90d | `snapshot` в repository → `delete` индекса |

Политика реализована в `config/ism-policy.json` и `scripts/archiving/setup-archiving.sh`.

**Важно:** OpenSearch Dashboards/Wazuh использует **ISM**, не Elasticsearch ILM. В документации пакета «ILM» = жизненный цикл индексов в смысле ISM.

## 8. Порядок развёртывания (high-level)

1. Создать ВМ в vSphere по таблице §6, anti-affinity для Indexer.
2. На всех: базовый Ubuntu 22.04, DNS/`/etc/hosts`, скопировать `config/cluster.env`.
3. `install-control-plane.sh` на `k8s-cp-01`.
4. `install-worker.sh` на worker-01/02.
5. `install-indexer.sh` на indexer-01/02/03 (join + labels/taints + disk).
6. С CP: `install-manager.sh` → `install-dashboard.sh` (Helm/manifests).
7. `setup-archiving.sh` (ISM + snapshot repo).
8. Чеклист `docs/checklist.md`.

Детали — в корневом `README.md` пакета.
