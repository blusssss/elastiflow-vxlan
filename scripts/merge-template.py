#!/usr/bin/env python3
"""Merge VXLAN mappings into an exported ElastiFlow 4.0.1 template file."""
import argparse
import copy
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('original', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
if args.original.resolve() == args.output.resolve():
    parser.error('Use a separate output file; keep the original for rollback.')
template = json.loads(args.original.read_text())
mapping = json.loads((Path(__file__).resolve().parent.parent / 'assets' / 'vxlan-mapping.json').read_text())
properties = template['mappings']['properties']
if 'vxlan' in properties and properties['vxlan'] != mapping['properties']['vxlan']:
    parser.error('The original template already contains a different vxlan mapping.')
properties['vxlan'] = copy.deepcopy(mapping['properties']['vxlan'])
if args.output.exists():
    parser.error('Output already exists; choose a new output filename.')
args.output.write_text(json.dumps(template, ensure_ascii=False, indent=2) + '\n')
print('Wrote merged template:', args.output)
