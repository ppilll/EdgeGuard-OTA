# 1. 为什么用 Python，而不是 shell 或 C/C++

从能力上讲，shell、Python、C/C++ 都能完成类似事情。区别不在于“能不能”，而在于开发成本、可维护性、可移植性和测试证据结构化程度。

Python 的优势主要在主机端编排。你这几份脚本要做的事情包括：解析命令行参数、读 YAML 配置、打开串口、异步读串口、按行加时间戳、正则解析输出、写 JSON、处理异常、创建目录、生成退出码。Python 标准库本身就覆盖了很多这类主机端工具逻辑，例如 argparse 用来构建命令行接口，官方文档也说明它会处理参数解析、帮助信息和非法参数报错；pathlib、json、datetime、threading、queue 等也都是标准库。

真正额外引入的核心第三方依赖其实主要是两个：pyserial 和 PyYAML。其中 pyserial 是为了跨平台访问串口，它的项目说明覆盖 Win32、OSX、Linux、BSD 等平台；它的 API 也直接支持串口 port、baudrate、timeout、write_timeout、read/write/flush 等能力。 PyYAML 是为了读配置文件；如果你非常介意依赖，它完全可以被 JSON、TOML 或 INI 替代，其中 JSON 可直接用 Python 标准库，TOML 在较新的 Python 版本里可用 tomllib 读。

shell 的优点是轻量、主机上通常已有、部署最简单。问题是串口交互、超时控制、按行缓冲、正则解析、JSON 结构化、异常分类、并发日志线程会很快变得难维护。比如 shell 可以用 stty + cat + tee + timeout + grep 做日志，也可以配合 expect 自动登录串口，但复杂度上来后，脚本可读性和错误处理会下降。

C/C++ 的优点是依赖少、性能高、可编译成单个二进制。问题是这个场景不是性能瓶颈场景。你采的是 UART 文本、执行的是 shell 命令、写的是 JSON 文件。用 C/C++ 会把大量精力花在串口 termios 配置、线程同步、字符串处理、正则、JSON 序列化、配置解析、异常路径和跨平台兼容上。除非你要做长期产品化工具、对部署环境极端受限，或者公司内部规定不能装 Python 包，否则 C/C++ 的投入产出比不一定高。

所以，Python 的选择逻辑大概是：它不是最轻的，也不是最快的，但它是“主机端测试自动化”里开发效率、可读性、可维护性、功能完整性比较均衡的选择。

# 2. 为什么还需要采集脚本，而不是手动用 MobaXterm

手动串口工具当然能做。MobaXterm 官方文档也明确支持 SSH、telnet、rlogin 或 serial 连接，并且可以在本地 Windows 终端运行 Unix 命令。 对 bring-up、临时排障、人工观察来说，MobaXterm 很合适。

但采集脚本解决的不是“能不能通信”，而是下面这些问题。

第一，操作可重复。你手动输入命令时，今天输的是 rauc status --detailed，明天可能少输一个命令，后天可能先输 dmesg 再输 findmnt。脚本把命令集合固定下来，每次采集同一批证据。

第二，结果可比较。手动看输出靠人判断，脚本可以把结果变成固定字段，例如：

这样后续可以自动 diff、自动归档、自动判定。人工日志很难稳定做到这一点。

第三，时间戳统一。e6_serial_logger.py 给每一行串口输出加主机端毫秒时间戳。手动终端看到的是滚动文本，事后很难准确回答“U-Boot 出现在几点几分几秒”“kernel 启动到 login prompt 花了多久”“断电后多久重新有串口输出”。

第四，证据链完整。电源事件 JSON、串口日志、probe JSON 可以互相对齐。人工方式下，你可能有一份 MobaXterm log，但缺少断电确认时间、上电确认时间、命令退出码、解析后的结构化状态。

第五，减少人为误判。比如 cat /etc/edgeguard_slot 被脚本列入 forbidden command，说明测试设计者可能认为这个文件不是权威槽位来源。人工操作时很容易因为习惯而使用错误信息源。脚本可以强制大家走同一套判据。

第六，便于 CI 或批量测试。人用 MobaXterm 无法自然地给 CI 返回 exit code，也不方便批量跑 50 次断电恢复测试。脚本可以返回 0 或 2，也可以产出机器可读 JSON。

第七，便于问题复现。测试失败后，你可以把 manual_power_event.json、serial.log、probe.json 发给别人。别人不需要知道当时操作者具体看到了什么，只要看结构化结果和原始日志。

所以，MobaXterm 是交互工具，采集脚本是测试证据生产工具。两者不是替代关系，而是不同阶段使用：bring-up 用 MobaXterm 更快；回归、验收、故障归档、批量测试用脚本更可靠。

# 4. 为什么不直接让开发板自己保存 log
开发板自己保存 log 也有价值，但它不能完全替代主机端串口采集。

关键区别是：板端日志依赖开发板自身已经运行到某个阶段，而串口日志可以覆盖更早阶段。

开发板自己的文件日志通常要等 kernel、rootfs、init/systemd、日志服务、存储挂载之后才可靠。而 e6_serial_logger.py 通过 UART 可以采到 U-Boot、kernel early boot、init 前后的输出。pySerial 的串口 API 本身就是按字节从主机端端口读取数据，脚本可以在开发板刚上电时就开始接收。

板端日志还有几个常见问题：

断电测试时，板端文件系统可能还没 flush，日志可能丢。

如果 /data 没挂载或损坏，板端日志可能根本写不进去。

如果测试目标就是验证 rootfs、RAUC、A/B 槽位和 /data 挂载状态，那你不能完全信任被测对象自己写出的日志。

如果系统时间没同步，板端日志时间戳可能是 1970、默认时间，或者跳变；主机端时间戳反而更稳定。

如果卡在 U-Boot 或 kernel panic，板端用户态日志服务不会启动；主机串口仍可能看到关键输出。

所以更合理的理解是：板端日志是系统内部视角，主机串口日志是外部观察视角。做断电恢复、启动链路、OTA A/B 验证时，外部观察视角很重要。

# 5. 什么时候不用 Python 脚本更合适

不是所有阶段都应该用这套 Python 脚本。

在早期 bring-up 阶段，板子经常进不了 shell、串口参数不确定、命令也在变化，用 MobaXterm/minicom/screen 手动调试更快。

在一次性问题定位阶段，人工串口工具更灵活，因为你可以临时试命令、改环境变量、观察交互式输出。

在生产线环境，如果主机环境极度受限，不允许安装 Python 包，C/C++ 单文件工具或者 shell 工具可能更合适。

在安全管控严格的场景，如果测试工具必须最小依赖、可审计、可签名、可离线部署，那么 Python 需要打包和依赖锁定，否则不如编译型工具干净。

但在回归测试、断电恢复测试、OTA A/B 验证、批量采样、报告生成这些场景，脚本的价值会明显高于手动操作。

Case 1:
断电点：OTA 写入未完成
执行位置：A 槽升级，写 B 槽
恢复结果：回到 A
分类：rollback_success / install_interrupted_but_recovered
判定：PASS

Case 2:
断电点：inactive rootfs B ext4 mount / 写入阶段
执行位置：A 槽升级，写 B 槽
恢复结果：回到 A
分类：install_interrupted_but_recovered
判定：PASS

Case 3:
断电点：OTA 安装完成、激活完成、reboot/shutdown 阶段
执行位置：B 槽升级，写 A 槽
关键证据：
  Installing done
  Installing succeeded
  BOOT_ORDER=A B
  BOOT_A_LEFT=3
  BOOT_B_LEFT=3
恢复结果：到 A
分类：upgrade_success / activated_slot_boot_success
判定：PASS

Case 4:
断电点：new slot 首启阶段
执行位置：A 槽升级，启动 B 槽
恢复结果：到 B
分类：upgrade_success / boot_recovered
判定：PASS

Case 5:
断电点：watchdog / health check 阶段
执行位置：A 槽升级，启动 B 槽
恢复结果：到 B
分类：upgrade_success / health_watchdog_recovered
判定：PASS