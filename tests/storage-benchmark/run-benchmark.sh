#!/usr/bin/env bash
# run-benchmark.sh — one-command, reproducible storage benchmark.
#
# Pipeline: reset both sinks -> port-forward the OTLP producer collector ->
# stream a deterministic ~100 MB log corpus -> wait until both sinks have
# ingested every record -> compact -> measure -> write results/<ts>-<label>.json.
#
# Because the corpus is seeded and byte-identical, two runs that differ only in a
# ClickHouse/OpenSearch config setting are directly comparable with compare.sh.
#
# Examples:
#   ./run-benchmark.sh --label baseline
#   ./run-benchmark.sh --label zstd3 --target-bytes $((100*1024*1024))
#   ./run-benchmark.sh --label quick --target-bytes $((5*1024*1024)) --seed 1234
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

LABEL="baseline"
TARGET_BYTES=$((100 * 1024 * 1024))
SEED=1234
BATCH_RECORDS=1500
SKIP_RESET=0
INGEST_TIMEOUT=900
ENDPOINT=""   # if set, skip port-forward and send here directly

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)         LABEL="$2"; shift 2;;
    --target-bytes)  TARGET_BYTES="$2"; shift 2;;
    --seed)          SEED="$2"; shift 2;;
    --batch-records) BATCH_RECORDS="$2"; shift 2;;
    --ingest-timeout) INGEST_TIMEOUT="$2"; shift 2;;
    --endpoint)      ENDPOINT="$2"; shift 2;;
    --skip-reset)    SKIP_RESET=1; shift;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

command -v python3 >/dev/null || die "python3 not found on PATH"
python3 -c 'import requests' 2>/dev/null \
  || die "python 'requests' missing — run: pip install -r requirements.txt"

PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

# 0. Preflight: confirm the pipeline isn't already broken before we send. ------
log "STEP 0/5  preflight health check"
bench_init
baseline_restarts="$(ch_server_restarts)"
if ! check_pipeline_health "5m" "$baseline_restarts"; then
  warn "Preflight found pre-existing pipeline errors (above) — results may be unreliable"
fi
log "  ClickHouse server restart count = $baseline_restarts (a jump during the run signals async-insert loss)"

# 1. Reset to an empty baseline ------------------------------------------------
if [[ "$SKIP_RESET" -eq 0 ]]; then
  log "STEP 1/5  reset sinks"
  ./reset.sh
else
  log "STEP 1/5  reset skipped (--skip-reset)"
fi

# 2. Port-forward the OTLP producer collector ---------------------------------
if [[ -z "$ENDPOINT" ]]; then
  log "STEP 2/5  port-forward svc/$OTEL_COLLECTOR_SVC $LOCAL_OTLP_PORT:$OTLP_HTTP_PORT (ns/$OTEL_NS)"
  kubectl -n "$OTEL_NS" port-forward "svc/$OTEL_COLLECTOR_SVC" \
    "$LOCAL_OTLP_PORT:$OTLP_HTTP_PORT" >/tmp/storage-bench-pf.log 2>&1 &
  PF_PID=$!
  ENDPOINT="http://localhost:${LOCAL_OTLP_PORT}/v1/logs"
  for _ in $(seq 1 20); do
    (exec 3<>"/dev/tcp/localhost/${LOCAL_OTLP_PORT}") 2>/dev/null && { exec 3>&- 3<&-; break; }
    sleep 0.5
  done
  (exec 3<>"/dev/tcp/localhost/${LOCAL_OTLP_PORT}") 2>/dev/null && exec 3>&- 3<&- \
    || die "port-forward to $OTEL_COLLECTOR_SVC did not come up (see /tmp/storage-bench-pf.log)"
else
  log "STEP 2/5  using endpoint $ENDPOINT (no port-forward)"
fi

# 3. Generate + send the deterministic corpus ---------------------------------
log "STEP 3/5  send ~$((TARGET_BYTES / 1048576)) MiB (seed=$SEED, batch=$BATCH_RECORDS)"
SUMMARY="$(python3 generate-and-send.py \
  --endpoint "$ENDPOINT" \
  --target-bytes "$TARGET_BYTES" \
  --batch-records "$BATCH_RECORDS" \
  --seed "$SEED")"
SENT_BYTES="$(echo "$SUMMARY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sent_bytes"])')"
RECORDS="$(echo "$SUMMARY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["records"])')"
log "sent $SENT_BYTES bytes / $RECORDS records"

# Stop the port-forward as soon as sending is done.
cleanup; PF_PID=""

# 4. Wait for both sinks to drain (with periodic error verification) ----------
log "STEP 4/5  wait for ingestion to reach $RECORDS records"
ingest_rc=0
./wait-ingest.sh "$RECORDS" "$INGEST_TIMEOUT" || ingest_rc=$?
case "$ingest_rc" in
  0) ;;
  2) warn "ingestion STALLED (see diagnostics above) — measuring partial state" ;;
  3) warn "ingestion reached target but pipeline errors were observed (see above)" ;;
  *) warn "ingestion did not converge before timeout — measuring partial state" ;;
esac

# 5. Compact + measure ---------------------------------------------------------
log "STEP 5/5  compact + measure"
./compact.sh
OUT="$(./measure.sh --label "$LABEL" --sent-bytes "$SENT_BYTES" \
  --records "$RECORDS" --target-bytes "$TARGET_BYTES" --seed "$SEED")"

if [[ "$ingest_rc" -ne 0 ]]; then
  warn "Benchmark FINISHED WITH ISSUES (ingest exit=$ingest_rc) -> $OUT"
  warn "Treat the storage numbers as a partial/failed run, not a clean comparison."
  exit "$ingest_rc"
fi
log "Benchmark complete -> $OUT"
