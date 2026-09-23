# РЕД ОС 8 и Astra Linux — установка с нуля

Серверы **пустые**: только чистая ОС. Скрипты сами ставят зависимости (curl, lvm2, containerd, kubeadm…).

Целевая нагрузка и размеры ВМ/подов — те же, что в `docs/pods-resources-simple.md` (Ubuntu больше не обязателен).

---

## Что выбрать

| ОС | Когда брать | Пакетный менеджер | Особенности |
|----|-------------|-------------------|-------------|
| **РЕД ОС 8** | Требование импортозамещения / RPM-контур | `dnf` | SELinux → скрипт ставит **permissive**; containerd с **бинарников** |
| **Astra Linux** (SE 1.7/1.8) | Требование Astra / Debian-контур | `apt` | Почти как Debian; K8s из deb-репозитория pkgs.k8s.io |

Можно смешивать ОС на разных ВМ **не рекомендуется** — берите одну ОС на весь кластер.

---

## Подготовка до скриптов (на каждой ВМ)

1. Установить минимальную ОС (без GUI).
2. Настроить **статический IP**, hostname, DNS или `/etc/hosts` на все 6 узлов.
3. Доступ в интернет (или зеркало) до:
   - `pkgs.k8s.io`
   - `github.com` (containerd/runc/cni на РЕД ОС)
   - `raw.githubusercontent.com` (Calico)
   - `registry.k8s.io` / Docker Hub (образы pause, Wazuh)
4. Скопировать пакет `wazuh-k8s-esxi/` на ВМ.
5. Заполнить `config/cluster.env` (IP, пароли, имена дисков `/dev/sdb`, `/dev/sdc`).

```bash
sudo mkdir -p /etc/wazuh-k8s
sudo cp config/cluster.env /etc/wazuh-k8s/cluster.env
# Отредактировать IP/пароли:
sudo nano /etc/wazuh-k8s/cluster.env
export WAZUH_K8S_ENV=/etc/wazuh-k8s/cluster.env
```

Опционально зафиксировать ОС:

```bash
# в cluster.env
TARGET_OS=redos    # или astra
```

---

## РЕД ОС 8 — нюансы

| Тема | Как сделано в скриптах |
|------|------------------------|
| SELinux | `SELINUX_MODE=permissive` (по умолчанию). Для enforcing нужна донастройка политик. |
| firewalld | При активном firewalld открываются порты роли (6443, 10250, 9200/9300, 1514/1515…). |
| containerd | `CONTAINERD_INSTALL_METHOD=auto` → **binary** (официальный tar + runc + CNI). |
| kubelet/kubeadm | yum-репозиторий `pkgs.k8s.io` … `/rpm/`, версия `K8S_VERSION_RPM=1.30.4`. |
| Swap | Отключается (требование Kubernetes). |
| Имена дисков | Часто `/dev/sdb`, `/dev/sdc` (как в VMware). Проверьте `lsblk`. |

Минимальные пакеты до запуска **не нужны** — `bootstrap_host_tools` поставит их сам.  
Нужен только работающий `dnf` и доступ к репозиториям РЕД ОС (базовая ОС).

Пример запуска control-plane:

```bash
sudo -E bash scripts/control-plane/install-control-plane.sh
```

---

## Astra Linux — нюансы

| Тема | Как сделано в скриптах |
|------|------------------------|
| apt | Используется как на Debian/Ubuntu. |
| containerd | Сначала пакет `containerd` из репозитория Astra/Debian; при сбое — binary. |
| kubelet/kubeadm | deb-репозиторий `pkgs.k8s.io`, версия `K8S_VERSION=1.30.4-1.1`. |
| Мандатный контроль Astra | При жёстких политиках PARSEC может понадобиться допуск служб — согласуйте с админом ИБ. |
| Подпись репозиториев | Скрипт ставит ключ pkgs.k8s.io в `/etc/apt/keyrings`. |

Если `apt-get install kubelet=1.30.4-1.1` не проходит из‑за политики Astra — ослабьте удержание версий или поставьте пакеты из внутреннего зеркала; переменная `K8S_VERSION` должна совпадать с доступным пакетом.

---

## Порядок на обеих ОС (одинаковый)

| Шаг | Где | Команда |
|-----|-----|---------|
| 1 | `k8s-cp-01` | `sudo -E bash scripts/control-plane/install-control-plane.sh` |
| 2 | Заполнить `KUBEADM_TOKEN` и `KUBEADM_HASH` в `cluster.env` (скрипт печатает готовые строки) |
| 3 | worker-01, worker-02 | `sudo -E bash scripts/worker/install-worker.sh` |
| 4 | indexer-01..03 | `sudo -E bash scripts/indexer/install-indexer.sh` |
| 5 | CP | `sudo -E bash scripts/common/label-nodes.sh` |
| 6 | CP | `sudo -E bash scripts/manager/install-manager.sh` |
| 7 | CP | `sudo -E bash scripts/dashboard/install-dashboard.sh` |
| 8 | CP | `sudo -E bash scripts/archiving/setup-archiving.sh` |
| 9 | | `docs/checklist.md` |

Логи: `/var/log/wazuh-k8s-install/`.

`DRY_RUN=true` — только показать действия, без изменений.

---

## Сеть /hosts (пример)

```text
10.10.10.10 k8s-cp-01
10.10.10.21 k8s-worker-01
10.10.10.22 k8s-worker-02
10.10.10.31 k8s-indexer-01
10.10.10.32 k8s-indexer-02
10.10.10.33 k8s-indexer-03
```

Имена в `INDEXER_HOSTS` / `WORKER_HOSTS` должны совпадать с `kubectl get nodes` (обычно короткий hostname).

---

## Что проверить после установки ОС-слоя

```bash
# на каждой ноде
cat /etc/os-release
systemctl is-active containerd
swapoff -s          # должно быть пусто
sysctl vm.max_map_count   # 262144 на indexer особенно важно

# на CP
kubectl get nodes -o wide
```

---

## Типичные проблемы

| Симптом | Что сделать |
|---------|-------------|
| `Unsupported OS` | Проверьте `/etc/os-release`; задайте `TARGET_OS=redos` или `astra` |
| нет `/dev/sdc` на indexer | Посмотрите `lsblk`, поправьте `INDEXER_DATA_DISK` |
| worker не join | TOKEN/HASH протухли (24ч) — создайте новый на CP: `kubeadm token create --print-join-command` |
| SELinux / AVC на РЕД ОС | Оставьте permissive на этапе внедрения |
| образы не тянутся | Нужен доступ к registry или внутреннее зеркало / `imagePullSecrets` |
| PVC Manager Pending | Имена в PV должны совпадать с hostname worker; скрипт менеджера подставляет их из `cluster.env` |

Ресурсы по подам — снова: **`docs/pods-resources-simple.md`**.
