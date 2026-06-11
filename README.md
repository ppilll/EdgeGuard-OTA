# EdgeGuard OTA

## 项目目标
EdgeGuard OTA 是一个嵌入式 Linux A/B OTA 可靠性验证平台。[具体细节在这里](docs/product_overview.md)  
## 阶段划分
[E0-E7](docs/product_overview.md)  
## 当前状态
E0 已完成，
E1 已完成，
E2 未开始

## 目标硬件
i.MX6ULL + SD 卡

## 文档入口
- docs/product_overview.md
- docs/stage_E0.md

## 下一阶段 E2 验收
E2  A/B 分区设计     
 A/B 可选启动  
 A 和 B 都能独立启动 


外部来源
## Buildroot
版本：2021.02.3
本地路径：
`~/桌面/linux/Buildroot/buildroot-2021.02.3`

使用时需要将Buildroot链接到本项目
`ln -s ~/桌面/linux/Buildroot/buildroot-2021.02.3 external/buildroot`