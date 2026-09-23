# Мониторинг и обслуживание

## 1. Здоровье кластера индексов

```bash
# Общий статус
kubectl -n wazuh exec wazuh-indexer-0 -- curl -sk -u admin:$INDEXER_ADMIN_PASSWORD \
  'https://localhost:9200/_cluster/health?pretty'

# Ноды и диск
kubectl -n wazuh exec wazuh-indexer-0 -- curl -sk -u admin:$INDEXER_ADMIN_PASSWORD \
  'https://localhost:9200/_cat/nodes?v&h=name,heap.percent,ram.percent,disk.used_percent,node.role'

# Индексы Wazuh
kubectl -n wazuh exec wazuh-indexer-0 -- curl -sk -u admin:$INDEXER_ADMIN_PASSWORD \
  'https://localhost:9200/_cat/indices/wazuh-*?v&s=index'

# ISM explain
kubectl -n wazuh exec wazuh-indexer-0 -- curl -sk -u admin:$INDEXER_ADMIN_PASSWORD \
  'https://localhost:9200/_plugins/_ism/explain/wazuh-alerts-*' | jq 'keys'
```

Ожидание production: **green**, disk.used_percent **< 75**, heap.percent **< 85**.

### Оценка фактического EPS

```bash
# docs count delta за интервал — грубая оценка
kubectl -n wazuh exec wazuh-indexer-0 -- curl -sk -u admin:$INDEXER_ADMIN_PASSWORD \
  'https://localhost:9200/wazuh-alerts-*/_count'
```

Сравните суточный прирост `store.size` с расчётом 22.9 GiB/day primary.

## 2. Ручная ротация / архивация

| Задача | Команда |
|--------|---------|
| Snapshot сейчас | `scripts/archiving/restore-archive.sh --snapshot-now` |
| Список архивов | `restore-archive.sh --list` |
| Restore для расследования | см. `restore-guide.md` |
| Принудительный ISM retry | `POST /_plugins/_ism/retry/wazuh-alerts-...` |

Закрытие «дырявого» индекса вручную (если ISM завис):

```bash
# 1) snapshot  2) close  3) delete — только после SUCCESS snapshot
```

## 3. Бэкап конфигурации Manager

Автоматически после `install-manager.sh`. Повторить:

```bash
sudo -E bash scripts/manager/install-manager.sh --backup-only
```

Что входит: rules, decoders, shared agent groups, `ossec.conf`.

Рекомендуемый график: **ежедневно** + перед любым изменением правил. Хранить копии **вне** кластера (NFS/S3), retention ≥ 90 дней.

Восстановление:

```bash
kubectl -n wazuh cp ./wazuh-manager-conf-DATE.tgz wazuh-manager-master-0:/tmp/restore.tgz
kubectl -n wazuh exec -it wazuh-manager-master-0 -- sh -c \
  'cd / && tar xzf /tmp/restore.tgz && /var/ossec/bin/wazuh-control restart'
```

(уточняйте пути под фактический layout образа; тестируйте на staging).

## 4. Rolling maintenance Indexer

1. `kubectl -n wazuh drain <node> --ignore-daemonsets --delete-emptydir-data` **не** для local PV без осторожности.  
2. Лучше: OpenSearch replica уже 1 → остановить **один** pod Indexer → maintenance ESXi → start.  
3. Дождаться green перед следующим узлом.

## 5. Обновление версии Wazuh

1. Читать release notes `wazuh-kubernetes` tag.  
2. Сменить `WAZUH_VERSION` / `WAZUH_K8S_TAG` в `cluster.env`.  
3. Snapshot всех индексов.  
4. Rolling update images STS/Deploy.  
5. Прогнать `docs/checklist.md` §D–H.
