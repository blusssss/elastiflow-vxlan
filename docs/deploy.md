# 部署与验证

适用版本：ElastiFlow Logstash 4.0.1、原版 `logstash-codec-sflow 2.1.3`、Elasticsearch/Kibana 7.8.1。部署需要更新 Logstash 镜像与索引模板，并导入 Kibana 图表。原有 sFlow input、ElastiFlow filter、ES/Kibana 容器和数据卷可继续使用。以下均为手工 `docker` 命令，不依赖 Docker Compose。

## 构建

在构建机执行：

```bash
git clone https://github.com/blusssss/elastiflow-vxlan.git
cd elastiflow-vxlan
bash scripts/build-elastiflow.sh
```

脚本需要 Python 3 和可用的 Docker。它从原版镜像导出 ElastiFlow 模板，只合并 `properties.vxlan`，并构建 `elastiflow-vxlan:4.0.1`。Dockerfile 自动查找 2.1.3 插件路径、核验原文件 SHA256；基础镜像插件已有不同修改时会停止。图表包和合并后的模板也内置在镜像中。

镜像构建需要支持在 `FROM` 中使用 `ARG` 的 Docker。旧版 Docker 可运行从构建机导入的镜像。

生产 Docker 较旧或不能拉取镜像时，在构建机导出后拷贝过去：

```bash
docker save -o elastiflow-vxlan.tar elastiflow-vxlan:4.0.1
sha256sum elastiflow-vxlan.tar > SHA256SUMS
```

目标机执行 `sha256sum -c SHA256SUMS`、`docker load -i elastiflow-vxlan.tar`。离线包应先在空镜像仓库的目标 Docker 版本上试导入；某些较新 Docker 的 containerd image store 曾导出过缺层归档，构建机已有镜像缓存会掩盖这个问题。若 ES/Kibana 也需离线部署，请分别准备并验证对应镜像。

## 准备索引模板

先保存现有 Logstash 的启动命令和 `docker inspect`，备份已挂载的模板、pipeline 及 ES 数据。将镜像内的合并模板提取到宿主机，作为持久化配置：

```bash
IMAGE=elastiflow-vxlan:4.0.1
DEPLOY_ROOT=/srv/elastiflow-vxlan
mkdir -p "$DEPLOY_ROOT"
docker run --rm --network none --entrypoint cat "$IMAGE" \
  /opt/elastiflow-vxlan/elastiflow.template.json \
  > "$DEPLOY_ROOT/elastiflow.template.json"
```

如果原容器已经挂载了**定制模板**，应以该模板为源合并 VXLAN 映射，保留原有字段和设置：`python3 scripts/merge-template.py 原模板.json "$DEPLOY_ROOT/elastiflow.template.json"`。先备份原文件。检查宿主机的目录挂载是否覆盖 `/etc/logstash/elastiflow` 或插件目录；被覆盖时镜像内的文件不会生效。

## 切换 Logstash 容器

停止旧 Logstash 后，按**原启动命令**重建容器：将镜像名改为 `elastiflow-vxlan:4.0.1`，并添加或替换下列模板挂载。原有环境变量、端口、网络、pipeline、数据卷和其他挂载保持一致；不要创建新的 Elasticsearch 数据卷。

```bash
-v "$DEPLOY_ROOT/elastiflow.template.json:/etc/logstash/elastiflow/templates/elastiflow.template.json:ro"
```

Logstash 4.0.1 启动时会重新写入 ES 的 ElastiFlow 模板，因此该挂载必须持续保留。一个目标路径只保留一条挂载；原来已有同目标挂载时替换它。启动后确认日志出现 pipeline started 和 sFlow UDP listener started。

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

新镜像中的合并模板用于未来索引；上述 `_mapping` 请求用于已经存在的写入索引。已有同名字段若被映射为冲突类型，需改用新索引。确认实际 output 仍写入 `elastiflow-4.0.1-*`；现场更改了索引名时，图表包中的 index pattern、TSVB 和 Vega 查询也必须一起改。

## 导入 Kibana 图表

仓库的 [`assets/kibana-7.8.1.ndjson`](../assets/kibana-7.8.1.ndjson) 包含 60 个 Saved Objects：五页仪表盘及其全部依赖。若生产主机只有镜像，可从镜像中提取同一文件：

```bash
docker run --rm --network none --entrypoint cat "$IMAGE" \
  /opt/elastiflow-vxlan/kibana-7.8.1.ndjson \
  > "$DEPLOY_ROOT/kibana-7.8.1.ndjson"

KIBANA_URL=http://127.0.0.1:5601
curl --fail -sS -X POST \
  "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
  -H 'kbn-xsrf: elastiflow-vxlan' \
  -F "file=@$DEPLOY_ROOT/kibana-7.8.1.ndjson"
```

确认响应为 `success:true`、导入对象数 60。入口：`$KIBANA_URL/app/kibana#/dashboard/vxlan-overview`。五页分别是流量总览、VNI 与内层通信、VTEP 与导出设备、协议与服务、解析质量。对象使用独立的 `vxlan-*` ID，不覆盖原版 ElastiFlow 仪表盘。首次收到数据后，在 Kibana 的 Index Patterns 中刷新导入的 `elastiflow-4.0.1-*` 字段列表，保留其对象 ID `vxlan-index`。Kibana 启用认证时，按现有访问方式给 curl 加认证参数。

## 验收

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

标准报文应显示 `vxlan.status: ok`、VNI 和内层地址。截断报文会保留已解析出的字段，并给出 `vxlan.reason`。在总览页确认 VNI 和流量，在通信页按 VNI 筛选，在质量页检查异常原因。如果设备只采集解封装后的内层包，就无法从样本恢复 VNI。

回滚时停止新 Logstash 容器，按原启动命令恢复旧镜像与原模板挂载。原有 Elasticsearch、Kibana 和数据卷不需要重建。若回滚到原版 codec，并在 input 中显式设置了 `vxlan_enabled`，需移除此参数。
