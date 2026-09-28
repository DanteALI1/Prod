# Prod

Production deployment package for **Wazuh on Kubernetes (VMware ESXi)**.

Целевые ОС: **РЕД ОС 8**, **Astra Linux** (серверы с нуля).

**Wazuh без Kubernetes (distributed / multi-node на РЕД ОС 8):**  
[docs/wazuh-redos8-distributed-install.md](docs/wazuh-redos8-distributed-install.md)

**Установка на пустой сервер** — общий скрипт с выбором роли/пода:

```bash
cd wazuh-k8s-esxi
sudo -E bash scripts/install.sh
```

- Ресурсы по подам простым языком: [wazuh-k8s-esxi/docs/pods-resources-simple.md](wazuh-k8s-esxi/docs/pods-resources-simple.md)
- Установка на РЕД ОС / Astra: [wazuh-k8s-esxi/docs/os-redos-astra.md](wazuh-k8s-esxi/docs/os-redos-astra.md)
- Доставка пакета Prod без отпечатка: [wazuh-k8s-esxi/docs/git-clone-clean.md](wazuh-k8s-esxi/docs/git-clone-clean.md)
- Скачивание upstream Wazuh без `.git`: [wazuh-k8s-esxi/docs/wazuh-upstream-fetch.md](wazuh-k8s-esxi/docs/wazuh-upstream-fetch.md)
- Как собирается кластер: [wazuh-k8s-esxi/docs/cluster-assembly.md](wazuh-k8s-esxi/docs/cluster-assembly.md)
- Полный пакет: [wazuh-k8s-esxi/README.md](wazuh-k8s-esxi/README.md)
