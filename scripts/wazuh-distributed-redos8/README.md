# Wazuh distributed installer (РЕД ОС 8)

Интерактивная обёртка над официальным `wazuh-install.sh` (без Kubernetes).

## Запуск

```bash
sudo bash install.sh
```

Переменные окружения (опционально):

```bash
sudo WAZUH_MAJOR=4.14 WAZUH_WORKDIR=/root/wazuh-install bash install.sh
sudo bash install.sh --status
```

## Типовой порядок на кластере

1. На **первом** узле (удобно indexer-1): пункты меню **1 → 2 → 3 → 4**  
   (подготовка, скачивание, мастер config.yml, генерация сертификатов/паролей).
2. Скопировать на остальные узлы:
   - `/root/wazuh-install/wazuh-install.sh`
   - `/root/wazuh-install/wazuh-install-files.tar`
   - этот `install.sh`
3. На каждом **Indexer**: пункт **7** (имя узла как в config.yml).
4. На **одном** Indexer: пункт **8** (`--start-cluster`).
5. На каждом **Server**: пункт **9**.
6. На **Dashboard**: пункт **10**.
7. Пункт **11** — креды в файл; пункт **12** — отключить yum-репо Wazuh.

## Креды

Файл: `/root/wazuh-install/wazuh-credentials.txt`  
Содержит содержимое `wazuh-passwords.txt` + строки `DASHBOARD_*` / `INDEXER_ADMIN_*`.

## Документация

Полная инструкция: [`docs/wazuh-redos8-distributed-install.md`](../../docs/wazuh-redos8-distributed-install.md)
