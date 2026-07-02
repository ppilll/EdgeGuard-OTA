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


| Capability | Required by | Trim result | Runtime evidence | Status |
|---|---|---|---|---|
| MMC / SD host | SD boot, A/B rootfs, data | kept | `/dev/mmcblk0p2`, `/dev/mmcblk0p3`, `/dev/mmcblk0p4` | PASS |
| EXT4 | rootfs/data | kept | `findmnt /`, `findmnt /data` | PASS |
| UART console | serial debug/log capture | kept | `console=ttymxc0,115200`, serial boot logs | PASS |
| Watchdog core | E5-W reset path | kept | `/dev/watchdog`, `/dev/watchdog0`, `imx2-wdt` | PASS |
| procfs | slot detection | kept | `/proc/cmdline` with `rauc.slot=A/B` | PASS |
| sysfs | device visibility | kept | `/sys` available | PASS |
| devtmpfs | device nodes | kept | `/dev/mmcblk*`, `/dev/watchdog*` | PASS |
| RAUC bundle mount support | RAUC install | kept | loop/SquashFS/dm-verity config checked | PASS |
| SOUND/audio | not used in EdgeGuard E5 | removed | no E5 regression | PASS |
| V4L2/multimedia/camera | not used in EdgeGuard E5 | removed | no E5 regression | PASS |
| Bluetooth | not used in EdgeGuard E5 | removed | no E5 regression | PASS |
| Wi-Fi/WLAN | not used in EdgeGuard E5 | removed | no E5 regression | PASS |
| Display/GPU | not used in serial-first E5 | removed | serial console still works | PASS |
| INPUT/EVDEV/KEYBOARD/TOUCHSCREEN | not used in serial-first E5 | removed | serial login and scripts work | PASS |
| unused NET/PHY drivers | not used in current SD/serial workflow | removed | RAUC local install and E5 tests pass | PASS |

Note:
Network/PHY removal is accepted only for the current E5 workflow because OTA bundle transfer and validation do not depend on target Ethernet/Wi-Fi. If later E6/E7 introduces network-based bundle delivery, SSH log collection, remote orchestration, or multi-device test control, network/PHY must be re-evaluated.

## Evidence files

- 当前运行内核：Linux 4.19.35+，ARMv7 32-bit，SMP 配置，可抢占内核，构建于 2026-06-13。

- 启动链路：串口 console 为 ttymxc0@115200，rootfs 从 /dev/mmcblk0p2 启动，rootfs 类型 ext4，启动时读写挂载，RAUC 当前 slot 为 A。

- 文件系统：ext2/ext3/ext4、squashfs、vfat、NFS/NFSv4、JFFS2、UBIFS、FUSE，以及 proc/sysfs/tmpfs/devtmpfs/cgroup/cgroup2/debugfs/tracefs/securityfs/configfs 等虚拟文件系统已支持或已加载。

- 存储：两个 MMC host 正常工作。mmc0 是 29.7 GiB SDHC 卡，4 个分区；mmc1 是 7.28 GiB eMMC，2 个普通分区，并有 boot0、boot1、RPMB。当前系统从 SD 卡的 mmcblk0p2 和 mmcblk0p4 运行，而不是从 eMMC 用户区运行。

- watchdog：i.MX watchdog 驱动 imx2-wdt 已加载，超时 60 秒，暴露 /dev/watchdog 和 /dev/watchdog0，nowayout=0。

- SoC 外设：i.MX pinctrl、SNVS pinctrl、SDMA、RNG、thermal、I2C、SPI、WEIM、USB controller、USB serial、Bluetooth HCI UART、UART console 等相关驱动已经注册或 probe。

- 挂载状态：/ 是 /dev/mmcblk0p2 ext4 rw,relatime；/data 是 /dev/mmcblk0p4 ext4 rw,noatime。

第一个保守型裁剪内核移除了以下未使用的子系统：

- 音频 / 音效  
- V4L2 / 多媒体 / 摄像头  
- 蓝牙  
- Wi-Fi / WLAN  
- 显示器 / GPU  
- 输入 / EVDEV / 键盘 / 触摸屏  
- 未使用的网络 / 物理层驱动程序
启动时间从3.4秒提升到2.9秒，大约提高了15%。

所有E5功能均无异常行为，已成功复现：
- A/B rootfs 启动
- RAUC 状态
- U-Boot 的 `BOOT_ORDER`、`BOOT_A_LEFT`、`BOOT_B_LEFT`
- 健康检查通过并标记为良好
- 健康失败但未提前标记为良好
- 时钟看门狗喂料正常
- 时钟看门狗无喂料重置
- 时钟看门狗守护程序
- 健康失败 + 时钟看门狗重置 + 跳转到备用方案
- `/data` 挂载并写入
- 串行控制台/日志收集
- MMC/Ext4/UART/时钟看门狗/procfs/sysfs/devtmpfs 运行时证据
决定：
此修剪后的内核将作为E5版本内核的基准线。
在E5中不会进行进一步的激进修剪。
如有需要，后续修剪将推迟至E6可靠性测试之后进行。

PASS.

## Scope

E5 covers:

- health check
- RAUC mark-good policy
- watchdog manual validation
- watchdog keeper integration
- health fail + watchdog reset + U-Boot fallback
- kernel capability inventory
- conservative kernel trimming

Out of scope:

- random power-cut relay testing
- cloud OTA
- web UI
- multi-device management
- differential update
- secure boot
- aggressive kernel minimization

## Final Architecture

```text
new slot boot
→ U-Boot passes rauc.slot=A/B
→ Linux mounts rootfs
→ S98edgeguard-watchdog starts keeper
→ S99edgeguard-health runs health check
→ PASS: mark-good + watchdog feed continues
→ FAIL: do not mark-good + watchdog reset
→ U-Boot consumes BOOT_<slot>_LEFT
→ fallback to old good slot after retries are exhausted