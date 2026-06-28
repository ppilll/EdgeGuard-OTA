# E4阶段
## E4阶段主要是完成了u-boot env的脚本设计
- 包括当前槽位与待升级槽位
- 槽位启动次数以及限制启动次数
- 升级失败后如何回滚、
- 升级成功如何标记成功
等问题
我们从最开始的自定义环境变量，启动时修改启动次数、到u-boot的bootcount,bootlimit,atbootcmd
再到rauc的BOOT_ORDER、BOOT_x_LEFT。完成了启动设计的优化，最后选择了rauc的设计方案。

同时我们完成了各类OTA情况下升级的验证实验：
- 签名错误
- 升级后未标记sccuess
- 时间错误
- 构造错误死循环init rootfs
## OTA各分支逻辑如下：
### 分支 A：正常开机，无 OTA

当前状态：

```BOOT_ORDER=B A
BOOT_B_LEFT=3
BOOT_A_LEFT=3
bootcmd=run eg_rauc_boot```

执行逻辑：

```上电
→ U-Boot 执行 bootcmd
→ bootcmd=run eg_rauc_boot
→ eg_rauc_boot 读取 BOOT_ORDER=B A
→ 优先尝试 B
→ 检查 BOOT_B_LEFT > 0
→ BOOT_B_LEFT 从 3 减到 2
→ saveenv
→ setenv eg_next B
→ run eg_bn
→ eg_bn 调用 eg_b
→ eg_b 设置 root=/dev/mmcblk0p3 rauc.slot=B
→ Linux 从 B 启动
→ 用户态执行 edgeguard-boot-success
→ rauc status mark-good booted
→ BOOT_B_LEFT 恢复到 3```


### 分支 B：正常 OTA 安装成功，新槽启动成功

假设当前从 B 启动，要安装新版本到 A。

当前状态：

```Booted from: rootfs.1 (B)
BOOT_ORDER=B A
BOOT_B_LEFT=3
BOOT_A_LEFT=3```

执行逻辑：

```edgeguard-ota-install new.raucb
→ rauc info 校验 bundle
→ rauc install new.raucb
→ RAUC 判断当前 booted slot 是 B
→ RAUC 选择 inactive slot A 作为安装目标
→ 写入 /dev/mmcblk0p2
→ 因 activate-installed=true，RAUC 自动激活 A
→ BOOT_ORDER 变为 A B
→ BOOT_A_LEFT 设置为 3
→ reboot
→ U-Boot 执行 eg_rauc_boot
→ 读取 BOOT_ORDER=A B
→ 尝试 A
→ BOOT_A_LEFT 从 3 减到 2
→ 启动 /dev/mmcblk0p2
→ cmdline 包含 rauc.slot=A
→ Linux 用户态起来
→ edgeguard-boot-success
→ rauc status mark-good booted
→ A 被确认为 good
→ BOOT_A_LEFT 恢复为 3```

activate-installed=true 的语义就是：新安装的 slot 会自动标记为下次启动的 active slot；如果设为 false，则需要手动激活。

### 分支 C：OTA 安装前失败

这包括你之前已经测过的 bad signature、untrusted cert、compatible mismatch。

执行逻辑：

```edgeguard-ota-install bad.raucb
→ rauc info 或 rauc install 失败
→ 脚本退出
→ 不 reboot
→ RAUC 不激活 inactive slot
→ BOOT_ORDER 不应改变
→ 当前 slot 继续运行```

这类失败属于“安装前安全失败”，不是“启动失败回滚”。它证明签名、compatible、安装入口短路正确，但不证明 bootloader fallback。

### 分支 D：安装成功，但新系统启动失败

假设当前 B 是 old good，要安装 bad rootfs 到 A。

初始：

```Booted from: B
BOOT_ORDER=B A
BOOT_B_LEFT=3
BOOT_A_LEFT=3```

安装后：

```RAUC install bad bundle 到 A
→ activate-installed=true
→ BOOT_ORDER=A B
→ BOOT_A_LEFT=3```

```第一次重启：

U-Boot 读 BOOT_ORDER=A B
→ 尝试 A
→ BOOT_A_LEFT 从 3 减到 2
→ 启动 A
→ A 是坏 rootfs
→ 无法进入用户态，或者没有执行 edgeguard-boot-success
→ BOOT_A_LEFT 不会恢复到 3

如果 A 卡死，E4 允许手动 reset；E5 才用 watchdog 自动 reset。

第二次 reset：

U-Boot 再次读 BOOT_ORDER=A B
→ BOOT_A_LEFT=2
→ 再尝试 A
→ BOOT_A_LEFT 从 2 减到 1
→ A 仍失败

第三次 reset：

U-Boot 尝试 A
→ BOOT_A_LEFT 从 1 减到 0
→ A 仍失败

第四次 reset：

U-Boot 看到 BOOT_A_LEFT=0
→ 不再尝试 A
→ 尝试 BOOT_ORDER 里的下一个 slot：B
→ BOOT_B_LEFT 从 3 减到 2
→ 启动 B
→ B 是 old good
→ 用户态执行 edgeguard-boot-success
→ rauc status mark-good booted
→ BOOT_B_LEFT 恢复 3
```
这就是 RAUC U-Boot backend 的核心失败回滚逻辑。关键点是：失败的新槽不是靠用户态判断坏，而是因为它没有执行 mark-good，导致 BOOT_A_LEFT 不断消耗，最终 U-Boot 跳到 fallback slot。
