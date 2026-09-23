# Разметка дисков (LVM) по ролям ВМ

Целевые ОС: **РЕД ОС 8**, **Astra Linux**, Ubuntu 22.04. Разметка дисков одинаковая. Swap: **отключён** на всех K8s-нодах (`SWAP_ENABLED=false`) — требование Kubernetes; для OpenSearch swap вреден (latency).

## Общие правила

| Параметр | Значение |
|----------|----------|
| LVM | Да (удобное расширение) |
| FS для OS | ext4 |
| FS для containerd | ext4 или xfs |
| FS для Indexer data | **XFS** + `noatime,nodiratime` |
| Mount Indexer доп. | опционально `inode64`, не использовать `discard` на thick Eager Zeroed без необходимости |
| `vm.max_map_count` | **262144** (ставит lib.sh) |

---

## 1. K8s Control-Plane

| Диск vSphere | Размер | Provisioning | LVM | Mount |
|--------------|--------|--------------|-----|-------|
| `sda` | 100 GiB | Thin | стандартный root ОС (РЕД ОС / Astra / Ubuntu) | `/` |
| `sdb` | 100 GiB | Thick Lazy | VG `vg_container` LV `lv_containerd` | `/var/lib/containerd` |
| `sdc` (опц.) | 50 GiB | Thin | VG `vg_logs` LV `lv_logs` | `/var/log` |

```
/
├── var/lib/containerd   ← sdb LVM
└── var/log              ← optional
```

Swap: отсутствует.

---

## 2. K8s Worker

| Диск | Размер | Provisioning | Mount |
|------|--------|--------------|-------|
| `sda` | 100 GiB | Thin | `/` |
| `sdb` | **200 GiB** | Thick Lazy | `/var/lib/containerd` |
| optional logs | 50 GiB | Thin | `/var/log` |

Manager PVC могут жить на отдельном CSI; images/containerd требуют запас из-за слоёв Wazuh images.

---

## 3. Wazuh Indexer Node

| Диск | Размер | Provisioning | FS | Mount |
|------|--------|--------------|----|-------|
| `sda` | 100 GiB | Thin | ext4 | `/` |
| `sdb` | 100 GiB | Thick Lazy | ext4/xfs | `/var/lib/containerd` |
| **`sdc`** | **2 TiB** | **Thick Eager Zeroed** | **XFS** | **`/var/lib/wazuh-indexer`** |
| optional | 50 GiB | Thin | ext4 | `/var/log` |

```bash
# Пример fstab (UUID подставит скрипт)
UUID=... /var/lib/wazuh-indexer xfs noatime,nodiratime,defaults 0 2
```

Права после монтирования (uid OpenSearch в контейнере часто 1000):

```bash
chown -R 1000:1000 /var/lib/wazuh-indexer
chmod 750 /var/lib/wazuh-indexer
```

### Почему XFS + noatime

- XFS лучше ведёт себя на больших файловых объёмах и параллельных allocation OpenSearch.
- `noatime` снижает write amplification от чтения сегментов.

### Почему Eager Zeroed Thick

- Предсказуемый latency (нет runtime zeroing).
- Избегаем «тонкого» overcommit, опасного при одновременном росте 3 индексеров.

---

## 4. Логи и journald

Рекомендуется ограничить journal:

```bash
# /etc/systemd/journald.conf
SystemMaxUse=2G
```

Не храните Indexer data и OS logs на одном spindles/LUN без QoS.

---

## 5. Расширение LVM (runbook)

```bash
# После увеличения VMDK в vSphere
echo 1 > /sys/class/block/sdc/device/rescan   # или helper esx
pvresize /dev/sdc
lvextend -l +100%FREE /dev/vg_indexer/lv_data
xfs_growfs /var/lib/wazuh-indexer
```

Скрипты установки идемпотентны: повторный запуск не пересоздаёт смонтированный LV.
