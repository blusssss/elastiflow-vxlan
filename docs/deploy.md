# 手工部署

以下步骤面向单机三容器：ElastiFlow Logstash 4.0.1、Elasticsearch 7.8.1、Kibana 7.8.1。示例使用 sFlow 6343/UDP 和标准 VXLAN 4789。Docker Compose 不参与部署。

## 1. 构建镜像

在有 Python 3、Docker 和基础镜像拉取能力的构建机执行：

```bash
git clone https://github.com/blusssss/elastiflow-vxlan.git
cd elastiflow-vxlan
docker pull robcowart/elastiflow-logstash:4.0.1
bash scripts/build-image.sh
```

脚本从基础镜像导出原始 ElastiFlow 索引模板，只合并 `vxlan` 映射，再构建 `elastiflow-logstash:4.0.1-vxlan-prod1`。构建过程先核对原 codec 文件 SHA256，基础镜像内容不符时会停止。生成的模板在 `build/`，不会提交到仓库。

生产机若不能直接拉取镜像，可在使用经典 Docker image store 的构建机打包三份镜像，并在**空镜像仓库**的目标版本 Docker Engine 上先做一次导入验证：

```bash
docker pull docker.elastic.co/elasticsearch/elasticsearch:7.8.1
docker pull docker.elastic.co/kibana/kibana:7.8.1
docker save -o docker-images.tar \
  elastiflow-logstash:4.0.1-vxlan-prod1 \
  docker.elastic.co/elasticsearch/elasticsearch:7.8.1 \
  docker.elastic.co/kibana/kibana:7.8.1
gzip -1 docker-images.tar
sha256sum docker-images.tar.gz > SHA256SUMS
```

目标机检查并导入：

```bash
sha256sum -c SHA256SUMS
docker load -i docker-images.tar.gz
docker images
```

曾有 Docker 29 containerd image store 导出包缺失 ES/Kibana 层、而本机因已有缓存误判导入成功的情况。仅校验压缩包 SHA256 不能发现这个问题；离线包必须在空镜像仓库验证三份镜像都能导入。生产 Docker 1.12.6 已按此方法验证。

## 2. 准备主机

先备份现有容器启动参数、ES 数据和 Kibana saved objects。以下使用新的 `elastiflow-prod-*` 名称与数据卷，不会迁移旧数据。确认主机内存足以同时运行 ES 4 GiB 堆、Logstash 4 GiB 堆及 Kibana，并确认 6343/UDP 没有被旧采集器占用。

```bash
docker version
sysctl vm.max_map_count
```

Elasticsearch 要求 `vm.max_map_count` 至少为 262144；数值偏小时先调整并在主机配置中持久化。

提取镜像内的运行配置和仪表盘：

```bash
DEPLOY_ROOT=/srv/elastiflow-vxlan
LS_IMAGE=elastiflow-logstash:4.0.1-vxlan-prod1
mkdir -p "$DEPLOY_ROOT/config"
docker run --rm --network none --entrypoint cat "$LS_IMAGE" \
  /opt/elastiflow-deploy/logstash.env.example > "$DEPLOY_ROOT/config/logstash.env"
docker run --rm --network none --entrypoint cat "$LS_IMAGE" \
  /opt/elastiflow-deploy/elastiflow.template.json > "$DEPLOY_ROOT/config/elastiflow.template.json"
docker run --rm --network none --entrypoint cat "$LS_IMAGE" \
  /opt/elastiflow-deploy/vxlan-production-7.8.1.ndjson > "$DEPLOY_ROOT/config/vxlan-production-7.8.1.ndjson"
chmod 600 "$DEPLOY_ROOT/config/logstash.env"
```

按现场资源调整 `logstash.env`。保留 `ELASTIFLOW_ES_HOST=elastiflow-prod-es:9200`，或同步修改下面的网络与容器名。若生产已有定制索引模板，应把 `assets/vxlan-mapping.json` 中的 `properties.vxlan` 合并到实际模板，不要用仓库模板覆盖现场定制。

## 3. 启动三容器

命令使用 Docker 1.12.6 支持的 `-v` 和 `docker volume create --name`。先创建网络和空数据卷：

```bash
docker network create elastiflow-prod-net
docker volume create --name elastiflow-prod-es-data
docker volume create --name elastiflow-prod-logstash-data
```

启动 Elasticsearch：

```bash
docker run -d --name elastiflow-prod-es \
  --restart unless-stopped --network elastiflow-prod-net \
  --memory 8g --ulimit nofile=131072:131072 \
  -p 127.0.0.1:9200:9200 \
  -e discovery.type=single-node -e cluster.name=elastiflow-production \
  -e xpack.security.enabled=false -e 'ES_JAVA_OPTS=-Xms4g -Xmx4g' \
  -e indices.query.bool.max_clause_count=8192 -e search.max_buckets=250000 \
  -v elastiflow-prod-es-data:/usr/share/elasticsearch/data \
  docker.elastic.co/elasticsearch/elasticsearch:7.8.1
curl --fail -sS 'http://127.0.0.1:9200/_cluster/health?wait_for_status=yellow&timeout=60s'
```

确认 ES 为 green 或 yellow 后启动 Logstash：

```bash
docker run -d --name elastiflow-prod-logstash \
  --restart unless-stopped --network elastiflow-prod-net --memory 8g \
  --env-file "$DEPLOY_ROOT/config/logstash.env" -p 6343:6343/udp \
  -v elastiflow-prod-logstash-data:/usr/share/logstash/data \
  -v "$DEPLOY_ROOT/config/elastiflow.template.json:/etc/logstash/elastiflow/templates/elastiflow.template.json:ro" \
  "$LS_IMAGE"
docker logs --tail=100 elastiflow-prod-logstash
```

看到 pipeline started 和 UDP 6343 listener started 后再接入设备。VXLAN 解析默认开启，无需发布 4789 端口。

启动 Kibana：

```bash
docker run -d --name elastiflow-prod-kibana \
  --restart unless-stopped --network elastiflow-prod-net --memory 2g \
  -p 127.0.0.1:5601:5601 \
  -e ELASTICSEARCH_HOSTS=http://elastiflow-prod-es:9200 \
  -e SERVER_HOST=0.0.0.0 -e SERVER_NAME=elastiflow-production \
  -e SERVER_MAXPAYLOADBYTES=8388608 -e XPACK_SECURITY_ENABLED=false \
  -e TELEMETRY_ENABLED=false -e 'NODE_OPTIONS=--max-old-space-size=1024' \
  docker.elastic.co/kibana/kibana:7.8.1
curl --fail -sS http://127.0.0.1:5601/api/status
```

ES 和 Kibana 管理端口仅绑定本机回环。远程管理可使用 SSH 转发。此示例关闭了 Elastic 安全认证，不应把管理端口直接暴露到公网。

## 4. 导入与验收

Kibana 就绪后导入五页仪表盘：

```bash
curl --fail -sS -X POST \
  'http://127.0.0.1:5601/api/saved_objects/_import?overwrite=true' \
  -H 'kbn-xsrf: vxlan-production' \
  -F "file=@$DEPLOY_ROOT/config/vxlan-production-7.8.1.ndjson"
```

确认响应包含 `success:true`；入口为 `/app/kibana#/dashboard/vxlan-prod-overview`。设备将 sFlow 发往生产主机的 6343/UDP，原始采样头需包含外层 UDP 4789 和足够的内层头字节。首次入库后，在 Kibana 的 Index Patterns 中刷新 `elastiflow-4.0.1-*` 字段列表，保留 `vxlan-prod-index` 对象 ID。

在 Kibana Dev Tools 检查：

```json
GET elastiflow-4.0.1-*/_search
{
  "size": 5,
  "sort": [{"@timestamp": "desc"}],
  "query": {"exists": {"field": "vxlan.vni"}},
  "_source": ["@timestamp", "vxlan", "network.bytes"]
}
```

正常记录含 `vxlan.status: ok`、VNI、内层地址及端口。`truncated`、`invalid`、`unsupported` 可在解析质量页检查。设备若只采集解封装后的内层包，无法还原 VNI。

停止新系统时保留数据卷：`docker stop -t 60 elastiflow-prod-logstash elastiflow-prod-kibana elastiflow-prod-es`。回滚时先停止新采集器释放 6343/UDP，再启动原容器。
