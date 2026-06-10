# E1阶段固化日志

启动内核无异常
```

Welcome to EdgeGuard OTA E1
Embedfire_imx6ull login: root
Password:
# [   64.488341] cfg80211: failed to load regulatory.db
[  209.927884] random: crng init done

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
# mount
uname -a
df -h
cat /etc/inittab | grep ttymxc0 || true/dev/root on / type ext4 (rw,relatime)
devtmpfs on /dev type devtmpfs (rw,relatime,size=83032k,nr_inodes=20758,mode=755)
proc on /proc type proc (rw,relatime)
devpts on /dev/pts type devpts (rw,relatime,gid=5,mode=620,ptmxmode=666)
tmpfs on /dev/shm type tmpfs (rw,relatime,mode=777)
tmpfs on /tmp type tmpfs (rw,relatime)
tmpfs on /run type tmpfs (rw,nosuid,nodev,relatime,mode=755)
sysfs on /sys type sysfs (rw,relatime)
# uname -a
Linux Embedfire_imx6ull 4.19.35+ #1 SMP PREEMPT Tue May 12 23:27:36 CST 2026 armv7l GNU/Linux
# df -h
Filesystem                Size      Used Available Use% Mounted on
/dev/root                29.0G     45.6M     27.5G   0% /
devtmpfs                 81.1M         0     81.1M   0% /dev
tmpfs                   241.6M         0    241.6M   0% /dev/shm
tmpfs                   241.6M     44.0K    241.5M   0% /tmp
tmpfs                   241.6M     20.0K    241.6M   0% /run
# cat /etc/inittab | grep ttymxc0 || true
ttymxc0::respawn:/sbin/getty -L  ttymxc0 115200 vt100 # GENERIC_SERIAL

```