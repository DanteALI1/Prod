# Сеть, безопасность и StorageClass

## 1. Логическая схема портов

```
[Agents 200]
    │ 1514/tcp (events), 1515/tcp (enrollment)
    ▼
[Service/Ingress → wazuh-manager]
    │
    ├─ 55000/tcp  Wazuh API  ← Dashboard, automations
    │
    ▼ filebeat / alerts
[wazuh-indexer StatefulSet :9200/:9300]
    ▲
    │ 443/tcp (HTTPS)
[wazuh-dashboard] ← operators (browser)
```

### Порты между компонентами

| Источник | Назначение | Порт | Протокол | Назначение |
|----------|------------|------|----------|------------|
| Agent | Manager | 1514 | TCP | События (после enrollment) |
| Agent | Manager | 1515 | TCP | Enrollment |
| Dashboard / ops | Manager API | 55000 | TCP/TLS | REST API |
| Manager (Filebeat) | Indexer | 9200 | HTTPS | Запись алертов |
| Indexer ↔ Indexer | Indexer | 9300 | TLS | Transport / cluster |
| Browser | Dashboard | 443 | HTTPS | UI |
| Admin | K8s API | 6443 | HTTPS | kube-apiserver |
| Node ↔ Node | Calico | 179 | TCP | BGP (если BGP mode) |
| Node ↔ Node | Calico VXLAN | 4789 | UDP | overlay (IP-in-IP/VXLAN) |
| Snapshot | NFS/S3 | 2049 / 443/9000 | — | Cold archive |

### Firewall (пример ESXi/NSX / iptables perimeter)

Разрешить с agent VLAN → worker NodePort/LB только **1514, 1515**.  
Indexer **9200/9300** — **только** внутри cluster network / namespace `wazuh`. Не публиковать Indexer наружу.

## 2. CNI: Calico (default) vs Cilium

| | Calico | Cilium |
|---|--------|--------|
| Сложность | Ниже | Выше |
| NetworkPolicy L3/L4 | Да | Да |
| L7 / Hubble | Нет | Да |
| Рекомендация пакета | **Default для 200 агентов** | Если SecOps требует DNS/HTTP visibility |

Установка Calico выполняется в `install-control-plane.sh`. Для Cilium: `CNI_PLUGIN=cilium` в `cluster.env` (скрипт ставит Cilium via Helm).

Рекомендуемые NetworkPolicy (идея):

- Deny all ingress in `wazuh` except from labeled pods.
- Allow agents CIDR → Manager service ports 1514/1515.
- Allow Dashboard → Indexer 9200, Manager 55000.
- Deny external → Indexer.

Манифесты-заготовки: `manifests/network/`.

## 3. TLS между Indexer / Manager / Dashboard

Официальный репозиторий `wazuh/wazuh-kubernetes` поставляет скрипты генерации сертификатов (`wazuh-certs-tool` / openssl в `certs/`).

Цепочки:

| Связь | Тип | Где лежит |
|-------|-----|-----------|
| Indexer nodes | transport + http TLS | Secret `indexer-certs` |
| Filebeat → Indexer | client cert / user+pass + CA | Secret в Manager pods |
| Dashboard → Indexer | CA + credentials | Secret `dashboard-creds` |
| Dashboard UI | HTTPS (self-signed или corp CA) | Ingress / Dashboard cert |
| Manager cluster | `wazuh_cluster_key` (32 hex) | ConfigMap/Secret |

Скрипты `install-manager.sh` / `install-indexer` deploy path вызывают генерацию, если секреты отсутствуют. В production замените на корпоративный PKI:

1. Выпустить CA.
2. Indexer: cert с SAN = pod DNS `wazuh-indexer-{0,1,2}.wazuh-indexer.wazuh.svc`.
3. Прописать CA во все truststore.

Ротация: не чаще 1 раза в год без автоматизации; при ротации — rolling restart Indexer (один узел за раз), затем Manager/Dashboard.

## 4. StorageClass и PersistentVolume

### Indexer (критичный путь I/O)

| Вариант | Вердикт |
|---------|---------|
| **local / hostPath + static PV** | **Рекомендуется.** Путь `/var/lib/wazuh-indexer` на thick Eager Zeroed SSD |
| NFS | **Нельзя** для data path OpenSearch (latency, locking) |
| vSAN thick | Допустимо, если latencies < 5–10 ms p99 и anti-affinity VM соблюдены |
| Longhorn/Ceph | Избыточно и рискованно для OS digests на 200 agents без отдельной экспертизы |

Пакет использует StorageClass `wazuh-indexer-local` (`manifests/storage/storageclass-indexer-local.yaml`) + pre-bound PV на каждую Indexer-ноду.

### Manager / Dashboard PVC

| Вариант | Вердикт |
|---------|---------|
| NFS RWX | OK для бэкапов конфигов |
| vSAN / CSI RWO | **OK** для Manager data |
| local-path (Rancher) | OK на worker, если не планируете migrate pod без drain |

Default в values: StorageClass `wazuh-general` → CSI/vSAN если есть, иначе `local-path`.

### Snapshot repository (cold)

| Тип | Когда |
|-----|-------|
| `fs` + NFS mount `/mnt/wazuh-snapshots` на всех Indexer | Простая ESXi lab / без S3 |
| `s3` (MinIO / ECS / AWS) | **Предпочтительно** в production |

## 5. Секреты и доступы

- Пароли только в `cluster.env` / SealedSecrets / External Secrets — **не в git**.
- RBAC: отдельный kubeconfig для Wazuh admins (namespace `wazuh` only).
- Audit log kube-apiserver — включить на CP.
- Отключить anonymous auth на Indexer; пользователь `admin` — только break-glass.
