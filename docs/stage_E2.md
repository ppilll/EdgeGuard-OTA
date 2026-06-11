#  E2 - A/B 分区设计
## 1. 目标 
在 野火 EBF6ULL S1 PRO / i.MX6ULL 实板 SD 卡 上，把 E1 的单 rootfs 改造成：
```
p1 boot
p2 rootfs_A
p3 rootfs_B
p4 data
```
并通过 U-Boot 临时 bootargs 或手动 fatload + bootz 分别启动 rootfs_A 和 rootfs_B

# 2. 建议32GB SD布局

| Partition | Name     | Size        | FS    | Purpose |
|---|---:|---:|---|---|
| raw area | U-Boot | starts at 1KiB | raw | vendor u-boot-dtb.imx |
| p1 | boot | 128MiB | FAT32 | zImage + dtb |
| p2 | rootfs_A | 512MiB | ext4 | active slot A candidate |
| p3 | rootfs_B | 512MiB | ext4 | inactive / alternate slot B |
| p4 | data | remaining | ext4 | persistent data, E2 only creates and verifies |

## 3. Notes

- p1 starts at 8MiB to avoid overwriting the vendor U-Boot raw area.
- E2 uses the same rootfs.tar for A and B.
- Slot identity is written after extraction:
  - rootfs_A: /etc/edgeguard_slot = SLOT=A
  - rootfs_B: /etc/edgeguard_slot = SLOT=B
- If rootfs grows, increase rootfs_A/rootfs_B to 1GiB each.

## 4. E2阶段完成清单
```
[√] E1 SD 卡整卡镜像已备份
[√] E1 SD 卡备份 SHA256 已保存
[√] E1 原始分区表已保存
[√] E1 /proc/cmdline 已保存
[√] E1 findmnt / 已保存
[√] E1 blkid 已保存
[√] U-Boot 原始 printenv 已保存
[√] bootcmd/mmcargs/mmcroot/bootargs 已分析
[√] A/B SD 卡分区已创建
[√] p1 boot 为 FAT32
[√] p2 rootfs_A 为 ext4
[√] p3 rootfs_B 为 ext4
[√] p4 data 为 ext4
[√] vendor U-Boot raw 写入方式未随意改变
[√] zImage 已复制到 boot 分区
[√] dtb 已复制到 boot 分区
[√] rootfs.tar 已解包到 rootfs_A
[√] rootfs.tar 已解包到 rootfs_B
[√] rootfs_A /etc/edgeguard_slot 输出 SLOT=A
[√] rootfs_B /etc/edgeguard_slot 输出 SLOT=B
[√] U-Boot 能手动启动 rootfs_A
[√] U-Boot 能手动启动 rootfs_B
[√] A 槽 Linux 用户态验证完成
[√] B 槽 Linux 用户态验证完成
[√] A 槽串口日志已保存
[√] B 槽串口日志已保存
[√] E2 报告已填写
[√] Git commit 已提交
```

## 5. 