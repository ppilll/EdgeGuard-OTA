# E2 双分区rootfs启动

## 1.快速使用
### 备份E1阶段SD卡镜像

[backup_e1_sdcard.sh](../scripts/backup_e1_sdcard.sh)
```
chmod +x scripts/backup_e1_sdcard.sh
scripts/backup_e1_sdcard.sh /dev/sdb
```
### 烧入双分区rootfs
[prepare_ab_sdcard.sh](../scripts/prepare_ab_sdcard.sh)
使用方式类似于`make_sdcard_vendor_boot.sh`,参考该脚本的快速使用方式
