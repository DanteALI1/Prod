# Wazuh distributed installer (РЕД ОС 8)

Интерактивная обёртка над официальным `wazuh-install.sh` (без Kubernetes).  
Поддерживает **локальную** и **удалённую (SSH)** установку с выбором сервера и роли.

## Запуск

```bash
sudo bash install.sh
```

## Выбор сервера и роли (новое)

После создания `config.yml` (пункт 3) и генерации сертификатов (пункт 4):

1. Пункт **15** — меню удалённой установки  
2. **b)** настроить SSH (user / port / ключ; нужен вход без пароля)  
3. **c)** выбрать узел из списка (имя + IP + роль из config.yml) и действие  
4. или **d)** поставить весь кластер по порядку: все Indexer → start-cluster → Server → Dashboard  

Скрипт сам копирует на целевой хост `wazuh-install.sh`, `wazuh-install-files.tar`, `install.sh`, `config.yml` и запускает нужную роль.

## Типовой порядок

1. На админ-хосте: **1 → 2 → 3 → 4**  
2. SSH-ключи на все узлы: `ssh-copy-id root@IP`  
3. Пункт **15 → d** (весь кластер) или **15 → c** (по одному серверу)  
4. Креды: пункт **11** → `/root/wazuh-install/wazuh-credentials.txt`

## Non-interactive (для SSH-дочерних вызовов)

```bash
sudo bash install.sh --auto-role indexer --node-name node-1
sudo bash install.sh --auto-role server --node-name wazuh-1
sudo bash install.sh --auto-role dashboard --node-name dashboard --port 443
sudo bash install.sh --auto-role start-cluster
sudo bash install.sh --status
```

## Документация

[`docs/wazuh-redos8-distributed-install.md`](../../docs/wazuh-redos8-distributed-install.md)
