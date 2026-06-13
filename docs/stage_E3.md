# E3阶段目标
在 i.MX6ULL 实板上，把 RAUC 集成进 Buildroot rootfs，制作 rootfs.tar + plain RAUC bundle，从当前运行槽安装到 inactive rootfs，并通过 E2 已验证的手动 U-Boot 命令启动新版本 0.3.0-e3。

## 1. E1/E2 基线

- E1: Buildroot rootfs 适配与实板启动验证
- E2: A/B rootfs 分区与手动 U-Boot 切槽已验证
- rootfs_A/rootfs_B 来自同一个 rootfs.tar
- A/B 区别由 /etc/edgeguard_slot 标识

## 2. 分区布局

```text
p1 boot      FAT32
p2 rootfs_A  ext4
p3 rootfs_B  ext4
p4 data      ext4
```

## 完整链路调用
```
                        构建端
                           │
                Buildroot 生成 rootfs.ext4
                           │
             manifest.raucm 描述版本、板型
                           │
           使用证书和私钥执行 rauc bundle
                           │
                           ▼
                 update-1.2.0.raucb
              包含 rootfs、manifest、签名
                           │
                    USB / HTTP / OTA平台
                           │
                           ▼
                        目标设备
                           │
                rauc install update.raucb
                           │
              目标端 keyring 验证签名
                           │
              检查 compatible 是否匹配
                           │
       当前运行 rootfs_A → 选择非活动 rootfs_B
                           │
                 把 rootfs 写入 B
                           │
             设置 U-Boot 下次优先启动 B
                           │
                         reboot
                           │
                           ▼
                  U-Boot 试启动 rootfs_B
                           │
            ┌──────────────┴──────────────┐
            │                             │
        启动和应用正常                启动或应用失败
            │                             │
  rauc status mark-good         不执行 mark-good / mark-bad
            │                             │
      B 成为稳定版本              watchdog 重启并减少次数
                                          │
                                   次数耗尽后启动 A
```

## 安全证书、公钥与密钥

生成证书
```
openssl genrsa \
  -out "$PROJECT/certs/private/ca.key.pem" \
  4096

openssl req \
  -x509 \
  -new \
  -nodes \
  -key "$PROJECT/certs/private/ca.key.pem" \
  -sha256 \
  -days 3650 \
  -subj "/CN=EdgeGuard E3 Development CA/" \
  -out "$PROJECT/certs/ca.cert.pem"

openssl genrsa \
  -out "$PROJECT/certs/private/dev.key.pem" \
  4096

openssl req \
  -new \
  -key "$PROJECT/certs/private/dev.key.pem" \
  -subj "/CN=EdgeGuard E3 Bundle Signer/" \
  -out "$PROJECT/certs/private/dev.csr.pem"

openssl x509 \
  -req \
  -in "$PROJECT/certs/private/dev.csr.pem" \
  -CA "$PROJECT/certs/ca.cert.pem" \
  -CAkey "$PROJECT/certs/private/ca.key.pem" \
  -CAcreateserial \
  -out "$PROJECT/certs/dev.cert.pem" \
  -days 825 \
  -sha256
```
- 根 CA 私钥 ca.key.pem
- 根 CA 证书 ca.cert.pem
- Bundle 签名私钥 dev.key.pem 
- 生成 证书签名请求 CSR dev.csr.pem
- CA 签发 Bundle signer 证书 dev.cert.pem

把公钥放证书放入rootfs overlay

