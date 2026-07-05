# 1.EdgeGuard OTA

## 项目概述
EdgeGuard OTA是一个面向嵌入式linux设备的OTA可靠性验证平台，用于验证A/B rootfs、失败回滚、watchdog自动恢复、health check、随机掉电测试、串口日志采集和自动测试报告。 

## 项目介绍
基于 i.MX6ULL 实板设计并实现嵌入式 Linux A/B 可靠升级平台，使用 Buildroot 定制 rootfs 并集成 RAUC，将升级包写入 inactive rootfs；基于厂家 U-Boot 设计 A/B slot 启动选择与 bootargs 切换机制，结合 bootcount/bootlimit/altbootcmd 实现启动失败自动回滚；裁剪并验证 Linux Kernel 中 MMC、ext4、UART、watchdog 等关键能力，开发 health check 与 watchdog daemon，支持新版本健康确认、失败不 mark-good、系统卡死复位；开发掉电故障注入与串口日志采集工具，完成 N 轮升级中断电测试并输出可靠性报告。

## 目标用户
- 嵌入式linux/bsp工程师
- 设备厂商固件工程师
- OTA平台验证工程师
- 技术评审人员

## 真实场景下拟解决的问题
嵌入式设备在OTA升级过程中可能遇到以下问题：
- 升级中断导致无法启动系统
- 新版本rootfs启动失败但无法回滚
- 应用启动失败但系统误判升级成功
- 看门狗配置不清导致死机无法恢复
- 掉电测试不可复现，无日志，无报告
- 镜像构建过程不可复现，交付物不可追踪

EdgeGuard OTA 的目标是提供一个可验证、可复现、可演示的最小产品闭环。

# 2.快速使用
## 获取代码
```
git clone https://github.com/ppilll/EdgeGuard-OTA.git
``` 
## 关于overlay
项目关于开发板的脚本均位于[overlay](./board/edgeguard-imx6ull/overlay)下。我们建议在编译rootfs时将其添加到rootfs下。具体的添加方式参考[这里](README_detail.md)。


# 3.关于这个项目你需要知道的是
## 关于内核
该项目涉及到 Linux Kernel 中 MMC、ext4、UART、watchdog、fw_printenv以及RAUC支持部分内容。所以在使用前确保你的内核包含上述功能，项目所涉及的详细功能参考[这里](README_detail.md)。

## 关于init system
由于不同的系统使用不同的初始化系统，所以你的init程序启动方式也许略有不同。我们使用的是BusyBox的方案。初始化程序位于/etc/init.d/SXX。如果你的init程序启动不同则需要修改[etc/init.d](./board/edgeguard-imx6ull/overlay/etc/init.d/)文件夹下的初始化脚本为对应的init启动方式。资料参考[init system](https://buildroot.org/downloads/manual/manual.html#init-system)6.3节部分内容。

## 配置 U-Boot 环境
为了配合我们的脚本，你需要修改你的u-boot env,在修改前请务必确认u-boot env剩余空间大小(最好预留1500bytes)，以确保能够正常写入命令，以及确认eg_f(设备树)、eg_k(zImage)命名，以及对应的载入地址eg_ka(0x80800000)、eg_fa(0x83000000)是否有误。
```
setenv BOOT_A_LEFT=3
setenv BOOT_B_LEFT=3
setenv BOOT_ORDER=B A
setenv eg_f=edgeguard.dtb
setenv eg_fa=0x83000000
setenv eg_k=zImage
setenv eg_ka=0x80800000

setenv eg_a=run eg_l; setenv bootargs console=ttymxc0,115200 root=/dev/mmcblk0p2 rootwait rw rootfstype=ext4 rauc.slot=A; bootz ${eg_ka} - ${eg_fa}
setenv eg_b=run eg_l; setenv bootargs console=ttymxc0,115200 root=/dev/mmcblk0p3 rootwait rw rootfstype=ext4 rauc.slot=B; bootz ${eg_ka} - ${eg_fa}
setenv eg_bn=if test "${eg_next}" = "A"; then run eg_a; elif test "${eg_next}" = "B"; then run eg_b; else setenv eg_next B; saveenv; run eg_b; fi

setenv eg_l=mmc dev 0; mmc rescan; fatload mmc 0:1 ${eg_ka} ${eg_k}; fatload mmc 0:1 ${eg_fa} ${eg_f}

setenv eg_rauc_init=if test -z "${BOOT_ORDER}"; then setenv BOOT_ORDER B A; fi; if test -z "${BOOT_A_LEFT}"; then setenv BOOT_A_LEFT 3; fi; if test -z "${BOOT_B_LEFT}"; then setenv BOOT_B_LEFT 3; fi

setenv eg_rauc_rescue=echo RAUC no bootable slot left, rescue to B; setenv BOOT_ORDER B A; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3; saveenv; setenv eg_next B; run eg_bn

setenv eg_rauc_try_a=if test "${BOOT_A_LEFT}" -gt 0; then echo RAUC try slot A, left=${BOOT_A_LEFT}; setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1; saveenv; setenv eg_next A; run eg_bn; fi

setenv eg_rauc_try_b=if test "${BOOT_B_LEFT}" -gt 0; then echo RAUC try slot B, left=${BOOT_B_LEFT}; setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1; saveenv; setenv eg_next B; run eg_bn; fi

setenv eg_rauc_boot=run eg_rauc_init; echo BOOT_ORDER=${BOOT_ORDER}; echo BOOT_A_LEFT=${BOOT_A_LEFT}; echo BOOT_B_LEFT=${BOOT_B_LEFT}; if test "${BOOT_ORDER}" = "A B"; then run eg_rauc_try_a; run eg_rauc_try_b; else run eg_rauc_try_b; run eg_rauc_try_a; fi; run eg_rauc_rescue

setenv bootcmd=run eg_rauc_boot
saveenv
```
## 关于RUAC
RAUC 可以接收一个经过签名的 update bundle，验证它确实属于当前设备型号，验证其完整性和签名可信，然后把其中的 rootfs payload 写入当前未运行的 rootfs 分区。更多的细节[在这里](README_detail.md)。

## 烧入SD卡
本项目同时提供了一个脚本用于烧入u-boot,zImage,dtb,rootfs到SD卡的脚本文件。
更多的细节[在这里](README_detail.md)。

# 4.核心流程

## 正常 OTA
```
A running
→ RAUC install to B
→ RAUC activates B through U-Boot backend
→ BOOT_ORDER updated
→ reboot
→ B boot
→ health PASS
→ rauc status mark-good booted
```

## 失败回滚
```bad B boot
→ BOOT_B_LEFT consumed
→ BOOT_B_LEFT=0
→ U-Boot fallback
→ A boot
→ A remains good
health + watchdog
new slot boot
→ health check
→ pass: mark-good
→ fail/hang: watchdog reset
→ U-Boot consumes boot attempt
→ fallback if attempts exhausted
```
## 随机掉电测试
```baseline probe
→ ensure bundle staged on /data
→ trigger OTA
→ random power cut
→ power restore
→ serial log
→ probe status
→ judge result
→ save JSON/CSV/Markdown report
```