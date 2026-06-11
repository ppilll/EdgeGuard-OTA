# E1阶段目标
在 i.MX6ULL 真实开发板 上，用固定 Buildroot 版本和固定 defconfig 构建一个最小 Linux 系统，烧录到 SD 卡启动，通过串口登录 shell，并能执行`cat /etc/edgeguard_version`查看对应的版本信息如
```
EDGEGUARD_VERSION=0.1.0-e1
BUILD_STAGE=E1
BUILD_TARGET=imx6ull
BOARD_NAME=<你的板卡型号>
BOOT_MEDIA=sdcard
```
总之分点目标或清单可用概括为：
```
[√] i.MX6ULL 实板可启动
[√] 串口启动日志可保存
[√] Linux shell 可登录
[√] /etc/edgeguard_version 可读
[√] Buildroot 版本已固定
[√] configs/buildroot_defconfig 已固定
[√] 烧录方式已记录
[√] 启动参数 bootargs 已记录
[√] rootfs 来源清楚
[√] kernel 来源清楚
[√] dtb 来源清楚
[√] U-Boot 来源清楚
[√] 项目目录结构稳定
[√] 已经有 Git commit
```
## 优先级
- 优先级 1：复用厂家 U-Boot
- 优先级 2：Buildroot 编译 U-Boot
- 优先级 3：独立移植 U-Boot，仅作为风险项

## E1阶段新增文件介绍
[imx6ull_board_info.md](configs/imx6ull_board_info.md) 开发板板级信息
[E1_use_docs.md](docs/E1_use_docs.md) E1阶段构建脚本快速使用


