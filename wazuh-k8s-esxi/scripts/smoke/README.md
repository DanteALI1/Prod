# Smoke test (local kind)

Проверка **сборки** Indexer/Manager-кластера на одном kind-узле с урезанными ресурсами.

**Не заменяет** prod на 6 ESXi ВМ.

```bash
# kind + docker уже нужны
kind create cluster --name wazuh-smoke --image kindest/node:v1.30.4
export WAZUH_K8S_ENV=/path/to/config/cluster.env
bash scripts/smoke/deploy-smoke.sh
```

Критерии успеха: Indexer `number_of_nodes=3` green; `cluster_control -l` показывает master + worker.
