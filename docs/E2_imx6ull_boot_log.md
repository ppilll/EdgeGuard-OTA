# 使用U-Boot 验证 A 槽
```
mmc dev 0
mmc rescan
fatls mmc 0:1
ext4ls mmc 0:2 /
fatload mmc 0:1 0x80800000 zImage
fatload mmc 0:1 0x83000000 edgeguard.dtb
setenv bootargs 'console=ttymxc0,115200 root=/dev/mmcblk0p2 rootwait rw rootfstype=ext4'
bootz 0x80800000 - 0x83000000
```

## 固化log如下：
```
Starting network: OK

Welcome to EdgeGuard OTA E1
Embedfire_imx6ull login: root
Password:
# cat /etc/edgeguard_slot
SLOT=A
# cat /etc/edgeguard_version
EDGEGUARD_VERSION=0.1.0-e1
BUILD_STAGE=E1
BUILD_TARGET=imx6ull
BOARD_NAME=EBF6ULL-S1-PRO
BOARD_VENDOR=Embedfire
BOOT_MEDIA=sdcard
ROOTFS_SOURCE=buildroot-2021.02.3
UBOOT_SOURCE=vendor
KERNEL_SOURCE=vendor
DTB_SOURCE=vendor
# cat /proc/cmdline
console=ttymxc0,115200 root=/dev/mmcblk0p2 rootwait rw rootfstype=ext4
# findmnt /
-sh: findmnt: not found
# mount
/dev/root on / type ext4 (rw,relatime)
devtmpfs on /dev type devtmpfs (rw,relatime,size=83032k,nr_inodes=20758,mode=755)
proc on /proc type proc (rw,relatime)
devpts on /dev/pts type devpts (rw,relatime,gid=5,mode=620,ptmxmode=666)
tmpfs on /dev/shm type tmpfs (rw,relatime,mode=777)
tmpfs on /tmp type tmpfs (rw,relatime)
tmpfs on /run type tmpfs (rw,nosuid,nodev,relatime,mode=755)
sysfs on /sys type sysfs (rw,relatime)
# df -h
Filesystem                Size      Used Available Use% Mounted on
/dev/root               487.9M      2.4M    449.8M   1% /
devtmpfs                 81.1M         0     81.1M   0% /dev
tmpfs                   241.6M         0    241.6M   0% /dev/shm
tmpfs                   241.6M     40.0K    241.5M   0% /tmp
tmpfs                   241.6M     20.0K    241.6M   0% /run
# blkid[   64.488371] cfg80211: failed to load regulatory.db
[  209.927935] random: crng init done

/dev/mmcblk1p2: LABEL="rootfs" UUID="c31e23ad-6d74-4946-a204-257af3e278be"
/dev/mmcblk1p1: LABEL="BOOT" UUID="02E0-2273"
/dev/mmcblk0p4: LABEL="data" UUID="2532f577-3c43-4dbd-9103-5a37faecce95"
/dev/mmcblk0p3: LABEL="rootfs_B" UUID="96a90ade-ab06-48ec-9260-89ca2fb7df06"
/dev/mmcblk0p2: LABEL="rootfs_A" UUID="1bfa89e9-8ac3-4879-b006-ce0aa5acb0a0"
/dev/mmcblk0p1: LABEL="BOOT" UUID="31D7-7DC4"
```

# 使用U-Boot 验证 B 槽
```
mmc dev 0
mmc rescan
fatls mmc 0:1
ext4ls mmc 0:3 /
fatload mmc 0:1 0x80800000 zImage
fatload mmc 0:1 0x83000000 edgeguard.dtb
setenv bootargs 'console=ttymxc0,115200 root=/dev/mmcblk0p3 rootwait rw rootfstype=ext4'
bootz 0x80800000 - 0x83000000
```

## 固化log如下：
```
Starting network: OK

Welcome to EdgeGuard OTA E1
Embedfire_imx6ull login: root
Password:
# cat /etc/edgeguard_slot
SLOT=B
# cat /etc/edgeguard_version
EDGEGUARD_VERSION=0.1.0-e1
BUILD_STAGE=E1
BUILD_TARGET=imx6ull
BOARD_NAME=EBF6ULL-S1-PRO
BOARD_VENDOR=Embedfire
BOOT_MEDIA=sdcard
ROOTFS_SOURCE=buildroot-2021.02.3
UBOOT_SOURCE=vendor
KERNEL_SOURCE=vendor
DTB_SOURCE=vendor
# cat /proc/cmdline
console=ttymxc0,115200 root=/dev/mmcblk0p3 rootwait rw rootfstype=ext4
# findmnt /
-sh: findmnt: not found
# [   64.488051] cfg80211: failed to load regulatory.db

# mount
/dev/root on / type ext4 (rw,relatime)
devtmpfs on /dev type devtmpfs (rw,relatime,size=83032k,nr_inodes=20758,mode=755)
proc on /proc type proc (rw,relatime)
devpts on /dev/pts type devpts (rw,relatime,gid=5,mode=620,ptmxmode=666)
tmpfs on /dev/shm type tmpfs (rw,relatime,mode=777)
tmpfs on /tmp type tmpfs (rw,relatime)
tmpfs on /run type tmpfs (rw,nosuid,nodev,relatime,mode=755)
sysfs on /sys type sysfs (rw,relatime)
# df -h
Filesystem                Size      Used Available Use% Mounted on
/dev/root               487.9M      2.4M    449.8M   1% /
devtmpfs                 81.1M         0     81.1M   0% /dev
tmpfs                   241.6M         0    241.6M   0% /dev/shm
tmpfs                   241.6M     44.0K    241.5M   0% /tmp
tmpfs                   241.6M     20.0K    241.6M   0% /run
# blkid
/dev/mmcblk1p2: LABEL="rootfs" UUID="c31e23ad-6d74-4946-a204-257af3e278be"
/dev/mmcblk1p1: LABEL="BOOT" UUID="02E0-2273"
/dev/mmcblk0p4: LABEL="data" UUID="2532f577-3c43-4dbd-9103-5a37faecce95"
/dev/mmcblk0p3: LABEL="rootfs_B" UUID="96a90ade-ab06-48ec-9260-89ca2fb7df06"
/dev/mmcblk0p2: LABEL="rootfs_A" UUID="1bfa89e9-8ac3-4879-b006-ce0aa5acb0a0"
/dev/mmcblk0p1: LABEL="BOOT" UUID="31D7-7DC4"
```