# Wazuh distributed installer (РЕД ОС 8)

Интерактивная обёртка над официальным `wazuh-install.sh` (без Kubernetes).  
Поддерживает **локальную** и **удалённую (SSH)** установку с выбором сервера и роли.

## Запуск

```bash
sudo bash install.sh
```

## Выбор сервера и роли

После `config.yml` (пункт 3) и генерации сертификатов (пункт 4):

1. Пункт **15** — удалённая установка  
2. **b)** SSH **и sudo**:
   - `root` — sudo не нужен  
   - обычный user — нужен **sudo** (лучше NOPASSWD); иначе пароль sudo один раз в память  
3. **c)** один сервер / действие, или **d)** весь кластер  

На целевой машине установка **всегда от root** (требование Wazuh).  
Не-root SSH: `~/wazuh-install-stage` → `sudo` в `/root/wazuh-install` → `sudo bash install.sh …`.

Пример NOPASSWD:

```text
# visudo
deploy ALL=(ALL) NOPASSWD: ALL
```

## Типовой порядок

1. Админ-хост: **1 → 2 → 3 → 4**  
2. `ssh-copy-id user@IP` (+ sudo на узлах)  
3. **15 → b** (SSH/sudo) → **15 → d** или **c**  
4. Креды: **11** → `/root/wazuh-install/wazuh-credentials.txt`

## Non-interactive

```bash
sudo bash install.sh --auto-role indexer --node-name node-1
sudo bash install.sh --auto-role server --node-name wazuh-1
sudo bash install.sh --auto-role dashboard --node-name dashboard --port 443
sudo bash install.sh --auto-role start-cluster
```

## Документация

[`docs/wazuh-redos8-distributed-install.md`](../../docs/wazuh-redos8-distributed-install.md)
