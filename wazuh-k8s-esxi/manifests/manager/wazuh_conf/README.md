# Wazuh Manager ossec.conf (cluster)

Файлы `master.conf` / `worker.conf` взяты из официального
[wazuh-kubernetes](https://github.com/wazuh/wazuh-kubernetes) tag `v4.9.2`
(`wazuh/wazuh_managers/wazuh_conf/`) и нужны для сборки Manager-кластера.

- Placeholder ключа: `to_be_replaced_by_cluster_key` → подставляет образ из env `WAZUH_CLUSTER_KEY`
- Worker `node_name`: `to_be_replaced_by_hostname` → `$HOSTNAME` пода
- DNS master в `<nodes>`: `wazuh-manager-master-0.wazuh-cluster.__NAMESPACE__`
  (скрипт подставляет namespace при apply)

См. `docs/cluster-assembly.md`.
