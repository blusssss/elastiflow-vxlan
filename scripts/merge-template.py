#!/usr/bin/env python3
"""Add VXLAN fields to an existing ElastiFlow 4.0.1 index template."""
import argparse
import copy
import json
from pathlib import Path


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()

template = json.loads(args.source.read_text())
mapping = json.loads((Path(__file__).resolve().parent.parent / "assets" / "vxlan-mapping.json").read_text())
properties = template["mappings"]["properties"]
vxlan = mapping["properties"]["vxlan"]
if "vxlan" in properties and properties["vxlan"] != vxlan:
    parser.error("The source template already has an incompatible vxlan mapping")
properties["vxlan"] = copy.deepcopy(vxlan)
args.destination.parent.mkdir(parents=True, exist_ok=True)
args.destination.write_text(json.dumps(template, ensure_ascii=False, indent=2) + "\n")
print(args.destination)
