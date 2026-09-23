# Восстановление архивных индексов Wazuh (OpenSearch snapshots)

Цель: вернуть данные **старше 90 дней** из cold snapshot repository в кластер Indexer для просмотра в Dashboard, затем при необходимости снова удалить.

## Preconditions

- Snapshot repository зарегистрирован (`setup-archiving.sh`).
- Кластер Indexer `green` или `yellow`, свободное место ≥ размера восстанавливаемых индексов × (1+replicas) × 1.25.
- Известны имя snapshot и индексов (`wazuh-alerts-4.x-yyyy.mm.dd`).

## 1. Список snapshots

```bash
export WAZUH_K8S_ENV=/etc/wazuh-k8s/cluster.env
bash scripts/archiving/restore-archive.sh --list
```

Эквивалент вручную:

```bash
kubectl -n wazuh exec wazuh-indexer-0 -- curl -sk -u admin:$INDEXER_ADMIN_PASSWORD \
  https://localhost:9200/_cat/snapshots/wazuh-cold-archive?v
```

## 2. Просмотр индексов внутри snapshot

```bash
bash scripts/archiving/restore-archive.sh --show SNAPSHOT_NAME
```

## 3. Restore во временные индексы

Скрипт восстанавливает с префиксом `restore-` (не затирает live indices):

```bash
bash scripts/archiving/restore-archive.sh \
  --restore SNAPSHOT_NAME \
  --indices 'wazuh-alerts-4.x-2025.01.*'
```

Параметры из `cluster.env`: `SNAPSHOT_REPO_NAME`, пароли.

## 4. Просмотр в Dashboard

1. Stack Management → Index Patterns → создать `restore-wazuh-alerts-*`.
2. Discover / Wazuh → использовать временный pattern.
3. Либо временно добавить alias:

```bash
bash scripts/archiving/restore-archive.sh --alias-add 'restore-wazuh-alerts-4.x-2025.01.15'
```

## 5. Удаление после расследования (освобождение hot disk)

```bash
bash scripts/archiving/restore-archive.sh --delete-restored 'restore-wazuh-alerts-*'
```

## 6. Ручной snapshot «прямо сейчас» (вне ISM)

```bash
bash scripts/archiving/setup-archiving.sh   # регистрирует repo при необходимости
# или:
bash scripts/archiving/restore-archive.sh --snapshot-now
```

## Оценка места перед restore

\[
S_{need} \approx S_{snapshot\_indices} \times (1+R) \times 1.25
\]

Пример: 7 дней алертов ≈ 7 × 22.9 GiB primary ≈ 160 GiB primary → с replica ~400 GiB на кластер.

Если места нет — временно снизьте replica на restore-индексах до 0:

```bash
bash scripts/archiving/restore-archive.sh --restore SNAP --indices '...' --replicas 0
```

## Troubleshooting

| Ошибка | Действие |
|--------|----------|
| `repository_missing_exception` | Перезапустить `setup-archiving.sh` |
| `index_already_exists` | Используйте rename/prefix (скрипт делает `restore-`) |
| Snapshot `PARTIAL` | Проверьте NFS/S3, повторите snapshot с ISM/manual |
| Dashboard не видит поля | Обновить index pattern / refresh field list |
