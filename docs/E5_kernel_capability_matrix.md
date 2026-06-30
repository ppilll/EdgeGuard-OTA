# E5 Kernel Capability Matrix

## 范围

本文件记录了OTA关键内核功能的运行时证据。  
不要仅因配置选项显示为启用而将某个功能标记为通过（PASS）。  
每个通过（PASS）都必须来自目标板的运行时证据。

## 目标

| Item | Value |
|---|---|
| Board | i.MX6ULL board |
| Boot media | SD card |
| Rootfs A | /dev/mmcblk0p2 |
| Rootfs B | /dev/mmcblk0p3 |
| Data | /dev/mmcblk0p4 |
| OTA backend | RAUC + U-Boot BOOT_ORDER / BOOT_A_LEFT / BOOT_B_LEFT |

## Matrix

| 功能 | 内核配置 | 运行时证据 | 由谁需求 | 状态 | 备注 |
|---|---|---|---|---|---|
| MMC host/controller | CONFIG_MMC, SoC MMC host driver | `/dev/mmcblk0*`, dmesg mmc lines | SD boot, rootfs A/B, data | TBD |  |
| MMC block | CONFIG_MMC_BLOCK | `/dev/mmcblk0p2`, `/dev/mmcblk0p3`, `/dev/mmcblk0p4` | rootfs/data access | TBD |  |
| EXT4 | CONFIG_EXT4_FS | `findmnt /`, `findmnt /data`, `/proc/filesystems` | rootfs/data mount | TBD |  |
| UART console | SoC UART + serial console | serial boot log, dmesg serial lines | debug/log capture | TBD |  |
| Watchdog | CONFIG_WATCHDOG + i.MX watchdog driver | `/dev/watchdog*`, `/sys/class/watchdog`, dmesg | E5 reset path later | TBD | Inventory only in this round |
| procfs | CONFIG_PROC_FS | `/proc/cmdline` | slot detection | TBD |  |
| sysfs | CONFIG_SYSFS | `/sys` exists, watchdog/mmc sysfs | device visibility | TBD |  |
| devtmpfs | CONFIG_DEVTMPFS | `/dev/mmcblk0*`, `/dev/watchdog*` | device nodes | TBD |  |
| RAUC bundle mount support | loop, squashfs, dm-verity if verity bundle is used | `rauc install/status`, kernel config | RAUC operation | TBD | RAUC docs require loop and SquashFS, and dm-verity for verity bundles |
| U-Boot env access | fw_env userspace support + storage driver | `fw_printenv BOOT_ORDER` | mark-good/fallback | TBD |  |
| Watchdog core | Linux watchdog framework | `/dev/watchdog`, `/dev/watchdog0` | E5-W reset path | PASS | sysfs detail attributes missing |
| i.MX watchdog | `imx2-wdt` | `dmesg: timeout 60 sec (nowayout=0)` | E5-W reset path | PASS | Use dmesg as timeout evidence |
| Watchdog sysfs | `/sys/class/watchdog/watchdog0` | class symlink exists, detail files missing | inventory only | WARN | Not blocking manual test |

## Evidence files

- 当前运行内核：Linux 4.19.35+，ARMv7 32-bit，SMP 配置，可抢占内核，构建于 2026-06-13。

- 启动链路：串口 console 为 ttymxc0@115200，rootfs 从 /dev/mmcblk0p2 启动，rootfs 类型 ext4，启动时读写挂载，RAUC 当前 slot 为 A。

- 文件系统：ext2/ext3/ext4、squashfs、vfat、NFS/NFSv4、JFFS2、UBIFS、FUSE，以及 proc/sysfs/tmpfs/devtmpfs/cgroup/cgroup2/debugfs/tracefs/securityfs/configfs 等虚拟文件系统已支持或已加载。

- 存储：两个 MMC host 正常工作。mmc0 是 29.7 GiB SDHC 卡，4 个分区；mmc1 是 7.28 GiB eMMC，2 个普通分区，并有 boot0、boot1、RPMB。当前系统从 SD 卡的 mmcblk0p2 和 mmcblk0p4 运行，而不是从 eMMC 用户区运行。

- watchdog：i.MX watchdog 驱动 imx2-wdt 已加载，超时 60 秒，暴露 /dev/watchdog 和 /dev/watchdog0，nowayout=0。

- SoC 外设：i.MX pinctrl、SNVS pinctrl、SDMA、RNG、thermal、I2C、SPI、WEIM、USB controller、USB serial、Bluetooth HCI UART、UART console 等相关驱动已经注册或 probe。

- 挂载状态：/ 是 /dev/mmcblk0p2 ext4 rw,relatime；/data 是 /dev/mmcblk0p4 ext4 rw,noatime。