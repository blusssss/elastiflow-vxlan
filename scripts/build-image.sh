#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build
docker run --rm --network none --entrypoint cat robcowart/elastiflow-logstash:4.0.1 \
  /etc/logstash/elastiflow/templates/elastiflow.template.json > build/elastiflow.template.original.json
rm -f build/elastiflow.template.json
python3 scripts/merge-template.py build/elastiflow.template.original.json build/elastiflow.template.json
docker build -t elastiflow-logstash:4.0.1-vxlan-prod1 .
