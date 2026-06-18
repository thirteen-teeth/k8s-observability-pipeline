#!/usr/bin/env bash
# measure.sh — collect the on-disk storage footprint from both engines and write
# one self-describing JSON result file under results/.
#
# Fairness notes captured in the output:
#   * ClickHouse numbers come from cluster('replicated', system.parts), which
#     reads one replica per shard — i.e. the logical (primary) on-disk size,
#     independent of the replica count.
#   * OpenSearch reports both pri.store.size (primaries only — compare this to
#     ClickHouse) and store.size (primaries + replicas).
# It also snapshots SHOW CREATE TABLE and the OpenSearch index settings so a
# result file records exactly which config produced it.
#
# Usage: measure.sh --label L [--sent-bytes N --records N --target-bytes N --seed N] [--out FILE]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

LABEL="default"; SENT_BYTES=0; RECORDS=0; TARGET_BYTES=0; SEED=0; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)        LABEL="$2"; shift 2;;
    --sent-bytes)   SENT_BYTES="$2"; shift 2;;
    --records)      RECORDS="$2"; shift 2;;
    --target-bytes) TARGET_BYTES="$2"; shift 2;;
    --seed)         SEED="$2"; shift 2;;
    --out)          OUT="$2"; shift 2;;
    *) die "unknown arg: $1";;
  esac
done

bench_init

log "Collecting ClickHouse storage metrics"
ch_row="$(ch_query "SELECT sum(rows), sum(bytes_on_disk), sum(data_compressed_bytes), sum(data_uncompressed_bytes) \
  FROM cluster('$CH_CLUSTER', system.parts) \
  WHERE database='$CH_DB' AND table='$CH_LOGS_TABLE' AND active" 2>/dev/null || echo $'0\t0\t0\t0')"
CH_ROWS="$(echo "$ch_row" | cut -f1)"; CH_ROWS="${CH_ROWS:-0}"
CH_DISK="$(echo "$ch_row" | cut -f2)"; CH_DISK="${CH_DISK:-0}"
CH_COMP="$(echo "$ch_row" | cut -f3)"; CH_COMP="${CH_COMP:-0}"
CH_UNCOMP="$(echo "$ch_row" | cut -f4)"; CH_UNCOMP="${CH_UNCOMP:-0}"
CH_PARTS="$(ch_logs_parts || echo 0)"; CH_PARTS="${CH_PARTS:-0}"
CH_CREATE="$(ch_query "SHOW CREATE TABLE $CH_DB.$CH_LOGS_TABLE" 2>/dev/null || echo '')"

log "Collecting OpenSearch storage metrics"
OS_CAT="$(os_curl GET "/_cat/indices/${OS_LOGS_INDEX_PATTERN}?bytes=b&h=index,docs.count,pri.store.size,store.size&format=json" 2>/dev/null || echo '[]')"
OS_SETTINGS="$(os_curl GET "/${OS_LOGS_INDEX_PATTERN}/_settings" 2>/dev/null || echo '{}')"

mkdir -p results
if [[ -z "$OUT" ]]; then
  OUT="results/$(date +%Y%m%d-%H%M%S)-${LABEL}.json"
fi
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

CH_ROWS="$CH_ROWS" CH_DISK="$CH_DISK" CH_COMP="$CH_COMP" CH_UNCOMP="$CH_UNCOMP" \
CH_PARTS="$CH_PARTS" CH_CREATE="$CH_CREATE" OS_CAT="$OS_CAT" OS_SETTINGS="$OS_SETTINGS" \
LABEL="$LABEL" SENT_BYTES="$SENT_BYTES" RECORDS="$RECORDS" TARGET_BYTES="$TARGET_BYTES" \
SEED="$SEED" GIT_SHA="$GIT_SHA" CH_CLUSTER="$CH_CLUSTER" CH_DB="$CH_DB" \
CH_LOGS_TABLE="$CH_LOGS_TABLE" OS_LOGS_INDEX_PATTERN="$OS_LOGS_INDEX_PATTERN" \
python3 - "$OUT" <<'PY'
import datetime, json, os, sys

def i(name): 
    try: return int(os.environ.get(name, "0") or 0)
    except ValueError: return 0

cat = json.loads(os.environ.get("OS_CAT", "[]") or "[]")
os_docs = sum(int(r.get("docs.count") or 0) for r in cat)
os_pri  = sum(int(r.get("pri.store.size") or 0) for r in cat)
os_store= sum(int(r.get("store.size") or 0) for r in cat)
os_settings = json.loads(os.environ.get("OS_SETTINGS", "{}") or "{}")

# Pull a few load-bearing index settings from the first matched index.
codec = shards = replicas = None
for idx, blob in os_settings.items():
    s = (blob.get("settings", {}) or {}).get("index", {}) or {}
    codec = s.get("codec", "default")
    shards = s.get("number_of_shards")
    replicas = s.get("number_of_replicas")
    break

ch_disk, ch_comp, ch_uncomp, ch_rows = i("CH_DISK"), i("CH_COMP"), i("CH_UNCOMP"), i("CH_ROWS")
records = i("RECORDS")

def ratio(a, b): return round(a / b, 4) if b else None

result = {
    "label": os.environ["LABEL"],
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "git_sha": os.environ.get("GIT_SHA", "unknown"),
    "input": {
        "target_bytes": i("TARGET_BYTES"),
        "sent_bytes": i("SENT_BYTES"),
        "records": records,
        "seed": i("SEED"),
    },
    "clickhouse": {
        "table": f'{os.environ["CH_DB"]}.{os.environ["CH_LOGS_TABLE"]}',
        "cluster": os.environ["CH_CLUSTER"],
        "rows": ch_rows,
        "active_parts": i("CH_PARTS"),
        "bytes_on_disk": ch_disk,
        "data_compressed_bytes": ch_comp,
        "data_uncompressed_bytes": ch_uncomp,
        "compression_ratio": ratio(ch_uncomp, ch_comp),
        "bytes_per_record": ratio(ch_disk, ch_rows),
        "show_create_table": os.environ.get("CH_CREATE", ""),
    },
    "opensearch": {
        "index_pattern": os.environ["OS_LOGS_INDEX_PATTERN"],
        "docs": os_docs,
        "primary_store_bytes": os_pri,
        "total_store_bytes": os_store,
        "bytes_per_doc_primary": ratio(os_pri, os_docs),
        "index_codec": codec,
        "number_of_shards": shards,
        "number_of_replicas": replicas,
    },
    "comparison": {
        # ClickHouse on-disk vs OpenSearch primaries — the apples-to-apples
        # engine-efficiency number (both exclude replication).
        "ch_disk_vs_os_primary_ratio": ratio(ch_disk, os_pri),
        "ch_bytes_per_record": ratio(ch_disk, ch_rows),
        "os_primary_bytes_per_doc": ratio(os_pri, os_docs),
    },
}

out = sys.argv[1]
with open(out, "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")

# Human-readable summary to stderr.
def mib(n): return f"{n / 1048576:.2f} MiB"
ch, osd, cmp = result["clickhouse"], result["opensearch"], result["comparison"]
print(f"\n  Result written to {out}", file=sys.stderr)
print(f"  ── input:      {mib(result['input']['sent_bytes'])} sent, {records:,} records", file=sys.stderr)
print(f"  ── ClickHouse: {mib(ch['bytes_on_disk'])} on disk  "
      f"({ch['rows']:,} rows, ratio {ch['compression_ratio']}x, {ch['bytes_per_record']} B/row)", file=sys.stderr)
print(f"  ── OpenSearch: {mib(osd['primary_store_bytes'])} primary / {mib(osd['total_store_bytes'])} total  "
      f"({osd['docs']:,} docs, {osd['bytes_per_doc_primary']} B/doc, codec={osd['index_codec']}, "
      f"replicas={osd['number_of_replicas']})", file=sys.stderr)
print(f"  ── CH disk / OS primary = {cmp['ch_disk_vs_os_primary_ratio']}", file=sys.stderr)
PY

echo "$OUT"
