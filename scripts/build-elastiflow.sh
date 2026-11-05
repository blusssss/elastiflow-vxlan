#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
base_image="${BASE_IMAGE:-robcowart/elastiflow-logstash:4.0.1}"
output_image="${OUTPUT_IMAGE:-elastiflow-vxlan:4.0.1}"

mkdir -p build
docker run --rm --network none --entrypoint cat "$base_image" \
  /etc/logstash/elastiflow/templates/elastiflow.template.json \
  > build/elastiflow.template.original.json
python3 scripts/merge-template.py \
  build/elastiflow.template.original.json \
  build/elastiflow.template.json
docker build -f Dockerfile.elastiflow \
  --build-arg "BASE_IMAGE=$base_image" \
  -t "$output_image" .
