# Install Guide — Wazuh Dashboard

Роль: UI (**Wazuh Dashboard** / OpenSearch Dashboards + Wazuh plugin). Под на **general worker**.

## Ресурсы пода

| | Request | Limit |
|---|---------|-------|
| CPU | 500m | 2 |
| RAM | 1 GiB | 4 GiB |

Отдельная ВМ не требуется — заложено в Worker 8/16.

## Сеть

| | |
|---|---|
| Service | `wazuh-dashboard` ClusterIP или NodePort `443` |
| Upstream Indexer | `https://wazuh-indexer:9200` |
| Upstream Manager API | `https://wazuh-manager-master-0.wazuh-cluster:55000` |

TLS: Dashboard → Indexer с CA из secret; браузер → Dashboard (self-signed или Ingress corp cert).

## Пошагово

```bash
export WAZUH_K8S_ENV=/etc/wazuh-k8s/cluster.env
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo -E bash scripts/dashboard/install-dashboard.sh
```

Скрипт проверяет Ready Indexer и Manager API, применяет Deployment/Service, ждёт Available.

### Проверка

```bash
kubectl -n wazuh get deploy,svc wazuh-dashboard
# NodePort или port-forward:
kubectl -n wazuh port-forward svc/wazuh-dashboard 8443:443
# Browser https://127.0.0.1:8443  (user admin / DASHBOARD or indexer creds per chart)
```

### Типовые проблемы

| Симптом | Фикс |
|---------|------|
| `Red` indices plugin | Indexer ещё не зелёный — ждать ISM/shards |
| API 3021 | Неверный пароль API — сверить secret |
| Blank page | Сертификат Indexer не доверен — пересоздать secrets/certs |

## Дальше

`scripts/archiving/setup-archiving.sh` — ISM 90 дней + snapshot repository.
