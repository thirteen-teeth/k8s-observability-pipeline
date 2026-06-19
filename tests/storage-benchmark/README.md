# Storage Benchmark — ClickHouse vs OpenSearch

Reproducible automation to measure the **on-disk storage footprint** of ingesting
a fixed log corpus (default **100 MiB**) into both ClickHouse and OpenSearch through
the existing pipeline, so different engine/index configurations can be compared
apples-to-apples.

## How it works

A single push feeds both sinks. The deterministic generator sends OTLP logs to the
producer collector (`my-collector-kafka`), which puts them on the Kafka `otlp_logs`
topic; the two ETL collectors (`my-collector-ch`, `my-collector-os`) consume the
**same** records into ClickHouse (`otel.otel_logs`) and OpenSearch (`ss4o_logs-*`).

```
generate-and-send.py ──OTLP──► my-collector-kafka ──► Kafka(otlp_logs) ──┬─► my-collector-ch ─► ClickHouse otel.otel_logs
        (seeded, fixed size)                                              └─► my-collector-os ─► OpenSearch ss4o_logs-*
```

The corpus is **seeded and size-deterministic** (fixed seed => identical record
count, shape, and on-the-wire byte size), so a re-run with a changed config setting
isolates that setting's storage impact. Record **timestamps** are anchored to the
current wall clock (epoch-nanosecond values are always 19 digits, so the byte size is
unchanged) — this keeps them inside the ClickHouse logs-table TTL (`720h`). Using a
fixed historic base time would put every record decades past the TTL, so the first TTL
merge would silently delete all rows in ClickHouse (OpenSearch has no TTL and would
keep them), making the comparison meaningless. Pass `--base-time-ns` for a fully
reproducible corpus, keeping the value within the TTL window.

### "100 MB of logs"
Defined as the cumulative size of the OTLP/JSON request bodies sent on the wire
(`--target-bytes`, default `100 * 1024 * 1024`). The exact bytes and record count are
recorded in every result file.

## Prerequisites

- The GitOps pipeline is deployed and healthy (`olap`, `kafka`, `otel`, `search`).
- `kubectl` context points at the target cluster.
- Python 3 with `requests`: `pip install -r requirements.txt`.

## Run

```bash
pip install -r requirements.txt          # once

./run-benchmark.sh --label baseline      # full 100 MiB run
./run-benchmark.sh --label quick --target-bytes $((5*1024*1024))   # fast smoke test
```

`run-benchmark.sh` performs: **reset → port-forward → send → wait-for-ingest →
compact → measure**, then writes `results/<timestamp>-<label>.json`.

### Large corpora (≥ 1 GiB)

Indexing into the single-shard OpenSearch `ss4o_logs-*` data stream is the slowest
stage, so a 1 GiB run (~1.5M records) takes longer than the default
`--ingest-timeout` (900 s) to drain. Give it more time so `wait-ingest.sh` doesn't
abort before OpenSearch catches up:

```bash
./run-benchmark.sh --label gigabyte --target-bytes $((1024*1024*1024)) --ingest-timeout 1800
```

The ETL collectors mark Kafka offsets only after a successful export
(`message_marking.after: true`), so when OpenSearch falls behind the records stay on
the topic and are redelivered rather than dropped — the run converges to the full
count instead of losing ~10% of OpenSearch docs. It just needs enough time.

### Compare two runs

```bash
./compare.sh results/20260617-101500-baseline.json results/20260617-True.json
```

## Comparing configuration settings

1. Capture a baseline: `./run-benchmark.sh --label baseline`.
2. Change **one** knob in the GitOps manifests and deploy it (commit + push to `main`;
   Flux reconciles). Examples:
   - **ClickHouse** — column codecs / `ORDER BY` / partitioning on `otel.otel_logs`
     (the clickhouse exporter creates the table; override via exporter settings or a
     post-create `ALTER`).
   - **OpenSearch** — `index.codec: best_compression`, `number_of_replicas`,
     or ss4o template field mappings.
3. Re-run with a new label: `./run-benchmark.sh --label <change>`.
4. `./compare.sh results/<baseline>.json results/<change>.json`.

Because the corpus is identical across runs, the storage delta is attributable to the
config change.

## Fairness notes (read before interpreting numbers)

- **ClickHouse** figures come from `cluster('replicated', system.parts)`, which reads
  **one replica per shard** — the logical/primary on-disk size, independent of the
  ClickHouse replica count.
- **OpenSearch** reports both `primary_store_bytes` (primaries only — compare this to
  ClickHouse) and `total_store_bytes` (primaries + replicas). The local env's ss4o
  indices default to 1 replica, so total ≈ 2× primary.
- For an engine-efficiency comparison use **ClickHouse `bytes_on_disk` vs OpenSearch
  `primary_store_bytes`** (`comparison.ch_disk_vs_os_primary_ratio`).

## ClickHouse compaction (optional precision)

`compact.sh` runs `OPTIMIZE TABLE ... FINAL` for the cleanest, fully-merged numbers,
but the least-privilege `otel_writer` ETL user lacks the `OPTIMIZE` grant, so it falls
back to a **settle-wait** (polls `system.parts` until background merges quiesce). For
deterministic full merges, run the harness as a ClickHouse user with
`GRANT OPTIMIZE ON otel.*` (set `CH_USER`/`CH_PW_KEY` to that user's secret key).

## Files

| File | Role |
|---|---|
| `run-benchmark.sh` | Orchestrator (reset → send → wait → compact → measure) |
| `generate-and-send.py` | Deterministic OTLP log generator + sender |
| `reset.sh` | Empty both sinks (ClickHouse `ALTER … DELETE`, OpenSearch index delete) |
| `wait-ingest.sh` | Poll until both sinks reach the expected record count |
| `compact.sh` | OpenSearch flush/forcemerge/refresh; ClickHouse OPTIMIZE or settle-wait |
| `measure.sh` | Collect metrics + config snapshots → `results/<ts>-<label>.json` |
| `compare.sh` | Side-by-side diff of two result files |
| `lib.sh` | Shared config + `kubectl` exec helpers (override any `:=` var via env) |

## Overriding targets (other environments)

Every handle in `lib.sh` is environment-overridable, e.g.:

```bash
OLAP_NS=olap SEARCH_NS=search OTEL_NS=otel ./run-benchmark.sh --label dev
```
