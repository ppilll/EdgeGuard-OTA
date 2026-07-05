# 关于内核
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
| Watchdog sysfs | `/sys/class/watchdog/watchdog0` | class symlink exists, detail files missing | inventory only | WARN | Not blocking manual test
# rootfs编译
```
cd /home/liu/work/EdgeGuard_OTA

make -C external/buildroot \
  O=/home/liu/work/EdgeGuard_OTA/output/edgeguard-imx6ull \
  BR2_DEFCONFIG=/home/liu/work/EdgeGuard_OTA/configs/buildroot_defconfig \
  defconfig

rm -f output/edgeguard-imx6ull/images/rootfs.tar

make -C external/buildroot \
  O=/home/liu/work/EdgeGuard_OTA/output/edgeguard-imx6ull

ls -lh output/edgeguard-imx6ull/images/rootfs.tar
```
## 额外注意
Buildroot 的 rootfs overlay 机制会把 overlay 目录树复制到目标 rootfs 里。Buildroot 文档也把 root filesystem overlay 和 post-build script 列为推荐的 rootfs 定制方法，overlay 对应的配置项就是 BR2_ROOTFS_OVERLAY。你可用参考[这里](https://fossies.org/linux/buildroot/docs/manual/customize-rootfs.adoc?utm_source=chatgpt.com)。
我们的设置如下
`BR2_ROOTFS_OVERLAY="/home/liu/work/EdgeGuard_OTA/board/edgeguard-imx6ull/overlay"`
# 安全证书、公钥与密钥
RAUC 在OTA升级时需要验证 bundle 的签名证书链。证书不可信、证书未生效、证书过期、bundle 被篡改、checksum 不匹配，都会导致验证失败。所以我们在主机端需要先构建对应的密钥公钥内容。
生成证书
```
openssl genrsa \
  -out "$PROJECT/certs/private/ca.key.pem" \
  4096

openssl req \
  -x509 \
  -new \
  -nodes \
  -key "$PROJECT/certs/private/ca.key.pem" \
  -sha256 \
  -days 3650 \
  -subj "/CN=EdgeGuard E3 Development CA/" \
  -out "$PROJECT/certs/ca.cert.pem"

openssl genrsa \
  -out "$PROJECT/certs/private/dev.key.pem" \
  4096

openssl req \
  -new \
  -key "$PROJECT/certs/private/dev.key.pem" \
  -subj "/CN=EdgeGuard E3 Bundle Signer/" \
  -out "$PROJECT/certs/private/dev.csr.pem"

openssl x509 \
  -req \
  -in "$PROJECT/certs/private/dev.csr.pem" \
  -CA "$PROJECT/certs/ca.cert.pem" \
  -CAkey "$PROJECT/certs/private/ca.key.pem" \
  -CAcreateserial \
  -out "$PROJECT/certs/dev.cert.pem" \
  -days 825 \
  -sha256
```
- 根 CA 私钥 ca.key.pem
- 根 CA 证书 ca.cert.pem
- Bundle 签名私钥 dev.key.pem 
- 生成 证书签名请求 CSR dev.csr.pem
- CA 签发 Bundle signer 证书 dev.cert.pem

把公钥放证书放入rootfs overlay

# 生成bundle
```
INPUT=bundles/input-e5-watchdog-keeper-0.5.2
OUTPUT=bundles/output/edgeguard-0.5.2-e5-watchdog-keeper.raucb
mkdir -p "$INPUT"

cp -a output/edgeguard-imx6ull/images/rootfs.tar \
  "$INPUT"

cat > bundles/input-e5-watchdog-keeper-0.5.2/manifest.raucm <<'EOF'
[update]
compatible=edgeguard-imx6ull
version=0.5.2-e5-watchdog-keeper
description=EdgeGuard E5 watchdog-keeper.

[image.rootfs]
filename=rootfs.tar
EOF

RAUC=output/edgeguard-imx6ull/host/bin/rauc
CERT=./certs/dev.cert.pem
KEY=./certs/private/dev.key.pem
KEYRING=./certs/ca.cert.pem

rm -f "$OUTPUT"

"$RAUC" bundle \
  --cert="$CERT" \
  --key="$KEY" \
  --keyring="$KEYRING" \
  "$INPUT" "$OUTPUT"

"$RAUC" --keyring="$KEYRING" info "$OUTPUT"

sha256sum "$OUTPUT"
```
# 烧入SD卡(单独烧入rootfs到SD卡/data下)
```
SD_DATA=/dev/sdb4

sudo mkdir -p /tmp/edgeguard-data
sudo mount "$SD_DATA" /tmp/edgeguard-data
sudo mkdir -p /tmp/edgeguard-data/bundles

sudo cp -a "$OUTPUT" \
  /tmp/edgeguard-data/bundles/

sync

sha256sum "$OUTPUT"

sudo umount /tmp/edgeguard-data
```
sudo mkdir -p /tmp/edgeguard-data/trim
sudo cp -a vendor/e5-kernel-trim-round1/zImage \
  /tmp/edgeguard-data/trim
sudo cp -a vendor/e5-kernel-trim-round1/u-boot-dtb.imx \
  /tmp/edgeguard-data/trim 

# 开发板上安装

```
date -u -s "2026-06-24 05:00:00"
edgeguard-ota-install /data/bundles/edgeguard-0.5.2-e5-watchdog-keeper.raucb

cat /etc/edgeguard_version
cat /etc/rauc/system.conf
cat /proc/cmdline
rauc status --detailed
```

# 烧入SD卡
本项目同时提供了一个脚本用于烧入u-boot,zImage,dtb,rootfs_A,rootfs_B到SD卡的脚本文件
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
- ROOTFS_A_TAR为rootfs_A。修改脚本对应内容。
- ROOTFS_A_TAR为rootfs_B。修改脚本对应内容。

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
关于烧入SD卡的内存布局，你可以在脚本`# Partition geometry, in 512-byte sectors.`处调整。

# fw_printenv
我们的脚本使用了fw_pintenv功能用于在linux态向u-boot env写入内容，所以请确保你的内核具备这个功能。同时注意u-boot env的起始地址以及大小。参考我们的[fw_env.config](../board/edgeguard-imx6ull/overlay/etc/fw_env.config).