#!/usr/bin/env python3
"""Overlay product filter packs in the app bundle without modifying upstream data."""
import json
import pathlib
import sys

base = pathlib.Path(sys.argv[1])
product = pathlib.Path(sys.argv[2])
output = pathlib.Path(sys.argv[3])
merged = json.loads(base.read_text())
for paper, illuminants in json.loads(product.read_text()).items():
    if paper in merged:
        raise ValueError(f"Duplicate print stock in filter packs: {paper}")
    merged[paper] = illuminants
output.write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n")
