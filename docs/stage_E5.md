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