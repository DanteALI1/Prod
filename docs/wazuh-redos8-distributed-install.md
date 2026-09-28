# Установка Wazuh (distributed / multi-node) на РЕД ОС 8

Инструкция для **чистых** серверов РЕД ОС 8: кластер Wazuh **без Kubernetes**, пакетами на отдельных ВМ/хостах.

Основано на официальной документации Wazuh 4.14:

- [Installation guide](https://documentation.wazuh.com/current/installation-guide/index.html)
- [Indexer — assisted](https://documentation.wazuh.com/current/installation-guide/wazuh-indexer/installation-assistant.html)
- [Server — assisted](https://documentation.wazuh.com/current/installation-guide/wazuh-server/installation-assistant.html)
- [Dashboard — assisted](https://documentation.wazuh.com/current/installation-guide/wazuh-dashboard/installation-assistant.html)
- [Architecture / порты](https://documentation.wazuh.com/current/getting-started/architecture.html)
- [Quickstart / ресурсы](https://documentation.wazuh.com/current/quickstart.html)

Целевая нагрузка: **100–200 агентов**.

---

## 0. Заработает ли всё «сразу» в конце?

**Да — центральные компоненты заработают**, если строго соблюдать порядок официального assisted install. Это проверено по документации Wazuh 4.14 (`wazuh-install.sh -h` и Installation guide).

| Что заработает сразу после правильной установки | Что НЕ появится само |
|------------------------------------------------|----------------------|
| Indexer API `:9200`, узлы в `_cat/nodes` | Агенты на endpoints (ставите отдельно) |
| Managers + Filebeat, `cluster_control -l` | Данные/алерты без агентов |
| Dashboard UI по HTTPS + логин `admin` | «Один клик на все 6 серверов» |

**Обязательные условия (иначе не поднимется):**

1. Один и тот же `wazuh-install-files.tar` на **всех** узлах (из одного `--generate-config-files`).
2. Имена в командах = `name` из `config.yml` (байт-в-байт).
3. Порядок: generate → копирование tar → **все** Indexer → `--start-cluster` (**один раз**) → все Server → Dashboard.
4. Сеть/firewall между узлами (9200, 9300–9400, 1514–1516, 55000, 443).
5. Доступ к `packages.wazuh.com` (или offline-пакеты).
6. Достаточно RAM (Indexer рекомендуется **16 GiB** на узел).

**Оговорки по РЕД ОС 8:** в списке поддержки Wazuh указан **RHEL 8**, не «РЕД ОС» по имени. Ставим как RHEL-compatible (dnf/yum, RPM). В редких случаях возможны отличия SELinux/зависимостей — смотрите логи assistant.

**Не путать:** инструкция и скрипт ставят роль на **текущий** сервер. На каждом узле кластера меню запускается отдельно (после копирования `wazuh-install.sh` + `wazuh-install-files.tar`).

### Интерактивный скрипт

```bash
# с репозитория / после копирования на сервер
sudo bash scripts/wazuh-distributed-redos8/install.sh
```

Скрипт: меню по этапам, запрашивает имена/IP/роли, показывает статус сервисов, сохраняет креды в:

`/root/wazuh-install/wazuh-credentials.txt` (права `600`).

**Пункт 15** — удалённая установка по SSH: список серверов из `config.yml`, выбор узла и роли (или весь кластер по порядку). Нужен SSH-ключ без пароля (`ssh-copy-id`).

Под капотом вызывает официальный `wazuh-install.sh` с флагами `-g` / `-wi` / `-s` / `-ws` / `-wd`.

---

## 1. Можно ли без Kubernetes?

**Да.** Это основной способ установки.

Wazuh ставится тремя центральными компонентами:

| Компонент | Что делает |
|-----------|------------|
| **Wazuh indexer** | Хранение и поиск алертов (OpenSearch) |
| **Wazuh server** | Manager + Filebeat: приём данных от агентов, анализ, отправка в indexer |
| **Wazuh dashboard** | Веб-интерфейс |

Kubernetes в документации — только **альтернатива** (Containers). Для РЕД ОС 8 на отдельных серверах используйте **distributed multi-node** через installation assistant.

---

## 2. Архитектура, которую собираем

Рекомендуемая схема для 100–200 агентов с отказоустойчивостью Indexer и Server:

```
                    ┌─────────────────┐
   Агенты ─────────►│  wazuh-mgr-1    │──┐
   (1514/1515)      │  master         │  │
                    └─────────────────┘  │   Filebeat → 9200
                    ┌─────────────────┐  ├──► Indexer cluster
   Агенты ─────────►│  wazuh-mgr-2    │──┘   (node-1, node-2, node-3)
   (через LB опц.)  │  worker         │
                    └─────────────────┘
                              ▲
                              │ API 55000
                    ┌─────────────────┐
                    │  wazuh-dash-1   │◄── браузер :443
                    │  dashboard      │
                    └─────────────────┘
```

### Роли серверов (имена зафиксируйте и не меняйте после генерации сертификатов)

| Имя хоста (пример) | Роль в `config.yml` | IP (пример) |
|--------------------|---------------------|-------------|
| `wazuh-idx-1` | indexer `node-1` | `10.10.10.11` |
| `wazuh-idx-2` | indexer `node-2` | `10.10.10.12` |
| `wazuh-idx-3` | indexer `node-3` | `10.10.10.13` |
| `wazuh-mgr-1` | server `wazuh-1` **master** | `10.10.10.21` |
| `wazuh-mgr-2` | server `wazuh-2` **worker** | `10.10.10.22` |
| `wazuh-dash-1` | dashboard `dashboard` | `10.10.10.31` |

> IP и имена ниже — **примеры**. Замените на свои **до** шага генерации сертификатов.

### Упрощённый вариант (минимум 3 сервера, без HA)

| Сервер | Роль |
|--------|------|
| 1 | Indexer (`node-1`) |
| 2 | Server master (`wazuh-1`) |
| 3 | Dashboard |

Для 100–200 агентов лучше схема с **3 indexer + 2 manager + 1 dashboard** (описана ниже полностью).

---

## 3. Сколько ресурсов выделить на каждый сервер

Официальные рекомендованные значения **на узел** (Wazuh docs):

| Компонент | Min CPU | Min RAM | Рекоменд. CPU | Рекоменд. RAM |
|-----------|---------|---------|---------------|---------------|
| Indexer (каждый узел) | 2 | 4 GiB | **8** | **16 GiB** |
| Server / manager (каждый узел) | 2 | 2 GiB | **8** | **4 GiB** (лучше **8 GiB** при 150–200 агентах) |
| Dashboard | 2 | 4 GiB | **4** | **8 GiB** |

### Диск Indexer (алерты, 90 дней) — на агента

| Тип endpoint | GB / 90 дней |
|--------------|--------------|
| Servers | 3.7 |
| Workstations | 1.5 |
| Network devices | 7.4 |

Пример на ~150 серверов: **~555 GB** только алертов. С ОС, запасом и репликами (при 3 узлах Indexer) ориентир суммарно **500–800+ GB** на кластер Indexer (данные распределяются по узлам; с репликой нужно больше).

### Практичная разметка ВМ под эту инструкцию

| Сервер | vCPU | RAM | Диск |
|--------|------|-----|------|
| `wazuh-idx-1` | 8 | 16 GiB | 300–400 GB SSD |
| `wazuh-idx-2` | 8 | 16 GiB | 300–400 GB SSD |
| `wazuh-idx-3` | 8 | 16 GiB | 300–400 GB SSD |
| `wazuh-mgr-1` | 8 | 8 GiB | 80–100 GB |
| `wazuh-mgr-2` | 8 | 8 GiB | 80–100 GB |
| `wazuh-dash-1` | 4 | 8 GiB | 50 GB |

All-in-one (всё на одном хосте) по официальному Quickstart рассчитан **только до 100 агентов** — для 100–200 **не используйте**.

---

## 4. Что должно быть на серверах до установки

На **каждом** сервере РЕД ОС 8 (только что установленная ОС):

1. Root или пользователь с `sudo`.
2. Архитектура **x86_64**.
3. Доступ в интернет до `packages.wazuh.com` (или offline-метод — отдельно).
4. Статические IP (желательно).
5. Синхронизация времени (NTP/chrony).
6. Имена хостов резолвятся между узлами (DNS или `/etc/hosts`).

РЕД ОС 8 официально в списке Wazuh не назван; установка идёт как на **RHEL 8–compatible** (yum/dnf, RPM).

### 4.1. Обновить систему и базовые пакеты (на каждом узле)

```bash
sudo -i
dnf -y update
dnf -y install curl tar openssl firewalld chrony
systemctl enable --now chronyd
timedatectl set-ntp true
```

### 4.2. Задать hostname (на каждом узле — своё имя)

```bash
# пример на indexer-1
hostnamectl set-hostname wazuh-idx-1
```

Аналогично: `wazuh-idx-2`, `wazuh-idx-3`, `wazuh-mgr-1`, `wazuh-mgr-2`, `wazuh-dash-1`.

### 4.3. `/etc/hosts` (на **всех** узлах одинаковый блок)

```bash
cat >> /etc/hosts << 'EOF'
10.10.10.11  wazuh-idx-1  node-1
10.10.10.12  wazuh-idx-2  node-2
10.10.10.13  wazuh-idx-3  node-3
10.10.10.21  wazuh-mgr-1  wazuh-1
10.10.10.22  wazuh-mgr-2  wazuh-2
10.10.10.31  wazuh-dash-1 dashboard
EOF
```

Проверка с любого узла:

```bash
ping -c1 wazuh-idx-1
ping -c1 wazuh-mgr-1
ping -c1 wazuh-dash-1
```

### 4.4. Firewall (firewalld)

Включите firewalld на всех узлах:

```bash
systemctl enable --now firewalld
```

#### На каждом Indexer (`wazuh-idx-*`)

```bash
firewall-cmd --permanent --add-port=9200/tcp
firewall-cmd --permanent --add-port=9300-9400/tcp
firewall-cmd --reload
```

Разрешите 9200 с IP manager’ов и dashboard; 9300–9400 — между indexer-узлами. Пример ограничения по источнику:

```bash
# с managers и dashboard на API indexer
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.10.10.21" port port="9200" protocol="tcp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.10.10.22" port port="9200" protocol="tcp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.10.10.31" port port="9200" protocol="tcp" accept'
# между indexer
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.10.10.11" port port="9300-9400" protocol="tcp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.10.10.12" port port="9300-9400" protocol="tcp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.10.10.13" port port="9300-9400" protocol="tcp" accept'
firewall-cmd --reload
```

> На этапе первой установки часто временно открывают порты шире, затем сужают. Главное — **не выставлять 9200/9300 в публичный интернет**.

#### На каждом Server / manager (`wazuh-mgr-*`)

```bash
firewall-cmd --permanent --add-port=1514/tcp
firewall-cmd --permanent --add-port=1515/tcp
firewall-cmd --permanent --add-port=1516/tcp
firewall-cmd --permanent --add-port=55000/tcp
firewall-cmd --reload
```

- **1514, 1515** — с сети агентов  
- **1516** — **только** между manager-узлами (не в интернет)  
- **55000** — с dashboard (и админской сети)

#### На Dashboard (`wazuh-dash-1`)

```bash
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --reload
```

### 4.5. SELinux

Оставьте SELinux в `Enforcing`, если так принято в организации. Installation assistant обычно отрабатывает на RHEL-подобных системах. При отказах:

```bash
ausearch -m avc -ts recent
journalctl -u wazuh-indexer -e --no-pager
journalctl -u wazuh-manager -e --no-pager
```

Не отключайте SELinux «навсегда» без политики ИБ.

---

## 5. Порядок работ (строго)

| Шаг | Где | Что |
|-----|-----|-----|
| A | Любой узел (удобно `wazuh-idx-1` или админская машина) | Скачать assistant + `config.yml`, заполнить IP, сгенерировать `wazuh-install-files.tar` |
| B | Скопировать archive | На **все** 6 серверов |
| C | Каждый Indexer | `wazuh-install.sh --wazuh-indexer <имя>` |
| D | **Один** любой Indexer | `wazuh-install.sh --start-cluster` |
| E | Проверка Indexer | `curl` к `:9200` |
| F | Каждый Server | `wazuh-install.sh --wazuh-server <имя>` |
| G | Dashboard | `wazuh-install.sh --wazuh-dashboard dashboard` |
| H | Все узлы | Отключить автообновление репо Wazuh |
| I | Агенты | Установка с Dashboard / документации |

---

## 6. Шаг A — генерация конфигурации и сертификатов

Выполните на машине с доступом в интернет. Удобно — на `wazuh-idx-1`.

```bash
sudo -i
mkdir -p /root/wazuh-install && cd /root/wazuh-install

curl -sO https://packages.wazuh.com/4.14/wazuh-install.sh
curl -sO https://packages.wazuh.com/4.14/config.yml

chmod +x wazuh-install.sh
ls -l
# должны появиться: wazuh-install.sh  config.yml
```

### 6.1. Отредактировать `config.yml`

```bash
cp config.yml config.yml.bak
vi config.yml
```

Содержимое для нашей схемы (подставьте **свои IP**):

```yaml
nodes:
  # Wazuh indexer nodes
  indexer:
    - name: node-1
      ip: "10.10.10.11"
    - name: node-2
      ip: "10.10.10.12"
    - name: node-3
      ip: "10.10.10.13"

  # Wazuh server nodes
  server:
    - name: wazuh-1
      ip: "10.10.10.21"
      node_type: master
    - name: wazuh-2
      ip: "10.10.10.22"
      node_type: worker

  # Wazuh dashboard nodes
  dashboard:
    - name: dashboard
      ip: "10.10.10.31"
```

**Важно:**

- `name` у indexer/server/dashboard потом передаются в `--wazuh-indexer` / `--wazuh-server` / `--wazuh-dashboard` **байт-в-байт**.
- IP должны совпадать с реальными адресами интерфейсов узлов.
- При одном manager уберите worker и `node_type` у единственного server (как в шаблоне Wazuh).

### 6.2. Сгенерировать сертификаты, ключ кластера и пароли

```bash
cd /root/wazuh-install
bash wazuh-install.sh --generate-config-files
```

После успеха в каталоге появится архив:

```text
/root/wazuh-install/wazuh-install-files.tar
```

Внутри (не распаковывайте без нужды на всех узлах — assistant сам возьмёт файлы из tar):

- SSL-сертификаты узлов  
- пароли (`wazuh-passwords.txt`)  
- ключ кластера managers  

Сохраните копию архива в безопасное место (бэкап админа). Без него повторная согласованная установка узлов сложнее.

Посмотреть пароли позже:

```bash
tar -O -xvf wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt
```

---

## 7. Шаг B — разнести файлы по серверам

### Что копировать куда

| Файл | Откуда | Куда на каждом целевом сервере |
|------|--------|--------------------------------|
| `wazuh-install.sh` | `/root/wazuh-install/` | `/root/wazuh-install/wazuh-install.sh` |
| `wazuh-install-files.tar` | `/root/wazuh-install/` | `/root/wazuh-install/wazuh-install-files.tar` |

`config.yml` на остальные узлы **не обязателен** для установки ролей (нужен был для генерации). Нужны **script + tar**.

Пример с `wazuh-idx-1`:

```bash
cd /root/wazuh-install

for h in wazuh-idx-2 wazuh-idx-3 wazuh-mgr-1 wazuh-mgr-2 wazuh-dash-1; do
  ssh root@$h 'mkdir -p /root/wazuh-install'
  scp wazuh-install.sh wazuh-install-files.tar root@$h:/root/wazuh-install/
done
```

Если SSH ещё не настроен — скопируйте носителем/WinSCP, главное путь:

```text
/root/wazuh-install/wazuh-install.sh
/root/wazuh-install/wazuh-install-files.tar
```

На каждом узле проверьте:

```bash
ls -l /root/wazuh-install/
# wazuh-install.sh
# wazuh-install-files.tar
```

---

## 8. Шаг C — установка Wazuh Indexer (на каждом indexer)

Делайте **по очереди** на `wazuh-idx-1`, затем `wazuh-idx-2`, затем `wazuh-idx-3`.

### На `wazuh-idx-1`

```bash
sudo -i
cd /root/wazuh-install
bash wazuh-install.sh --wazuh-indexer node-1
```

### На `wazuh-idx-2`

```bash
cd /root/wazuh-install
bash wazuh-install.sh --wazuh-indexer node-2
```

### На `wazuh-idx-3`

```bash
cd /root/wazuh-install
bash wazuh-install.sh --wazuh-indexer node-3
```

Имя после `--wazuh-indexer` = поле `name` в секции `indexer` файла `config.yml`.

Дождитесь сообщения об успешной установке на каждом узле. Сервис indexer ставится и настраивается assistant’ом (сертификаты берутся из `wazuh-install-files.tar` в текущем каталоге).

---

## 9. Шаг D — инициализация Indexer-кластера (один раз)

Выполните **только на одном** indexer-узле (например `wazuh-idx-1`):

```bash
cd /root/wazuh-install
bash wazuh-install.sh --start-cluster
```

Повторять на других indexer **не нужно**.

---

## 10. Шаг E — проверка Indexer

На любом indexer (или с админской машины с доступом к 9200):

```bash
cd /root/wazuh-install

# пароль admin
tar -axf wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt -O | grep -P "'admin'" -A 1
```

Проверка API (подставьте IP и пароль):

```bash
curl -k -u admin:'<ADMIN_PASSWORD>' https://10.10.10.11:9200
```

Ожидается JSON с `"tagline" : "The OpenSearch Project..."`.

Список узлов кластера:

```bash
curl -k -u admin:'<ADMIN_PASSWORD>' https://10.10.10.11:9200/_cat/nodes?v
```

Должны быть видны **node-1, node-2, node-3**.

Статус сервиса:

```bash
systemctl status wazuh-indexer --no-pager
```

---

## 11. Шаг F — установка Wazuh Server (managers)

### На `wazuh-mgr-1` (master)

```bash
sudo -i
cd /root/wazuh-install
bash wazuh-install.sh --wazuh-server wazuh-1
```

### На `wazuh-mgr-2` (worker)

```bash
sudo -i
cd /root/wazuh-install
bash wazuh-install.sh --wazuh-server wazuh-2
```

Assistant ставит **Wazuh manager + Filebeat**, прописывает сертификаты и связь с indexer из `wazuh-install-files.tar`.

Проверка:

```bash
systemctl status wazuh-manager --no-pager
systemctl status filebeat --no-pager

# список узлов server-кластера
/var/ossec/bin/cluster_control -l
```

Ожидается master `wazuh-1` и worker `wazuh-2` в статусе connected.

Здоровье кластера:

```bash
/var/ossec/bin/cluster_control -i more
```

Конфиг кластера лежит в `/var/ossec/etc/ossec.conf` (блок `<cluster>`). При assisted-установке с `node_type` в `config.yml` он уже должен быть заполнен. Ключ кластера одинаковый на всех managers; порт **1516**.

---

## 12. Шаг G — установка Dashboard

Только на `wazuh-dash-1`:

```bash
sudo -i
cd /root/wazuh-install
bash wazuh-install.sh --wazuh-dashboard dashboard
```

Порт UI по умолчанию **443**. Другой порт:

```bash
bash wazuh-install.sh --wazuh-dashboard dashboard -p 8443
```

В конце вывода будут URL и учётка `admin` / пароль.

Вход:

- URL: `https://10.10.10.31` (или ваш IP/DNS)
- User: `admin`
- Password: из вывода или `wazuh-passwords.txt`

Браузер предупредит о self-signed сертификате — ожидаемо. Можно принять исключение или импортировать `root-ca.pem` из архива установки.

Проверка сервиса:

```bash
systemctl status wazuh-dashboard --no-pager
```

---

## 13. Шаг H — отключить автообновления репозитория Wazuh

На **каждом** узле, где ставились пакеты Wazuh, **после** завершения всех ролей на этом хосте:

```bash
sed -i "s/^enabled=1/enabled=0/" /etc/yum.repos.d/wazuh.repo
# если файл через dnf/yum-репо с другим именем — проверьте:
ls /etc/yum.repos.d/*wazuh*
```

Это рекомендация Wazuh: случайный `dnf update` не должен молча обновить SIEM и «сломать» связку версий.

---

## 14. Куда что установилось (ориентиры путей)

| Что | Типичный путь |
|-----|----------------|
| Конфиг manager | `/var/ossec/etc/ossec.conf` |
| Логи manager | `/var/ossec/logs/` |
| Бинарники/утилиты | `/var/ossec/bin/` (в т.ч. `cluster_control`) |
| Filebeat | `/etc/filebeat/` |
| Indexer | `/etc/wazuh-indexer/`, данные часто под `/var/lib/wazuh-indexer/` |
| Dashboard | `/etc/wazuh-dashboard/` |
| Архив установки (у вас) | `/root/wazuh-install/wazuh-install-files.tar` |

---

## 15. Порты — сводная таблица

| Порт | Протокол | На каком сервере слушает | Кто подключается |
|------|----------|--------------------------|------------------|
| 1514 | TCP | Server | Агенты (события) |
| 1515 | TCP | Server | Агенты (enrollment) |
| 1516 | TCP | Server | Другие Server (кластер) |
| 55000 | TCP | Server | Dashboard / API-клиенты |
| 9200 | TCP | Indexer | Filebeat, Dashboard, curl |
| 9300–9400 | TCP | Indexer | Другие Indexer |
| 443 | TCP | Dashboard | Браузеры аналитиков |

---

## 16. Установка агентов (после центральных компонентов)

1. Откройте Dashboard → **Agents management → Summary → Deploy new agent**.
2. Выберите ОС агента, укажите IP/DNS **manager** (для HA — VIP load balancer на 1514/1515, иначе IP master или оба через настройку агента).
3. Либо по документации: [Wazuh agent](https://documentation.wazuh.com/current/installation-guide/wazuh-agent/index.html).

С агента должны открываться до manager:

- `1514/tcp`
- `1515/tcp`

---

## 17. Чеклист «установка закончена»

- [ ] `curl` к `https://<indexer>:9200` отвечает  
- [ ] `_cat/nodes` показывает все indexer-узлы  
- [ ] `systemctl is-active wazuh-manager` = active на обоих managers  
- [ ] `cluster_control -l` показывает master + worker  
- [ ] Dashboard открывается по HTTPS, логин `admin` работает  
- [ ] В Dashboard видны indexer/API без красных ошибок  
- [ ] Репозиторий `wazuh.repo` выключен (`enabled=0`)  
- [ ] Архив `wazuh-install-files.tar` сохранён офлайн в сейф  

---

## 18. Типичные проблемы

| Симптом | Что проверить |
|---------|----------------|
| Assistant не качает пакеты | DNS, прокси, доступ к `packages.wazuh.com`, `dnf` |
| Indexer не стартует | RAM (нужен запас), `vm.max_map_count`, логи `journalctl -u wazuh-indexer` |
| `_cat/nodes` один узел | firewall 9300–9400, одинаковый cluster name/сертификаты, `--start-cluster` выполнен |
| Managers не в кластере | порт 1516 между ними, одинаковый cluster key, время (NTP) |
| Dashboard «не видит» API | 55000 с dash→mgr, пароли из того же `wazuh-install-files.tar` |
| Агент Pending | 1514/1515, IP manager в конфиге агента, enrollment |

Увеличение `vm.max_map_count` (часто нужно для indexer), на **каждом** indexer:

```bash
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
sysctl -p
```

(Assistant часто делает это сам; если нет — выполните вручную до/после установки.)

---

## 19. Offline-установка (кратко)

Если серверы без интернета: на машине с интернетом скачайте пакеты по [Offline installation](https://documentation.wazuh.com/current/deployment-options/offline-installation/index.html), перенесите на РЕД ОС 8 и ставьте с флагом `--offline-installation` теми же `--wazuh-indexer` / `--wazuh-server` / `--wazuh-dashboard`. Логика ролей и `config.yml` та же.

---

## 20. Ссылки

- Installation guide: https://documentation.wazuh.com/current/installation-guide/index.html  
- Indexer assisted: https://documentation.wazuh.com/current/installation-guide/wazuh-indexer/installation-assistant.html  
- Server assisted: https://documentation.wazuh.com/current/installation-guide/wazuh-server/installation-assistant.html  
- Dashboard assisted: https://documentation.wazuh.com/current/installation-guide/wazuh-dashboard/installation-assistant.html  
- Server cluster config: https://documentation.wazuh.com/current/user-manual/wazuh-server-cluster/cluster-nodes-configuration.html  
- Deployment alternatives (Docker/K8s — не этот гайд): https://documentation.wazuh.com/current/deployment-options/index.html  

---

*Версия пакетов в командах: ветка `4.14` на packages.wazuh.com. Перед установкой сверьте актуальный номер в официальном Installation guide и при необходимости замените URL.*
