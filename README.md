# ElastiFlow VXLAN for sFlow

为 ElastiFlow 4.0.1 的 `logstash-codec-sflow 2.1.3` 增加标准 VXLAN 报文解析，并提供适用于 Kibana 7.8.1 的生产监控仪表盘。面向仍在运行 Logstash 版 ElastiFlow 的环境。

设备向 Logstash 发送 sFlow v5 采样报文。解码器从其中的原始报文头识别 UDP 目的端口 4789、VXLAN I 标志和 VNI，解析内层 Ethernet、IPv4/IPv6、TCP/UDP/ICMP。原有外层字段和采样率估算口径保持不变；新增字段位于 `vxlan.*`。

## 内容

- 标准 VXLAN：VNI、VTEP、内层地址、端口、VLAN 和解析状态。
- 五页 Kibana 仪表盘：总览、VNI 与内层通信、VTEP 与导出设备、协议与服务、解析质量。
- 独立的字段映射、可复现的派生镜像构建脚本，以及原生 `docker` 部署步骤。

## 兼容版本

| 组件 | 版本 |
| --- | --- |
| ElastiFlow Logstash 镜像 | `robcowart/elastiflow-logstash:4.0.1` |
| 底层 Logstash | 7.8.1 |
| sFlow codec | 2.1.3，源码补丁后的插件列表仍显示此版本 |
| Elasticsearch / Kibana | 7.8.1 |
| 已验证的生产 Docker Engine | 1.12.6，使用预先构建并验证的镜像包导入 |

本版解析标准 UDP 4789 VXLAN。非标准端口、VXLAN GBP/GPE、IP 分片重组和设备未采集到的内层头不在支持范围内。采样头建议按设备能力设置为 192 或 256 字节。

## 快速开始

在构建机上运行 `bash scripts/build-image.sh`，然后按照 [手工部署文档](docs/deploy.md)启动 Elasticsearch、Logstash 和 Kibana，并导入 `assets/vxlan-production-7.8.1.ndjson`。不依赖 Docker Compose。

仪表盘中的字节和速率按 sFlow 采样率估算，表示外层帧流量；记录数是采样数，不是连接数。解析成功率只针对识别出 VXLAN 的记录。

## 代码与许可

`plugin/` 基于 Elasticsearch 发布的 `logstash-codec-sflow 2.1.3`，保留其 Apache-2.0 许可和 NOTICE。新增解析器位于 `plugin/lib/logstash/codecs/sflow/vxlan.rb`。本仓库与 ElastiFlow 官方项目无隶属关系。
