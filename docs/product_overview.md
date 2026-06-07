EdgeGuard OTA：嵌入式 Linux A/B OTA 与掉电可靠性测试平台
# 产品定义：
EdgeGuard OTA是一个面向嵌入式linux设备的OTA可靠性验证平台，用于验证A/B rootfs、失败回滚、watchdog自动恢复、health check、随机掉电测试、串口日志采集和自动测试报告。
# 目标用户
- 嵌入式linux/bsp工程师
- 设备厂商固件工程师
- OTA平台验证工程师
- 技术评审人员
# 真实场景下拟解决的问题
嵌入式设备在OTA升级过程中可能遇到以下问题：
- 升级中断导致无法启动系统
- 新版本rootfs启动失败但无法回滚
- 应用启动失败但系统误判升级成功
- 看门狗配置不清导致死机无法恢复
- 掉电测试不可复现，无日志，无报告
- 镜像构建过程不可复现，交付物不可追踪
EdgeGuard OTA 的目标是提供一个可验证、可复现、可演示的最小产品闭环。
#  默认技术路线

- 构建系统：Buildroot
- Bootloader：U-Boot
- OTA 框架：RAUC
- 分区方式：A/B rootfs + data 分区
- health check：systemd service 或 init 脚本
- watchdog：Linux watchdog 设备
- 测试控制：Python 脚本
- 日志采集：串口日志 + 测试脚本保存
- 报告格式：Markdown / HTML / JSON
# 产品链路
正常升级链路：
## 旧版本系统启动：
- 下载或本地安装OTA包
- 写入inactive rootfs
- 设置下次启动槽位
- 重启
- 新槽位启动
- health check 成功  
- 标记新版本 good  
- 升级完成
## 失败回滚链路：
- 安装坏版本到 inactive rootfs
- 设置下次启动槽位
- 重启
- 新槽位启动失败或health check失败
- 看门狗或bootcount 触发恢复
- 回到旧槽位
- 报告升级失败原因
## 随机掉电测试链路
测试机控制电源
- 触发 OTA
- 在随机时间断电
- 恢复供电
- 采集串口日志
- 判断系统是否可恢复
- 记录当前槽位、版本、结果
- 生成测试报告
#  阶段验收标准概览

| 阶段  | 输入                  | 输出        | 最小验证         |
| --- | ------------------- | --------- | ------------ |
| E1  | Buildroot 配置        | 可启动基础镜像   | 系统能启动并打印版本   |
| E2  | A/B 分区设计            | A/B 可选启动  | A 和 B 都能独立启动 |
| E3  | RAUC 配置             | 正常 OTA 成功 | A 升级到 B      |
| E4  | bootcount/health 设计 | 失败回滚      | 坏版本回到旧版本     |
| E5  | watchdog 设计         | 自恢复机制     | health 失败后复位 |
| E6  | 掉电测试脚本              | 测试报告      | N 轮随机掉电后有统计  |
| E7  | 全部产物                | 可交付包      | README 可复现   |

# 风险控制

| 风险 | 影响 | 规避方案 | 降级方案 |
|---|---|---|---|
| 真实板卡 U-Boot 难改 | E2 卡住 | 先用 QEMU 验证 | 用脚本模拟 slot 选择 |
| RAUC 和 U-Boot 集成复杂 | E3/E4 卡住 | 先本地 bundle + 手动切槽 | 先不做自动回滚 |
| watchdog 驱动不可用 | E5 卡住 | 使用 softdog 或 QEMU watchdog | 用 reboot 模拟 |
| 掉电硬件不稳定 | E6 卡住 | 先用 QEMU reset 模拟 | 手动断电 + 串口日志 |
| 构建时间太长 | E1 卡住 | 固定 defconfig 和下载缓存 | 使用预构建镜像 |