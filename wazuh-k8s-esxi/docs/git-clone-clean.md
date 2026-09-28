# Clone с GitHub без «отпечатка» на сервере

Отдельная инструкция: как доставить пакет **`Prod` / `wazuh-k8s-esxi`** на пустую ВМ **без оставления учётных данных, токена и лишних следов git** на диске сервера.

> **Важно:** скачивание официального репозитория **Wazuh** (`wazuh/wazuh-kubernetes`) на шаге Manager — это **другой** момент.  
> См. отдельно: **[wazuh-upstream-fetch.md](wazuh-upstream-fetch.md)**.

«Отпечаток» здесь — это не SSH host key fingerprint в буквальном смысле, а **следы доступа к GitHub**, которые потом находят аудиторы или злоумышленник:

| Что остаётся | Где лежит | Чем плохо |
|--------------|-----------|-----------|
| PAT / пароль в URL | `.git/config` → `remote.origin.url` | Токен читается с диска, попадает в бэкапы |
| Credential helper | `~/.git-credentials`, `~/.config/gh/` | Долгоживущий секрет на прод-ВМ |
| История + remote | каталог `.git/` | Лишняя поверхность; иногда утекают старые секреты из коммитов |
| `GIT_ASKPASS` / env в истории shell | `~/.bash_history` | Токен в открытом виде в истории команд |

На **production-нодах** репозиторий нужен только как **дистрибутив файлов**. Постоянный `git pull` с GitHub с сервера обычно не нужен.

---

## Рекомендуемый способ (без `.git` на сервере)

Скачать **архив** ветки/тега — на сервере не будет `.git`, remote и токена.

### Публичный репозиторий

```bash
# на админ-ПК или на ВМ (если репо public)
VER=main   # или тег / SHA
curl -fsSL "https://github.com/DanteALI1/Prod/archive/refs/heads/${VER}.tar.gz" \
  -o /tmp/prod.tar.gz

sudo mkdir -p /opt/wazuh-k8s
sudo tar -xzf /tmp/prod.tar.gz -C /opt/wazuh-k8s --strip-components=1
rm -f /tmp/prod.tar.gz

# дальше только каталог пакета
cd /opt/wazuh-k8s/wazuh-k8s-esxi
```

### Приватный репозиторий — токен только в памяти процесса

```bash
# ПОМЕТКА: токен НЕ пишите в команду так, чтобы он попал в history.
# Вариант A: ввести вручную (не сохранится в argv другого пользователя так же легко)
read -rs GITHUB_TOKEN
export GITHUB_TOKEN

curl -fsSL \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/DanteALI1/Prod/tarball/main" \
  -o /tmp/prod.tar.gz

# сразу убрать токен из окружения
unset GITHUB_TOKEN
history -d "$(history 1)" 2>/dev/null || true   # bash: убрать последнюю строку при необходимости

sudo mkdir -p /opt/wazuh-k8s
sudo tar -xzf /tmp/prod.tar.gz -C /opt/wazuh-k8s --strip-components=1
shred -u /tmp/prod.tar.gz 2>/dev/null || rm -f /tmp/prod.tar.gz
```

Проверка, что отпечатка нет:

```bash
test ! -d /opt/wazuh-k8s/.git && echo "OK: нет .git"
grep -RInE 'ghp_|github_pat_|x-access-token' /opt/wazuh-k8s 2>/dev/null \
  || echo "OK: токенов в дереве не найдено"
```

---

## Если всё же нужен `git clone`

### 1) Clone **без** токена в URL

Плохо (отпечаток в `.git/config`):

```bash
# НЕ ДЕЛАЙТЕ ТАК на сервере
git clone https://ghp_XXXX@github.com/DanteALI1/Prod.git
```

Лучше — токен через переменную / askpass, URL чистый:

```bash
read -rs GITHUB_TOKEN
export GITHUB_TOKEN

# URL без секрета
git -c credential.helper= \
  -c "http.extraHeader=Authorization: Bearer ${GITHUB_TOKEN}" \
  clone --depth 1 https://github.com/DanteALI1/Prod.git /opt/wazuh-k8s

unset GITHUB_TOKEN
```

После clone remote уже **без** токена. Дополнительно можно обнулить remote:

```bash
cd /opt/wazuh-k8s
git remote set-url origin https://github.com/DanteALI1/Prod.git
# или полностью убрать связь с GitHub:
git remote remove origin
```

### 2) Снести `.git` после доставки (часто оптимально для prod)

Пакет на ноде — это файлы для `scripts/install.sh`, история git не нужна:

```bash
cd /opt/wazuh-k8s
rm -rf .git
# при желании удалить и сам remote-кэш/credential leftovers пользователя
rm -f ~/.git-credentials
git config --global --unset credential.helper 2>/dev/null || true
```

### 3) Clone на админ-ПК → копирование на сервер (лучший «воздушный зазор»)

На рабочей станции (не на prod-ВМ):

```bash
git clone --depth 1 https://github.com/DanteALI1/Prod.git
# или через SSH-ключ, который живёт только на админ-ПК
tar -czf prod-bundle.tar.gz --exclude='.git' Prod/
```

На сервер:

```bash
scp prod-bundle.tar.gz user@k8s-cp-01:/tmp/
ssh user@k8s-cp-01 'sudo mkdir -p /opt/wazuh-k8s && sudo tar -xzf /tmp/prod-bundle.tar.gz -C /opt/wazuh-k8s --strip-components=1 && rm -f /tmp/prod-bundle.tar.gz'
```

Так на сервере **нет** ни GitHub-токена, ни SSH-ключа к GitHub, ни `.git`.

---

## SSH-clone: про отпечаток host key

При первом `git clone git@github.com:...` ssh спросит **fingerprint** хоста `github.com`. Это нормальная проверка подлинности сервера GitHub, не «ваш» секрет.

Актуальные fingerprints GitHub: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints

```bash
# проверить, что в known_hosts именно официальный ключ
ssh-keyscan -t ed25519,ecdsa,rsa github.com 2>/dev/null | ssh-keygen -lf -
```

На prod-ВМ SSH-ключ к GitHub **лучше не класть**. Если ключ уже использовали — удалите:

```bash
rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa ~/.ssh/id_rsa.pub
# при необходимости почистить github.com из known_hosts:
ssh-keygen -R github.com
```

---

## Чеклист «отпечатка нет» (после доставки пакета)

Выполните на каждой ВМ:

```bash
# 1) нет каталога git (если доставляли архивом / удалили .git)
test ! -d /opt/wazuh-k8s/.git && echo OK_no_git || echo WARN_git_present

# 2) в remote нет токена
git -C /opt/wazuh-k8s remote -v 2>/dev/null | grep -E 'ghp_|github_pat_|x-access-token|:@' \
  && echo BAD_token_in_remote || echo OK_remote

# 3) нет сохранённых credentials
test ! -f ~/.git-credentials && echo OK_no_git_credentials || echo BAD_git_credentials
test ! -d ~/.config/gh && echo OK_no_gh_cli || echo WARN_gh_cli_config

# 4) токен не в history
grep -E 'ghp_|github_pat_|x-access-token' ~/.bash_history ~/.zsh_history 2>/dev/null \
  && echo BAD_history || echo OK_history

# 5) в файлах пакета нет вставленного секрета
grep -RInE 'ghp_|github_pat_' /opt/wazuh-k8s 2>/dev/null \
  && echo BAD_in_tree || echo OK_tree
```

---

## Связка с установкой Wazuh

После чистой доставки:

```bash
sudo mkdir -p /etc/wazuh-k8s
sudo cp /opt/wazuh-k8s/wazuh-k8s-esxi/config/cluster.env /etc/wazuh-k8s/cluster.env
sudo nano /etc/wazuh-k8s/cluster.env   # IP, пароли, диски — НЕ коммитить обратно в GitHub

export WAZUH_K8S_ENV=/etc/wazuh-k8s/cluster.env
cd /opt/wazuh-k8s/wazuh-k8s-esxi
sudo -E bash scripts/install.sh       # выбрать роль / под
```

`cluster.env` с боевыми паролями держите **только** в `/etc/wazuh-k8s/` на серверах (права `600`), не в git.

---

## Краткий выбор метода

| Ситуация | Что делать |
|----------|------------|
| Prod-ВМ, один раз поставить пакет | **Архив** (tarball) или scp с админ-ПК **без** `.git` |
| Нужен `git clone` на ВМ | Clone с `Authorization` header → `git remote remove origin` или `rm -rf .git` |
| Есть PAT в URL уже сейчас | `git remote set-url origin https://github.com/DanteALI1/Prod.git` и **отозвать** PAT на GitHub |
| Нужны обновления с GitHub | Тянуть на админ-ПК, собирать архив, копировать на ВМ — не хранить GitHub-доступ на prod |
