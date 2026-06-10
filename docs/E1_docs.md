# 构建rootfs

export PROJECT=$HOME/桌面/project/EdgeGuard_OTA
export BR=$PROJECT/external/buildroot
export OUT=$PROJECT/output/edgeguard-imx6ull
export OVERLAY=$PROJECT/board/edgeguard-imx6ull/overlay
export BR2_DL_DIR=$HOME/buildroot-dl

cd "$BR2_DL_DIR"
wget -c https://mirrors.tuna.tsinghua.edu.cn/gnu/gcc/gcc-9.3.0/gcc-9.3.0.tar.xz

cd "$BR"
make O="$OUT" source

cd "$PROJECT"
BR2_DL_DIR="$HOME/buildroot-dl" ./scripts/build_rootfs_only.sh

# 烧入SD卡
本项目同时提供了一个脚本用于烧入u-boot,zImage,dtb,rootfs到SD卡的脚本文件
完整脚本[在这里](../scripts/make_sdcard_vendor_boot.sh)。

快速使用
```
chmod +x (scripts/make_sdcard_vendor_boot.sh)
sudo scripts/make_sdcard_vendor_boot.sh /dev/sdb \
  path/to/u-boot-dtb.imx \
  path/to/zImage \
  path/to/edgeguard.dtb
```
其中：
- path/to/u-boot.imx为需要烧入的u-boot.imx相对地址。
- path/to/zImage为需要烧入的zImage相对地址。
- path/to/edgeguard.dtb为需要烧入的dtb相对地址。

额外注意：
- 烧入前需要确认SD卡设备，类似于/dev/sdb而非/dev/sdb1分区。建议烧入前完全格式化SD卡，即使该脚本在烧入前会擦除SD卡。
- 同时注意需要确认u-boot.imx不超过1M(参考[NXP建议](https://community.nxp.com/t5/i-MX-Processors-Knowledge-Base/u-boot-on-the-i-MX6-sabre-sd-platform-in-a-few-commands/ta-p/1114268?utm_source=chatgpt.com&profile.language=zh-CN)u-boot.imx 应放在 SD 卡 1024KB 偏移处)。

烧入后的预期结构类似于
```
SD card: /dev/sdb

前部原始区域：
  0x00000000 附近：MBR 分区表
  0x00000400，即 1KiB 偏移：u-boot-dtb.imx raw image

分区 1：/dev/sdb1，FAT32，label=BOOT
  /zImage
  /edgeguard.dtb

分区 2：/dev/sdb2，ext4，label=rootfs
  /bin
  /etc
  /lib
  /sbin
  /usr
  /var
  ...
```
可以使用`lsblk -f /dev/sdb`检查预期内容是否正确。

# boot启动内核
```
fatload mmc 0:1 0x80800000 zImage
fatload mmc 0:1 0x83000000 edgeguard.dtb
setenv bootargs 'console=ttymxc0,115200 root=/dev/mmcblk0p2 rootwait rw rootfstype=ext4'
bootz 0x80800000 - 0x83000000
```
