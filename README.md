# Prod

Production deployment package for **Wazuh on Kubernetes (VMware ESXi)**.

Целевые ОС: **РЕД ОС 8**, **Astra Linux** (серверы с нуля).

**Установка на пустой сервер** — общий скрипт с выбором роли/пода:

```bash
cd wazuh-k8s-esxi
sudo -E bash scripts/install.sh
```

- Ресурсы по подам простым языком: [wazuh-k8s-esxi/docs/pods-resources-simple.md](wazuh-k8s-esxi/docs/pods-resources-simple.md)
- Установка на РЕД ОС / Astra: [wazuh-k8s-esxi/docs/os-redos-astra.md](wazuh-k8s-esxi/docs/os-redos-astra.md)
- Полный пакет: [wazuh-k8s-esxi/README.md](wazuh-k8s-esxi/README.md)
