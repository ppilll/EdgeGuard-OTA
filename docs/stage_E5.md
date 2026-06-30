E5：health check + watchdog + kernel critical capability validation

主线：
- health check 判断新系统是否健康
- 成功后 mark-good
- 失败后不 mark-good / mark-bad / reboot
- watchdog 负责 health check 卡死后的 reset 兜底

内核子线：
- 裁剪并验证 MMC、ext4、UART、watchdog 等 OTA 必需内核能力
- 不做激进裁剪
- 每裁掉一类功能，都必须证明 E1~E4 主链路仍可用

```
系统启动
  |
  v
/etc/init.d/S99edgeguard-health start
  |
  v
等待 /data 挂载，最多 30 秒
  |
  +-- /data 未挂载 --> 不 mark-good --> sync --> reboot --> reboot -f
  |
  v
执行 /usr/bin/edgeguard-health-check
  |
  +-- health-check FAIL
  |       |
  |       +--> 记录 BOOT_ORDER/BOOT_A_LEFT/BOOT_B_LEFT
  |       +--> 不 mark-good
  |       +--> reboot，交给 bootloader 重试或回滚
  |
  v
health-check PASS
  |
  v
执行 rauc status mark-good booted
  |
  +-- mark-good PASS
  |       |
  |       +--> 记录 U-Boot A/B 环境变量
  |       +--> sync
  |       +--> exit 0，当前 slot 被确认
  |
  +-- mark-good FAIL
          |
          +--> 记录 U-Boot A/B 环境变量
          +--> 不确认当前 slot
          +--> reboot
```


```
RAUC 安装新系统到 inactive slot
  -> bootloader 下次启动新 slot
  -> 新系统启动
  -> S99edgeguard-health 运行
  -> edgeguard-health-check 做健康检查
  -> 通过则 mark-good
  -> 失败则不 mark-good 并重启
  -> bootloader 根据 BOOT_*_LEFT 决定重试或回滚
```

```
S98edgeguard-watchdog start
        |
        |-- 如果 /data/edgeguard/watchdog/enable_keeper 存在
        |-- 后台启动 /usr/bin/edgeguard-watchdog-keeper
        |
        v
edgeguard-watchdog-keeper
        |
        |-- 打开 /dev/watchdog
        |-- 健康检查还没结束时，周期性喂狗
        |-- 看到 /run/edgeguard/health.ok 后，继续喂狗
        |-- 看到 /run/edgeguard/health.fail 后，停止喂狗，等待 watchdog 复位
        |-- 超过 HEALTH_TIMEOUT 还没看到 ok/fail，也停止喂狗，等待 watchdog 复位
        |
        v
S99edgeguard-health start
        |
        |-- 执行 edgeguard-health-check
        |-- 成功：rauc status mark-good booted，然后 touch /run/edgeguard/health.ok
        |-- 失败：touch /run/edgeguard/health.fail
```

```
enable_keeper 不存在：
    keeper 不启动。
    即使 use_watchdog_on_fail 存在，也没有 keeper 喂狗/停喂狗，watchdog 集成不完整。

enable_keeper 存在，use_watchdog_on_fail 不存在：
    keeper 启动。
    健康检查 pending 时 keeper 喂狗。
    健康检查成功后 keeper 继续喂狗。
    健康检查失败后 S99 主动 reboot。
    如果 S99 卡住，keeper 超时后仍可触发 watchdog reset。

enable_keeper 存在，use_watchdog_on_fail 存在：
    keeper 启动。
    健康检查 pending 时 keeper 喂狗。
    健康检查成功后 keeper 继续喂狗。
    健康检查失败后 S99 不主动 reboot，keeper 停止喂狗，等待 watchdog reset。
```

```
1. init 执行 S98edgeguard-watchdog start
2. S98 检查 enable_keeper 存在
3. S98 后台启动 edgeguard-watchdog-keeper
4. keeper 打开 /dev/watchdog
5. keeper 初始喂狗
6. keeper 创建 /run/edgeguard/watchdog.ready
7. keeper 等待 health.ok 或 health.fail，期间持续喂狗
8. init 执行 S99edgeguard-health start
9. S99 等待 /data 挂载
10. S99 执行 edgeguard-health-check
11. 健康检查通过
12. S99 执行 rauc status mark-good booted
13. mark-good 成功
14. S99 创建 /run/edgeguard/health.ok
15. keeper 看到 health.ok
16. keeper 继续周期性喂狗
17. 系统保持运行
```

除了健康检查失败能回滚之外，健康检查卡死、启动流程卡住、手动 reboot 失败 这类异常也能通过 watchdog 兜底复位。当前设计的最大风险是：use_watchdog_on_fail 依赖 keeper 已经成功启动，建议用 /run/edgeguard/watchdog.ready 做保护判断。