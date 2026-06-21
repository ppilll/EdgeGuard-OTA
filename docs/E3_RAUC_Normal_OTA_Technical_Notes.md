# EdgeGuard OTA E3 技术说明：RAUC 在手动 A/B 启动链路中的作用

## 1. E3 阶段结论

EdgeGuard_OTA 的 E3 阶段目标已经完成。当前系统已经验证了完整的“正常 OTA 主链路”：

当前运行槽 A，也就是 `/dev/mmcblk0p2`，运行版本 `0.3.0-e3`。主机端构建 `0.3.1-e3` rootfs，并将其封装为 RAUC bundle。目标板从 A 启动后执行 `rauc install`，RAUC 将 bundle 中的 `rootfs.tar` 安装到 inactive B，也就是 `/dev/mmcblk0p3`。随后通过手动 U-Boot 命令从 B 启动，并验证 B 中版本为 `0.3.1-e3`，`/etc/edgeguard_slot` 为 `SLOT=B`，`/proc/cmdline` 包含 `root=/dev/mmcblk0p3` 和 `rauc.slot=B`，`/data` 挂载自 `/dev/mmcblk0p4`，RAUC 识别当前 booted slot 为 `rootfs.1`。

E3 的边界也很明确：不做自动切槽，不做自动回滚，不做 bootcount，不做 watchdog，不做 `mark-good`，不让 RAUC 修改 U-Boot 环境变量。E3 使用 `bootloader=noop` 和 `activate-installed=false`，启动槽位切换仍然由人工在 U-Boot 命令行完成。

## 2. E2 已经能用 U-Boot 切 rootfs，E3 为什么还需要 RAUC

E2 解决的是“板子能不能从 A 或 B 启动”。它验证的是 bootloader 层面的能力：U-Boot 能加载同一套 kernel 和 DTB，并通过不同的 `root=/dev/mmcblk0p2` 或 `root=/dev/mmcblk0p3` 启动不同 rootfs。

E3 解决的是“如何安全、可验证、可追踪地把新 rootfs 写入 inactive slot”。这不是 U-Boot 擅长的事情。U-Boot 只负责启动，它并不负责 OTA 包格式、签名验证、证书链校验、manifest 解析、目标槽选择、写入过程记录、slot status 记录、安装日志和 bundle 元数据管理。

因此，E2 和 E3 的分工是：

E2：证明 A/B 分区布局和 U-Boot 启动参数可行。

E3：证明在 Linux 用户态中，RAUC 可以接收一个经过签名的 update bundle，验证它确实属于当前设备型号，验证其完整性和签名可信，然后把其中的 rootfs payload 写入当前未运行的 rootfs 分区。

也就是说，E3 并没有替代 U-Boot。E3 中的 RAUC 负责“安全安装”；U-Boot 仍负责“选择哪个 rootfs 启动”。

## 3. 在 E3 中 RAUC 扮演的角色

在当前 E3 架构中，RAUC 扮演四个角色。

第一，RAUC 是 update artifact 的格式定义者。我们不是直接把一个裸 `rootfs.tar` 丢到目标板执行脚本解压，而是把它放进 `.raucb` bundle。bundle 中包含 manifest、payload、签名信息和校验信息。

第二，RAUC 是安全校验者。目标板执行 `rauc info` 或 `rauc install` 时，会用 `/etc/rauc/keyring.pem` 验证 bundle 的签名证书链。证书不可信、证书未生效、证书过期、bundle 被篡改、checksum 不匹配，都会导致验证失败。

第三，RAUC 是目标槽选择者。RAUC 根据 `/etc/rauc/system.conf` 中定义的 slot 布局，以及当前启动槽判断哪个 rootfs 是 booted slot，哪个 rootfs 是 inactive slot。当前从 A，也就是 `rootfs.0` 启动时，RAUC 将 `[image.rootfs]` 写入对应 slot class 的 inactive B，也就是 `rootfs.1`。

第四，RAUC 是安装状态记录者。安装成功后，`rauc status --detailed` 可以看到 B 槽记录了 bundle 的 compatible、version、description、build、checksum、size、installed timestamp、install count 和 `status=ok`。这些信息不是 U-Boot 提供的，而是 RAUC 写入并维护的 slot status。

因此，RAUC 在 E3 中不是“启动器”，而是“可信 OTA 安装器”。

## 4. 为什么 RAUC 写 B 这一步仍然有必要

表面上看，最终仍然是 U-Boot 通过 `root=/dev/mmcblk0p3` 启动 B，似乎只要手动把 rootfs 写进 B 就可以。但 E3 的关键价值不在“写文件”本身，而在“以 OTA 系统的方式写入”。

直接手动写 B 的方式无法系统化解决以下问题：

无法确认这个 rootfs 是否是给 `edgeguard-imx6ull` 设备的。

无法确认 payload 是否被篡改。

无法确认 payload 是否来自被信任的开发签名证书。

无法统一描述版本号、构建号、镜像名称和 slot class。

无法让目标板上的 OTA 客户端判断当前运行槽，并自动选择 inactive slot。

无法记录安装状态、checksum、安装时间和安装次数。

无法为后续 E4/E5 的自动切槽、回滚、bootcount 和 mark-good 机制打基础。

E3 的 RAUC install 实际上是在建立 OTA 主链路的“安全安装层”。U-Boot 只是在安装完成后负责启动验证。二者是上下游关系，不是重复关系。

## 5. manifest.raucm 是什么

`manifest.raucm` 是 RAUC bundle 的清单文件。它是 bundle 中的元数据核心，用来告诉 RAUC：这个 bundle 适用于什么设备、版本是什么、bundle 格式是什么、包含哪些 image、每个 image 应该安装到哪一类 slot。

本项目 E3 的 manifest 是：

```ini
[update]
compatible=edgeguard-imx6ull
version=0.3.1-e3
description=EdgeGuard E3 normal A/B rootfs update
build=20260613

[bundle]
format=plain

[image.rootfs]
filename=rootfs.tar
```

其中：

`compatible=edgeguard-imx6ull` 表示该 bundle 只适用于系统 compatible 也是 `edgeguard-imx6ull` 的目标设备。如果目标板 `/etc/rauc/system.conf` 中 `[system] compatible` 不匹配，RAUC 应拒绝安装。

`version=0.3.1-e3` 是 OTA payload 的版本。我们用它验证 A 到 B 的版本变化。

`description` 是描述字段，用于 `rauc info` 和 `rauc status` 输出。

`build=20260613` 是构建标识。

`[bundle] format=plain` 指定 bundle 格式为 plain。E3 使用 plain，不做 verity。

`[image.rootfs] filename=rootfs.tar` 表示这个 bundle 中有一个 rootfs image，文件名为 `rootfs.tar`。`rootfs` 这个名字对应 slot class。RAUC 会把它安装到 system.conf 中 class 为 `rootfs` 的目标 slot。

RAUC 在 bundle 创建和安装过程中会基于 manifest 生成或校验 image checksum 和 size。目标板上执行 `rauc info` 时看到的 rootfs checksum：

```text
508607464cd4e2d29c949f521d02837583c69e331bcf303c9dd817344f0a0563
```

就是该 `rootfs.tar` payload 的 digest。

## 6. bundle 是什么，为什么需要构建 bundle

bundle 是 RAUC 的 OTA 更新包。它不是单纯的 tar 文件，而是一个包含 payload、manifest 和签名信息的更新单元。本项目生成的 bundle 是：

```text
edgeguard-update-v0.3.1-e3.raucb
```

它的 SHA-256 是：

```text
242f8c3c3b9a28e1404fe905669e8d87de581f6c8f0cadd8115da573ea8ac33e
```

bundle 中的 rootfs payload 是：

```text
rootfs.tar
sha256=508607464cd4e2d29c949f521d02837583c69e331bcf303c9dd817344f0a0563
size=12984320
```

我们需要 bundle 的原因有三个。

第一，bundle 是可验证的。RAUC 可以验证它是否由受信任证书签名，是否被篡改，manifest 是否有效，payload checksum 是否匹配。

第二，bundle 是自描述的。它携带 compatible、version、description、build、image class、filename、checksum、size 等信息。

第三，bundle 是 RAUC install 的输入单位。目标板不直接安装裸 `rootfs.tar`，而是安装 `.raucb`。这样可以把“安装内容”和“安装规则”绑定在一起。

## 7. host RAUC 签名生成 bundle 是什么

host RAUC 是主机端的 RAUC 工具。它运行在 Ubuntu 主机上，用于创建、签名和检查 `.raucb` 文件。

我们执行的核心命令是：

```sh
rauc bundle \
  --cert=dev.cert.pem \
  --key=dev.key.pem \
  --keyring=ca.cert.pem \
  bundles/input-v0.3.1 \
  bundles/output/edgeguard-update-v0.3.1-e3.raucb
```

这条命令做了几件事：

读取输入目录 `bundles/input-v0.3.1`。

读取 `manifest.raucm`。

读取 payload `rootfs.tar`。

根据 manifest 和 payload 生成 bundle 内容。

使用 `dev.key.pem` 对 bundle 进行数字签名。

把 `dev.cert.pem` 作为签名证书放入签名结构中。

用 `ca.cert.pem` 验证生成后的 bundle 签名是否能被项目 CA 信任。

所以，host RAUC 签名生成 bundle 的本质是：把 rootfs payload 和 manifest 封装成一个可信 update artifact，并用开发签名证书证明“这个 OTA 包确实由我们签发”。

## 8. 目标板执行 RAUC install 时发生了什么

目标板从 A 槽启动后，执行：

```sh
rauc install /data/bundles/edgeguard-update-v0.3.1-e3.raucb
```

这个过程主要包括以下步骤。

第一，读取系统配置。RAUC 读取 `/etc/rauc/system.conf`，其中定义了：

```ini
[system]
compatible=edgeguard-imx6ull
bootloader=noop
activate-installed=false
statusfile=/data/rauc/central.raucs
mountprefix=/mnt/rauc/
bundle-formats=plain

[keyring]
path=/etc/rauc/keyring.pem

[slot.rootfs.0]
device=/dev/mmcblk0p2
type=ext4
bootname=A

[slot.rootfs.1]
device=/dev/mmcblk0p3
type=ext4
bootname=B
```

第二，读取 bundle 并验证签名。目标板用 `/etc/rauc/keyring.pem` 验证 bundle 的签名证书链。你的板子时间一开始是 1970，导致证书尚未生效，验证失败。修复时间到 2026 后，RAUC 能成功验证签名。

第三，检查 manifest。RAUC 确认 bundle 的 `compatible=edgeguard-imx6ull` 和目标板 system.conf 中的 compatible 一致，确认 bundle 格式为 plain，确认存在 rootfs image。

第四，确定目标安装组。当前从 `/dev/mmcblk0p2` 启动，也就是 `rootfs.0` booted，所以另一个同 class 的 slot `/dev/mmcblk0p3`，也就是 `rootfs.1`，是 inactive slot。

第五，更新 inactive B。RAUC 挂载或打开 `/dev/mmcblk0p3`，将 `rootfs.tar` 的内容写入 B 槽。你的安装日志中显示：

```text
Checking slot rootfs.1
Copying image to rootfs.1
Installing ... succeeded
```

第六，写入 slot status。安装成功后，`rauc status --detailed` 中 `rootfs.1` 显示 version、checksum、installed timestamp、count 和 `status=ok`。

E3 中 RAUC 到此为止。它不会自动修改 U-Boot env，也不会自动让下次启动进入 B，因为我们配置了 `bootloader=noop` 和 `activate-installed=false`。

## 9. 安装成功后为什么要检查 inactive B

RAUC install 返回成功后，理论上 B 已被写入。但是在嵌入式 OTA 验收中，仅凭 install 返回值还不够。我们需要挂载 inactive B 做离线检查，确认它确实是预期的新系统。

阶段 6 检查了以下内容：

`/mnt/inactive/etc/edgeguard_version` 是否为 `EDGEGUARD_VERSION=0.3.1-e3`。

`/mnt/inactive/etc/edgeguard_slot` 初始是否为 `SLOT=UNKNOWN`，然后手动写成 `SLOT=B`。

`/mnt/inactive/etc/fstab` 是否包含 `/dev/mmcblk0p4 /data ext4 defaults,noatime 0 2`。

`/mnt/inactive/usr/bin/rauc` 是否存在。

`/mnt/inactive/sbin/mke2fs` 是否存在。

`/mnt/inactive/sbin/mkfs.ext4` 是否指向 `mke2fs`。

这样做的目的不是替代 RAUC，而是给 E3 提供可解释、可复现的人工验收依据。它能提前发现 payload 错误、overlay 没进 rootfs、`/data` 自动挂载缺失、RAUC 工具缺失、e2fsprogs 缺失等问题。你确实在最终 B 验证前发现了 `/data` 未自动挂载的问题，并通过补 init 脚本修复后重新验证成功。

## 10. /data 分区是什么，在哪些步骤中起作用

`/data` 是 SD 卡上的持久化数据分区，对应：

```text
/dev/mmcblk0p4
LABEL=data
TYPE=ext4
mountpoint=/data
```

它和 rootfs_A、rootfs_B 不同。A/B rootfs 会被 OTA 覆盖，而 `/data` 不应该被 OTA 覆盖。它用于存放跨 rootfs 版本保留的数据。

E3 中 `/data` 主要承担五类作用。

第一，存放 RAUC central status file。system.conf 中配置：

```ini
statusfile=/data/rauc/central.raucs
```

这意味着 RAUC 的 slot status 不存在 A 或 B 的 rootfs 内，而是存在持久化 data 分区中。这样 A 和 B 都能看到同一份安装状态记录。

第二，存放 OTA bundle。因为没有网络，我们将 bundle 复制到：

```text
/data/bundles/edgeguard-update-v0.3.1-e3.raucb
```

目标板从这里执行 `rauc info` 和 `rauc install`。

第三，存放日志。E3 中的 preflight、bundle 验证、install、inactive B 检查、B 启动验收日志都存放在：

```text
/data/logs/
```

这保证日志不依赖当前运行的 rootfs。即使 rootfs 切换，日志仍然可见。

第四，存放辅助脚本。你在 E3 中创建过 `/data/scripts`，后续可以用于存放修复脚本、验收脚本、测试脚本。

第五，作为跨版本持久化验证点。B 启动后必须确认 `/data` 仍然挂载自 `/dev/mmcblk0p4`，而不是误写到 rootfs 内的 `/data` 目录。你第一次 B 启动时正是发现 `/data` 未挂载，后续修复并严格验证通过。

因此，`/data` 是 E3 中连接 A/B rootfs 的持久化状态层。

## 11. 证书和密钥分别是什么，谁使用它们

本项目 E3 中用到以下证书和密钥：

```text
ca.key.pem
ca.cert.pem
dev.key.pem
dev.csr.pem
dev.cert.pem
```

它们之间的关系如下。

`ca.key.pem` 是根 CA 私钥。它只应该留在开发主机或更安全的签发环境中，用来签发 bundle signer 证书。它不应该放到目标板上，也不应该放进 bundle 中。拥有它的人可以签发新的可信 signer 证书，因此它是整个信任体系中最敏感的文件。

`ca.cert.pem` 是根 CA 证书。它包含根 CA 的公钥和身份信息，不含私钥。目标板上的 `/etc/rauc/keyring.pem` 本质上就是信任锚，用来验证 bundle 签名证书是否由可信 CA 签发。在主机端，我们也用它执行：

```sh
openssl verify -CAfile ca.cert.pem dev.cert.pem
```

确认 `dev.cert.pem` 是由该 CA 签发的。

`dev.key.pem` 是 bundle signer 私钥。它用于主机端执行 `rauc bundle --key=dev.key.pem` 时对 bundle 进行签名。它也不应该放到目标板上。拥有它的人可以签发合法 bundle，因此它也需要保护。

`dev.csr.pem` 是证书签名请求 CSR。它由 `dev.key.pem` 对应的公钥和身份信息生成，然后交给 CA 签发。CSR 不是运行时使用的文件，它只用于证书签发流程。

`dev.cert.pem` 是 CA 签发出来的 bundle signer 证书。它绑定了 signer 身份和 signer 公钥。主机端创建 bundle 时通过 `--cert=dev.cert.pem` 把该证书作为签名证书使用。目标板验证 bundle 时，会检查该 signer 证书是否能被 `/etc/rauc/keyring.pem` 中的 CA 证书信任。

可以用一条链描述：

```text
ca.key.pem 签发 dev.cert.pem
dev.key.pem 对 bundle 签名
dev.cert.pem 证明签名者身份
ca.cert.pem / keyring.pem 验证 dev.cert.pem 是否可信
目标板用 dev.cert.pem 中的公钥验证 bundle 签名
```

简化说：

CA 私钥负责“授予谁有签包资格”。

Bundle signer 私钥负责“给某个 bundle 签名”。

目标板 keyring 负责“判断这个 signer 是否可信”。

## 12. RAUC 如何完成签名校验、manifest 校验和目标槽选择

RAUC 的安装过程可以按三个校验层理解。

第一层是签名校验。目标板执行 `rauc info` 或 `rauc install` 时读取 bundle 的签名结构。它用 `/etc/rauc/keyring.pem` 中的 CA 证书验证 bundle 中携带的 signer 证书，也就是 `dev.cert.pem`。如果证书链不可信、证书时间无效、bundle 内容被篡改，验证失败。你在开发板时间为 1970 时看到的 `certificate is not yet valid` 就属于这一层失败。

第二层是 manifest 校验。签名通过后，RAUC 读取 manifest，检查 bundle 中声明的 compatible、version、build、bundle format、image 列表、image checksum、image size 等信息。E3 中重点检查了 `compatible=edgeguard-imx6ull`、`version=0.3.1-e3`、`Bundle Format=plain`、`rootfs.tar`、rootfs checksum。

第三层是目标槽选择。RAUC 读取 `/etc/rauc/system.conf`，知道系统有两个 rootfs slot：

```text
rootfs.0 -> /dev/mmcblk0p2 -> bootname A
rootfs.1 -> /dev/mmcblk0p3 -> bootname B
```

当前从 `/dev/mmcblk0p2` 启动，并且 cmdline 中含有对应 root 参数，RAUC 识别 `rootfs.0` 为 booted slot。因此，对于 manifest 中的 `[image.rootfs]`，RAUC 选择同 class 的 inactive slot，也就是 `rootfs.1`，作为安装目标。于是 `rootfs.tar` 被写入 `/dev/mmcblk0p3`。

## 13. bootloader=noop、boot status: bad 与 E3 的关系

E3 中 `system.conf` 配置：

```ini
bootloader=noop
activate-installed=false
```

这意味着 RAUC 不读取、不修改 U-Boot 环境变量，也不负责设置下一次启动槽。它也不会执行完整的 boot success feedback。RAUC 仍然能识别当前 booted slot，并能选择 inactive slot 进行安装，但它不参与自动切槽和自动回滚。

因此，`rauc status --detailed` 里看到：

```text
Failed getting primary slot: Obtaining primary entry from bootloader 'noop' not supported yet
boot status: bad
```

在 E3 是预期现象。它不表示 rootfs 坏，也不表示安装失败。E3 不使用 `mark-good` 作为验收项，boot status 没有实际闭环来源。

后续如果进入 E4/E5，要实现自动切槽和回滚，就需要切换到：

```ini
bootloader=uboot
```

并配置 `fw_printenv/fw_setenv`、U-Boot env 存储位置、bootcount、upgrade_available、bootlimit 等机制。那时 `mark-good` 才会成为关键动作。

## 14. 当前 E3 中最重要的技术难点

第一个难点是区分“启动链路”和“安装链路”。U-Boot 解决启动选择，RAUC 解决安全安装。E3 的意义不是让 RAUC 取代 U-Boot，而是引入一个可信 OTA 安装层。

第二个难点是 slot 识别。RAUC 必须知道当前从哪个 rootfs 启动，才能避免覆盖当前运行中的 rootfs。E3 中通过 system.conf 和 kernel cmdline 的 root 参数识别当前 booted slot。

第三个难点是证书时间。开发板没有持久时间，重启后回到 1970，导致签名证书尚未生效。这个问题不影响已经启动的 rootfs，但会影响 RAUC 的证书验证。E3 的临时处理方式是在安装前手动设置系统时间到证书有效期内。

第四个难点是 `/data` 的真实挂载。第一次 B 启动时，脚本显示 `DATA_WRITE_TEST=PASS`，但实际上 `/data` 没有挂载到 p4，只是写进了 rootfs 内部目录。这个问题通过严格检查 `/proc/mounts` 发现，并通过启动脚本修复。最终确认 `/dev/mmcblk0p4 /data ext4 rw,noatime` 后才真正满足 E3 条件。

第五个难点是 Buildroot overlay 的完整性。E3 payload 必须包含 `/etc/rauc/system.conf`、`/etc/rauc/keyring.pem`、`/etc/fstab`、`/etc/edgeguard_version`、`/etc/edgeguard_slot`、`/usr/bin/rauc`、`/sbin/mke2fs` 和 `/sbin/mkfs.ext4`。少任何一个都会影响后续验证或运维。

第六个难点是区分 host RAUC 和 target RAUC。host RAUC 负责在 Ubuntu 主机生成和检查 bundle；target RAUC 负责在开发板上验证并安装 bundle。二者是同一工具的不同运行环境，职责不同。

第七个难点是不用 RAUC bootloader backend 时如何验收。因为 E3 不接入 U-Boot env，不能用自动激活和 mark-good 验收。我们用人工 U-Boot 切 B、版本文件、cmdline、RAUC booted slot 和 `/data` 挂载作为验收依据。

## 15. E3 最终验收证据

E3 的最终有效证据如下：

主机端 bundle：

```text
edgeguard-update-v0.3.1-e3.raucb
sha256=242f8c3c3b9a28e1404fe905669e8d87de581f6c8f0cadd8115da573ea8ac33e
```

bundle 中 rootfs payload：

```text
rootfs.tar
sha256=508607464cd4e2d29c949f521d02837583c69e331bcf303c9dd817344f0a0563
version=0.3.1-e3
```

目标板安装前：

```text
当前 rootfs_A: /dev/mmcblk0p2
EDGEGUARD_VERSION=0.3.0-e3
SLOT=A
bundle sha256 PASS
rauc info PASS
inactive B not mounted PASS
```

RAUC install：

```text
INSTALL_RC=0
Installing succeeded
rootfs.1 version=0.3.1-e3
rootfs.1 status=ok
```

inactive B 检查：

```text
EDGEGUARD_VERSION=0.3.1-e3
SLOT=B
/etc/fstab contains /dev/mmcblk0p4 /data ext4 defaults,noatime 0 2
/usr/bin/rauc exists
/sbin/mke2fs exists
/sbin/mkfs.ext4 -> mke2fs
```

B 启动后：

```text
EDGEGUARD_VERSION=0.3.1-e3
SLOT=B
root=/dev/mmcblk0p3
rauc.slot=B
/dev/mmcblk0p4 /data ext4 rw,noatime
RAUC Booted from: rootfs.1 (B)
E3_AFTER_BOOT_B_STRICT_VALIDATE=PASS
```

因此，E3 可以归档为：

```text
E3 PASS: RAUC normal A/B OTA main path verified with manual U-Boot slot switch.
```

## 16. E3 之后建议进入的下一阶段

E4 可以做“半自动启动集成”：继续保留手动控制风险，但开始引入 U-Boot env 变量、`fw_printenv/fw_setenv`、`rauc.slot` 标准化和启动脚本整理。

E5 再做完整 RAUC bootloader integration：`bootloader=uboot`、自动激活 installed slot、bootcount、bootlimit、watchdog、`mark-good`、失败回滚。

不建议 E3 结束后立刻做复杂回滚。当前最合理的是先冻结 E3 成果，整理日志和文档，然后再进入 U-Boot backend 的设计。
