# Скачивание репозитория Wazuh (`wazuh-kubernetes`) без отпечатка

Этот документ про **конкретный момент** в установке: когда скрипт Manager
тянет официальный upstream с GitHub.

Не путать с доставкой **вашего** пакета `Prod` / `wazuh-k8s-esxi` на ВМ  
(для этого — `docs/git-clone-clean.md`).

---

## Где это происходит

| | |
|--|--|
| **Скрипт** | `scripts/manager/install-manager.sh` → `fetch_wazuh_kubernetes` |
| **Когда** | роль `manager` (после labels, с control-plane) |
| **Репозиторий** | [github.com/wazuh/wazuh-kubernetes](https://github.com/wazuh/wazuh-kubernetes) |
| **Каталог на CP** | `/var/tmp/wazuh-kubernetes` (`WAZUH_K8S_WORKDIR`) |
| **Тег** | `WAZUH_K8S_TAG` (по умолчанию `v4.9.2`) |

После скачивания пакет применяет **локальные** hardened STS/SVC из `manifests/`.  
Из tarball реально используются эталонные **`master.conf` / `worker.conf`**  
(блок `<cluster>`) → ConfigMap `wazuh-conf`. Без этого Manager-кластер не соберётся  
корректно (образ ждёт `WAZUH_CLUSTER_KEY` + mounted ossec.conf).  

Подробности сборки: **`docs/cluster-assembly.md`**. `.git` на диске не нужен.

---

## В чём «отпечаток»

Раньше скрипт делал:

```bash
git clone --depth 1 --branch v4.9.2 \
  https://github.com/wazuh/wazuh-kubernetes.git \
  /var/tmp/wazuh-kubernetes
```

На сервере оставалось:

| След | Путь |
|------|------|
| каталог `.git` | `/var/tmp/wazuh-kubernetes/.git` |
| remote `origin` | URL GitHub в `config` |
| факт pull с github.com | логи, conntrack, иногда proxy-логи |

Репозиторий **публичный** — токен обычно не нужен. Отпечаток здесь =  
**оставшийся git-метаданные и постоянная связь с GitHub на диске prod**.

---

## Как сделано сейчас (по умолчанию)

В `cluster.env`:

```bash
WAZUH_K8S_FETCH_METHOD=tarball   # рекомендуется
WAZUH_K8S_STRIP_GIT=true
WAZUH_K8S_WORKDIR=/var/tmp/wazuh-kubernetes
WAZUH_K8S_TAG=v4.9.2
```

### Режим `tarball` (по умолчанию)

Скрипт качает архив тега **без** git:

```text
https://github.com/wazuh/wazuh-kubernetes/archive/refs/tags/v4.9.2.tar.gz
  → распаковка в /var/tmp/wazuh-kubernetes
  → .git отсутствует
```

Эквивалент вручную:

```bash
TAG=v4.9.2
curl -fsSL \
  "https://github.com/wazuh/wazuh-kubernetes/archive/refs/tags/${TAG}.tar.gz" \
  -o /tmp/wazuh-k8s.tar.gz
sudo rm -rf /var/tmp/wazuh-kubernetes
sudo mkdir -p /var/tmp/wazuh-kubernetes
sudo tar -xzf /tmp/wazuh-k8s.tar.gz -C /var/tmp/wazuh-kubernetes --strip-components=1
rm -f /tmp/wazuh-k8s.tar.gz
test ! -d /var/tmp/wazuh-kubernetes/.git && echo "OK: нет .git"
```

### Режим `git`

Если tarball недоступен или явно задано `WAZUH_K8S_FETCH_METHOD=git`:

1. `git clone --depth 1 --branch $WAZUH_K8S_TAG` по **чистому** https URL (без токена в строке).
2. При `WAZUH_K8S_STRIP_GIT=true` (default) сразу: `rm -rf …/.git`.

### Режим `skip`

```bash
export WAZUH_K8S_FETCH_METHOD=skip
```

Upstream **не** скачивается. Деплой идёт только из локальных `manifests/` пакета.  
Удобно для закрытого контура без доступа к GitHub с CP.

---

## Закрытый контур (нет выхода в GitHub с CP)

1. На админ-ПК скачать tarball (команда выше).
2. Залить на CP: `scp wazuh-k8s.tar.gz user@k8s-cp-01:/tmp/`.
3. Распаковать в `/var/tmp/wazuh-kubernetes` **без** `.git`.
4. На CP:

```bash
export WAZUH_K8S_FETCH_METHOD=skip
sudo -E bash scripts/install.sh --role manager
# или
sudo -E bash scripts/manager/install-manager.sh
```

Либо положить уже распакованный каталог и оставить `tarball` — скрипт увидит  
готовое дерево без `.git` и **не** будет качать снова.

---

## Проверка после роли `manager`

```bash
# нет git-отпечатка upstream
test ! -d /var/tmp/wazuh-kubernetes/.git && echo OK_no_git || echo BAD_git_left

# нет токена в любых remote (если .git вдруг оставили)
git -C /var/tmp/wazuh-kubernetes remote -v 2>/dev/null \
  | grep -E 'ghp_|github_pat_|x-access-token' && echo BAD || echo OK

# что реально задеплоено — из локальных manifests пакета
kubectl -n wazuh get sts,deploy,svc
```

---

## Связанные переменные (`cluster.env`)

| Переменная | Default | Смысл |
|------------|---------|--------|
| `WAZUH_K8S_TAG` | `v4.9.2` | тег upstream |
| `WAZUH_K8S_GIT` | `https://github.com/wazuh/wazuh-kubernetes.git` | URL для режима `git` |
| `WAZUH_K8S_FETCH_METHOD` | `tarball` | `tarball` \| `git` \| `skip` |
| `WAZUH_K8S_WORKDIR` | `/var/tmp/wazuh-kubernetes` | куда класть файлы |
| `WAZUH_K8S_STRIP_GIT` | `true` | удалять `.git` после clone |

---

## Кратко

| Вопрос | Ответ |
|--------|--------|
| Когда качается Wazuh repo? | На шаге **manager**, с control-plane |
| Как не оставить отпечаток? | `WAZUH_K8S_FETCH_METHOD=tarball` (default) или `skip` + ручная доставка |
| Нужен ли токен? | Нет, репо публичный; **не** вставляйте PAT в URL |
| Нужен ли `.git` на CP? | Нет — для prod оставляйте только распакованные файлы |
