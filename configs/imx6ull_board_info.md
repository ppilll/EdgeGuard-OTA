# i.MX6ULL Board Info

## Basic

| Item | Value |
|---|---|
| Board vendor | 野火 |
| Board model | EBF6ULL S1 PRO |
| CPU | NXP i.MX6ULL / ARM Cortex-A7 |
| RAM size | 512MB DDR3 |
| Flash type | 8GB eMMC/32GB SD card |
| Boot media for E1 | SD card |
| Power input | DC 12V@2A 直流输入 |
| Ethernet PHY | 2路百兆以太网，型号KSZ8081RNB |
| LCD / display | not used in E1 |

## Serial Console

| Item | Value |
|---|---|
| Host serial device | `/dev/ttyUSB0` |
| Target UART | `UART1` |
| Linux console device | `/dev/ttymxc0` |
| Baudrate | `115200` |
| Data bits | `8` |
| Parity | `none` |
| Stop bits | `1` |
| Flow control | `none` |

## Bootloader / Kernel Source

| Item | Value |
|---|---|
| Existing vendor U-Boot? | [yes](https://doc.embedfire.com/lubancat/build_and_deploy/zh/latest/building_image/use_uboot/use_uboot.html) |
| Existing vendor kernel? | [yes](https://doc.embedfire.com/lubancat/build_and_deploy/zh/latest/building_image/building_kernel/building_kernel.html#id3) |
| Buildroot builds U-Boot in E1? | no |
| Buildroot builds kernel in E1? | no |
| U-Boot defconfig | use the vendor defconfig |
| Kernel defconfig | use the vendor defconfig |
| Device tree file | `imx6ull-14x14-evk.dtb` |

## Storage / Flashing

| Item | Value |
|---|---|
| SD card host node |`/dev/mmcblk0` |
| SD card capacity | 32G |
| Flash method | `dd` / vendor tool / manual partition copy |
| Rootfs partition | `/dev/mmcblk0p2` |
| Boot partition | `/dev/mmcblk0p1` |

### 之前使用的eMMC
| Item | Value |
|---|---|
|eMMC 设备节点：|/dev/mmcblk1|
|当前 eMMC rootfs：|/dev/mmcblk1p2|


