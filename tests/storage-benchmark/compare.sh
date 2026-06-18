#!/usr/bin/env bash
# compare.sh — diff two benchmark result JSON files side by side.
#
# Usage: compare.sh <baseline.json> <candidate.json>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

[[ $# -eq 2 ]] || { echo "usage: compare.sh <baseline.json> <candidate.json>" >&2; exit 1; }
A="$1"; B="$2"
[[ -f "$A" ]] || { echo "no such file: $A" >&2; exit 1; }
[[ -f "$B" ]] || { echo "no such file: $B" >&2; exit 1; }

A="$A" B="$B" python3 - <<'PY'
import json, os

a = json.load(open(os.environ["A"]))
b = json.load(open(os.environ["B"]))

def mib(n): return n / 1048576 if isinstance(n, (int, float)) else None

def delta(x, y):
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)) or x == 0:
        return ""
    return f"{(y - x) / x * 100:+.1f}%"

la, lb = a.get("label", "A"), b.get("label", "B")
print(f"\n{'metric':<34}{la:>18}{lb:>18}{'Δ':>12}")
print("-" * 82)

def row(label, va, vb, fmt=lambda v: f"{v:,}" if isinstance(v, (int, float)) else str(v)):
    print(f"{label:<34}{fmt(va):>18}{fmt(vb):>18}{delta(va, vb):>12}")

def fmib(v): return f"{mib(v):.2f} MiB" if isinstance(v, (int, float)) else str(v)

ai, bi = a["input"], b["input"]
ac, bc = a["clickhouse"], b["clickhouse"]
ao, bo = a["opensearch"], b["opensearch"]

print("input")
row("  sent", ai["sent_bytes"], bi["sent_bytes"], fmib)
row("  records", ai["records"], bi["records"])
print("clickhouse")
row("  bytes_on_disk", ac["bytes_on_disk"], bc["bytes_on_disk"], fmib)
row("  compression_ratio", ac["compression_ratio"], bc["compression_ratio"])
row("  bytes_per_record", ac["bytes_per_record"], bc["bytes_per_record"])
print("opensearch")
row("  primary_store_bytes", ao["primary_store_bytes"], bo["primary_store_bytes"], fmib)
row("  total_store_bytes", ao["total_store_bytes"], bo["total_store_bytes"], fmib)
row("  bytes_per_doc_primary", ao["bytes_per_doc_primary"], bo["bytes_per_doc_primary"])
row("  index_codec", ao.get("index_codec"), bo.get("index_codec"))
row("  number_of_replicas", ao.get("number_of_replicas"), bo.get("number_of_replicas"))
print("comparison")
row("  ch_disk / os_primary", a["comparison"]["ch_disk_vs_os_primary_ratio"],
    b["comparison"]["ch_disk_vs_os_primary_ratio"])
print()
PY
