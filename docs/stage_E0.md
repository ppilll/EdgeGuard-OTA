# 总体产品闭环
```
┌──────────────────────────────┐
│          Host PC              │
│                              │
│  Buildroot build             │
│  RAUC bundle create          │
│  Test scripts                │
│  Report generator            │
└──────────────┬───────────────┘
               │
               │ image / bundle / test command
               ▼
┌──────────────────────────────┐
│       Target Device           │
│                              │
│  U-Boot                       │
│    └─ choose A/B slot         │
│                              │
│  Linux rootfs A               │
│  Linux rootfs B               │
│  data partition               │
│                              │
│  RAUC client                  │
│  health check                 │
│  watchdog daemon              │
└──────────────┬───────────────┘
               │
               │ serial log / status / result
               ▼
┌──────────────────────────────┐
│      Test Report              │
│                              │
│  version before/after         │
│  active slot                  │
│  upgrade result               │
│  rollback result              │
│  power-cut result             │
│  logs                         │
└──────────────────────────────┘
```

OTA主链路
```
当前运行 rootfs_A
        │
        ▼
安装 bundle 到 rootfs_B
        │
        ▼
设置下次启动 rootfs_B
        │
        ▼
重启
        │
        ▼
rootfs_B 启动
        │
        ▼
health check 成功？
        │
   ┌────┴────┐
   │         │
  是         否
   │         │
   ▼         ▼
mark good   rollback to rootfs_A
```

# 范围边界
# E0 范围边界

## 第一版必须做

- 可复现构建
- A/B rootfs
- U-Boot 启动选择
- RAUC 正常升级
- 失败回滚
- watchdog
- health check
- 随机掉电测试
- 串口日志采集
- 自动报告

## 第一版不做

- 云平台
- Web UI
- 差分升级
- 多设备管理
- secure boot
- 复杂证书管理
- bootloader A/B
- 容器 OTA

## 范围冻结原则

只要主链路还没有完成，不新增炫酷功能。

# E0：
## 产品定义：
EdgeGuard OTA 是一个面向嵌入式 Linux 设备的 OTA 可靠性验证平台，用于验证 A/B rootfs 升级、失败回滚、watchdog 自恢复、health check、随机掉电测试、串口日志采集和自动测试报告。

## 真实场景下拟解决的问题
嵌入式设备在OTA升级过程中可能遇到以下问题：
- 升级中断导致无法启动系统
- 新版本rootfs启动失败但无法回滚
- 应用启动失败但系统误判升级成功
- 看门狗配置不清导致死机无法恢复
- 掉电测试不可复现，无日志，无报告
- 镜像构建过程不可复现，交付物不可追踪
EdgeGuard OTA 的目标是提供一个可验证、可复现、可演示的最小产品闭环。

## 第一版目标板卡与运行环境  
  
第一版目标板卡：i.MX6ULL 开发板  
启动介质：SD 卡  
存储设备：暂定 /dev/mmcblk0  
构建系统：Buildroot  
Bootloader：U-Boot  
Kernel：开发板配套 Linux Kernel  
Rootfs：Buildroot 生成的 ext4 rootfs  
OTA 框架：RAUC  
测试连接：串口 + 网络/本地拷贝升级包  
掉电测试：第一版先手动断电，E6 阶段升级为继电器控制  
  
选择 i.MX6ULL + SD 卡作为第一版，是为了降低 bring-up 风险，优先验证 A/B rootfs、U-Boot 启动选择、RAUC 安装、health check、watchdog 和掉电恢复链路。
## OTA 框架选型理由：
我们的OTA升级策略选择的是主流的A/B rootfs升级，失败回滚方案，相比整镜像替换不会因为中断升级而变成砖，对比文件/包级更新，则不依赖包管理器或是高质量回滚。对比一些差分OTA则不那么复杂。双分区OTA这一方案在市面上算是比较成熟的方案。
在双分区OTA框架选择上，我们选择的是RAUC，对比像Mender、SWUpdate，RAUC的优势在于A/B 升级要稳、要可控、要安全。而Mender还需要去完善云平台、批量部署、Web UI等等,它更适合作为一个用户产品的OAT更新方案，而非针对于嵌入式工程师的一种轻量化的OTA选择。而SWUpdate则自由度更高，如果我们需要进行双分区OTA。我们需要明确很多的OTA升级逻辑，像介质支持，本地恢复，这种定制化程度高的OTA升级方式。基于上述考虑我认为RAUC对于针对嵌入式工程师双分区OTA升级而言，RAUC框架是最好的选择。

## A/B 分区 v0.1 假设

第一版采用 SD 卡分区，暂定结构如下：

- boot：存放 U-Boot 后续加载所需的 kernel、dtb 或启动文件，具体格式 E2 确认；
- rootfs_A：系统 A 槽，默认启动系统；
- rootfs_B：系统 B 槽，OTA 写入的 inactive slot；
- data：保存 OTA 日志、health check 结果、测试报告和设备状态。

E0 阶段不锁定精确分区大小和编号。E2 阶段需要通过实际分区表、bootargs、U-Boot env 和启动日志确认 A/B 两个 rootfs 都能独立启动。
## 产品链路
正常升级链路：
### 旧版本系统启动：
- 下载或本地安装OTA包
- 写入inactive rootfs
- 设置下次启动槽位
- 重启
- 新槽位启动
- health check 成功  
- 标记新版本 good  
- 升级完成
### 失败回滚链路：
- 安装坏版本到 inactive rootfs
- 设置下次启动槽位
- 重启
- 新槽位启动失败或health check失败
- 看门狗或bootcount 触发恢复
- 回到旧槽位
- 报告升级失败原因
### 随机掉电测试链路
测试机控制电源
- 触发 OTA
- 在随机时间断电
- 恢复供电
- 采集串口日志
- 判断系统是否可恢复
- 记录当前槽位、版本、结果
- 生成测试报告
## watchdog 与 health check 的职责边界：
在EdgeGuard OTA里**health check 是判断逻辑，watchdog 是最后保险丝**。
health check:
- 判断新系统是否真的可用
- 决定是否mark-good/bad
- 决定是否请求重启或回滚
watchdog:
- 监控系统是否卡死、喂狗程序是否还活着
- 在系统无法正常完成判断或恢复时强制复位
- 不负责理解OTA业务语义
## 掉电测试台设计边界；
掉电测试不属于OTA系统的一部分，而是外部可靠性验证工具
它的主要功能是制造故障，记录过程，判断结果，生成报告，而不涉及OTA升级失败设备恢复

## 默认技术路线
- 构建系统：Buildroot
- Bootloader：U-Boot
- OTA 框架：RAUC
- 分区方式：A/B rootfs + data 分区
- health check：systemd service 或 init 脚本
- watchdog：Linux watchdog 设备
- 测试控制：Python 脚本
- 日志采集：串口日志 + 测试脚本保存
- 报告格式：Markdown / HTML / JSON
##   阶段验收标准概览

| 阶段  | 输入                  | 输出        | 最小验证         |
| --- | ------------------- | --------- | ------------ |
| E1  | Buildroot 配置        | 可启动基础镜像   | 系统能启动并打印版本   |
| E2  | A/B 分区设计            | A/B 可选启动  | A 和 B 都能独立启动 |
| E3  | RAUC 配置             | 正常 OTA 成功 | A 升级到 B      |
| E4  | bootcount/health 设计 | 失败回滚      | 坏版本回到旧版本     |
| E5  | watchdog 设计         | 自恢复机制     | health 失败后复位 |
| E6  | 掉电测试脚本              | 测试报告      | N 轮随机掉电后有统计  |
| E7  | 全部产物                | 可交付包      | README 可复现   |
## E0 阶段工程资产路径  
  
Git 仓库：  
[embedded-linux-product-portfolio/edgeguard-ota/  ](https://github.com/ppilll/EdgeGuard-OTA)
  
当前文档：  
edgeguard-ota/README.md  
edgeguard-ota/docs/product_overview.md  
edgeguard-ota/docs/stage_E0.md  
  
当前状态：  
E0 阶段只完成产品定义和技术边界，不包含 RAUC 集成、U-Boot 回滚、watchdog 实现和掉电测试实现。