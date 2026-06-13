# E3 Normal OTA Report

## 1. 结论

- Result: PASS / FAIL
- Test direction: rootfs_A -> rootfs_B / rootfs_B -> rootfs_A
- Bundle: edgeguard-update-v0.2-to-v0.3.raucb
- Payload: rootfs.tar / rootfs.ext4 fallback
- Bundle format: plain
- Slot switch method: manual U-Boot command from E2

## 2. 测试环境

- Board: 野火 / Embedfire EBF6ULL S1 PRO
- CPU: NXP i.MX6ULL
- RAM: 512MB DDR3
- Boot media: SD card
- Serial: /dev/ttyUSB0, 115200
- Target console: /dev/ttymxc0
- Buildroot: 2021.02.3
- Kernel/U-Boot/DTB: vendor BSP
- DTB name in boot partition: edgeguard.dtb
- Kernel name in boot partition: zImage

## 3. E1/E2 基线

- E1: vendor BSP + Buildroot rootfs 启动验证完成
- E2: A/B rootfs 手动启动完成
- A slot boot command verified: yes / no
- B slot boot command verified: yes / no

## 4. 分区布局
```
lsblk
blkid
cat /proc/cmdline
findmnt /
findmnt /data
```

## 5. 升级前状态
cat /etc/edgeguard_version
cat /etc/edgeguard_slot
cat /proc/cmdline
findmnt /
mount
df -h
blkid
rauc status
rauc status --detailed