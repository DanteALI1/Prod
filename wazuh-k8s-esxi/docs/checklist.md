# Чеклист успешного развёртывания Wazuh on Kubernetes (ESXi)

Отмечайте пункты после выполнения. Цель — подтвердить готовность к подключению ~200 агентов.

## A. Инфраструктура ESXi / ВМ

- [ ] 6 ВМ созданы по таблице README (1 CP + 2 worker + 3 indexer)
- [ ] ОС: РЕД ОС 8 **или** Astra Linux (или Ubuntu 22.04) на всех узлах одного кластера
- [ ] На пустых серверах скрипты отработали bootstrap (curl/containerd/kubeadm)
- [ ] Indexer anti-affinity: разные ESXi hosts
- [ ] RAM reservation на Indexer = 32 GiB; data disk Thick Eager Zeroed 2 TiB
- [ ] `/etc/hosts` или DNS резолвит все узлы
- [ ] `cluster.env` заполнен (IP, токены, пароли ≠ default)

## B. Kubernetes

- [ ] `kubectl get nodes` → все **Ready** (6)
- [ ] Labels: 2× `wazuh.role=general`, 3× `wazuh.role=indexer`
- [ ] Taint `wazuh-indexer=true:NoSchedule` на 3 indexer
- [ ] CNI pods Running (`calico-node` / `cilium`)
- [ ] Namespace `wazuh` существует

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.wazuh\\.role,TAINTS:.spec.taints
```

## C. Диски Indexer

- [ ] На каждой indexer-ноде: `df -h /var/lib/wazuh-indexer` ≥ ~1.8 TiB avail
- [ ] FS = xfs, mount opts содержат `noatime`
- [ ] `PV` Bound: `kubectl get pv | grep wazuh-indexer`

## D. Wazuh Indexer (OpenSearch)

- [ ] 3/3 pods Running: `kubectl -n wazuh get pods -l app=wazuh-indexer -o wide`
- [ ] Поды на разных indexer-нодах
- [ ] Cluster health green (допустимо yellow только пока нет replica allocation на новых индексах):

```bash
kubectl -n wazuh exec wazuh-indexer-0 -- curl -sk -u admin:$INDEXER_ADMIN_PASSWORD \
  https://localhost:9200/_cluster/health?pretty
```

- [ ] `number_of_nodes: 3`
- [ ] Heap не упирается: JVM ~16g в логах старта

## E. Wazuh Manager

- [ ] master + worker Running
- [ ] `cluster_control -l` показывает оба узла Connected
- [ ] Service NodePort/LB: 31514/31515 (или ваши)
- [ ] Бэкап конфига создан (`/var/backups/wazuh/...tgz`)

```bash
kubectl -n wazuh exec wazuh-manager-master-0 -- /var/ossec/bin/cluster_control -l
```

## F. Dashboard

- [ ] Deployment Available
- [ ] UI открывается (NodePort 31443 / Ingress)
- [ ] Логин успешен; Wazuh plugin видит API (зелёный статус)
- [ ] Индекс-паттерн `wazuh-alerts-*` существует или создаётся при первых алертах

## G. ISM / архивирование

- [ ] Snapshot repo: `GET /_snapshot/wazuh-cold-archive`
- [ ] Policy `wazuh-retention-90d` существует
- [ ] Test: `restore-archive.sh --snapshot-now` → snapshot SUCCESS
- [ ] Документирован путь NFS/S3 (≥ 3 TiB)

## H. Функциональный тест агента

- [ ] Один тестовый агент enrolled (Linux)
- [ ] Агент Active в Dashboard
- [ ] Событие появляется в Discover < 5 мин
- [ ] EPS sanity: `_nodes/stats/indexing` растёт при нагрузке

## I. Безопасность

- [ ] Пароли сменены относительно заглушек `cluster.env`
- [ ] Indexer 9200 не опубликован в agent VLAN
- [ ] TLS secrets не лежат в git
- [ ] Firewall: только 1514/1515 к Manager VIP

## J. Мониторинг (минимум)

- [ ] Алерт на Indexer disk > 75%
- [ ] Алерт на pod CrashLoopBackOff namespace `wazuh`
- [ ] Алерт на cluster health ≠ green дольше 15 мин

---

**Критерий «production ready»:** все пункты A–I отмечены; J — согласован с NOC/SecOps.
