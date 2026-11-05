# 部署与验证

此补丁针对已安装原版 `logstash-codec-sflow 2.1.3` 的 Logstash。只需更换 Logstash 镜像；原有 sFlow input、ElastiFlow filter、Elasticsearch 和 Kibana 可继续使用。

## 构建

在构建机执行：

```bash
git clone https://github.com/blusssss/elastiflow-vxlan.git
cd elastiflow-vxlan
docker build --build-arg BASE_IMAGE=robcowart/elastiflow-logstash:4.0.1 \
  -t logstash-sflow-vxlan:2.1.3 .
```

使用其他基础镜像时，先确认其中装有**未修改过的** 2.1.3 插件。Dockerfile 会自动查找插件路径，并校验原文件。没有匹配路径或校验失败时不会生成镜像。此方式不运行插件安装器，也不改变现有依赖。

镜像构建需要支持在 `FROM` 中使用 `ARG` 的 Docker。旧版 Docker 可运行从构建机导入的镜像。

生产 Docker 较旧或不能拉取镜像时，在构建机导出后拷贝过去：

```bash
docker save -o logstash-sflow-vxlan.tar logstash-sflow-vxlan:2.1.3
sha256sum logstash-sflow-vxlan.tar > SHA256SUMS
```

目标机执行 `sha256sum -c SHA256SUMS`、`docker load -i logstash-sflow-vxlan.tar`。离线包应先在空镜像仓库的目标 Docker 版本上试导入；某些较新 Docker 的 containerd image store 曾导出过缺层归档，构建机已有镜像缓存会掩盖这个问题。

## 切换容器

保存当前 Logstash 容器的启动命令和 `docker inspect`，备份挂载的配置文件。停止旧容器后，按**原启动命令**创建新容器，只把镜像名改为 `logstash-sflow-vxlan:2.1.3`。保留原来的端口、环境变量、网络、pipeline 和数据卷；不要建立新的 Elasticsearch 数据卷。

解码器默认开启，无需让设备向 4789/UDP 发送流量，也无需在 Docker 发布 4789 端口。设备仍向既有 sFlow 接收端口发送数据。采样报文中必须含外层 UDP 4789 和足够的内层头字节。

## 字段映射

解码结果位于根对象 `vxlan` 下，字段定义见 [`assets/vxlan-mapping.json`](../assets/vxlan-mapping.json)。已有 Elasticsearch 索引可以添加映射：

```bash
ES_URL=http://127.0.0.1:9200
INDEX=elastiflow-4.0.1-YYYY.MM.DD  # 改成实际写入索引
curl --fail -sS -X PUT "$ES_URL/$INDEX/_mapping" \
  -H 'Content-Type: application/json' \
  --data-binary @assets/vxlan-mapping.json
```

未来索引还需把 `properties.vxlan` 合并到实际生效的 index template。先备份原模板，只添加这一段映射，保留其他字段和设置。已有同名字段若被映射为冲突类型，需改用新索引。入库后在 Kibana 刷新现有 index pattern 的字段列表。

## 检查

确认 Logstash 日志显示 sFlow UDP listener 已启动，再在 Kibana Dev Tools 查询：

```json
GET elastiflow-4.0.1-*/_search
{
  "size": 5,
  "sort": [{"@timestamp": "desc"}],
  "query": {"exists": {"field": "vxlan.vni"}},
  "_source": ["@timestamp", "vxlan"]
}
```

标准报文应显示 `vxlan.status: ok`、VNI 和内层地址。截断报文会保留已解析出的字段，并给出 `vxlan.reason`。如果设备只采集解封装后的内层包，就无法从样本恢复 VNI。

回滚时停止新 Logstash 容器，按原启动命令恢复旧镜像和配置。原有 Elasticsearch、Kibana 和数据卷不需要重建。
