# E1 构建rootfs
## `scripts/e1_patch_buildroot_config.sh`
目的：
为仅用于E1 rootfs的启动，修改生成的Buildroot `.config`文件。
它强制执行：
--- 禁用 Buildroot Linux Linux 内核构建  
--- 禁用 Buildroot U-BootBoot 构建  
-- 将串口 getty 设置为 `ttymxc0`  
- 设置系统主机名和横幅  
- 设置 rootfsfsfs 嵌套路径  
-- 启用 `rootfs.tar`  
-- 启用 ext 文件系统镜像
该脚本的引入是因为 E1 使用了厂商 U-Boot/内核/dtb，而 Buildroot 仅用于根文件系统生成。
### `scripts/build_rootfs_only.sh`
目的：
根据固定的项目配置重建 E1 根文件系统。
它确实：
- 加载 `configs/buildroot_defconfig`
- 使用非树状 Buildroot 输出目录
- 使用共享的 Buildroot 下载缓存 `BR2_DL_DIR`
-- 运行 Buildroot 的 make
-- 将构建日志保存到 `reports/logs/`
-- 打印生成的镜像
-- 验证 `/etc/edgeguard_version`
## 快速使用 
```
export PROJECT=$HOME/桌面/project/EdgeGuard_OTA  
export BR=$PROJECT/external/buildroot  
export OUT=$PROJECT/output/edgeguard-imx6ull  
export BR2_DL_DIR=$HOME/buildroot-dl
cd "$BR"
make O="$OUT" imx6ullevk_defconfig
cd "$PROJECT"
./scripts/e1_patch_buildroot_config.sh
cd "$BR"
make O="$OUT" olddefconfig
make O="$OUT" savedefconfig
cp "$OUT/defconfig" "$PROJECT/configs/buildroot_defconfig"
cd "$PROJECT"
./scripts/build_rootfs_only.sh

```

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
# rootfs构建中的问题
在rootfs构建时，可能遇到从源码网站下载过慢的问题，建议先使用make source和清华镜像源下载源码

再使用./scripts/build_rootfs_only.sh构建rootfs

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