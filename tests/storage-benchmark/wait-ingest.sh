#!/usr/bin/env bash
# wait-ingest.sh — block (with polling, never a single long wait) until both
# sinks have ingested the expected number of log records, while continuously
# verifying pipeline health so failures surface immediately instead of only at
# the final timeout.
#
# Record-count convergence is the drain signal: the producer emitted exactly N
# records onto Kafka, and both ETL consumer groups (otel-clickhouse /
# otel-opensearch) read the same otlp_logs topic, so ClickHouse rows and
# OpenSearch docs each converge to N when ingestion is complete.
#
# Each poll also scans the three collectors' recent logs for export errors and
# checks whether the ClickHouse server pods have crash-restarted during the run
# (the prime cause of silent loss: the collector reports a successful export
# while ClickHouse drops acknowledged async inserts on a node restart). A STALL
# — data sent but neither sink advancing for several consecutive polls — aborts
# early with diagnostics.
#
# Exit codes: 0 = both sinks reached the target cleanly; 1 = timeout;
#             2 = stalled; 3 = reached target but pipeline errors were observed.
#
# Usage: wait-ingest.sh <expected-records> [timeout-seconds] [poll-interval]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

EXPECTED="${1:?usage: wait-ingest.sh <expected-records> [timeout] [interval]}"
TIMEOUT="${2:-900}"
INTERVAL="${3:-5}"
# Abort if neither sink makes progress for this many consecutive polls.
: "${STALL_POLLS:=8}"

bench_init

start=$(date +%s)
baseline_restarts="$(ch_server_restarts)"
log "Health baseline: ClickHouse server restarts=$baseline_restarts"

prev_total=-1
stall=0
issues_seen=0
ch=0; os=0

while :; do
  now=$(date +%s)
  elapsed=$(( now - start ))
  since="$(( elapsed > 10 ? elapsed : 10 ))s"

  ch="$(ch_logs_count || echo 0)"; ch="${ch:-0}"
  os="$(os_logs_count || echo 0)"; os="${os:-0}"
  total=$(( ch + os ))
  log "ingested  ClickHouse=$ch/$EXPECTED  OpenSearch=$os/$EXPECTED"

  # Periodic error verification.
  if ! check_pipeline_health "$since" "$baseline_restarts"; then
    issues_seen=1
  fi

  # Success: both sinks reached the target.
  if [[ "$ch" -ge "$EXPECTED" && "$os" -ge "$EXPECTED" ]]; then
    if [[ "$issues_seen" -eq 1 ]]; then
      warn "Both sinks reached the target, but pipeline errors were observed during the run"
      exit 3
    fi
    log "Both sinks reached the expected record count"
    exit 0
  fi

  # Stall detection: no forward progress for STALL_POLLS consecutive polls.
  if [[ "$total" -le "$prev_total" ]]; then
    stall=$(( stall + 1 ))
  else
    stall=0
  fi
  prev_total="$total"
  if [[ "$stall" -ge "$STALL_POLLS" ]]; then
    warn "STALLED: no ingestion progress for $stall polls (ClickHouse=$ch, OpenSearch=$os, expected=$EXPECTED)"
    warn "Diagnostics:"
    check_pipeline_health "$since" "$baseline_restarts" || true
    cur="$(ch_server_restarts)"
    warn "  ClickHouse server restarts now=$cur (baseline=$baseline_restarts)"
    if [[ "$ch" -lt "$EXPECTED" && "$os" -ge "$EXPECTED" ]]; then
      warn "  Only ClickHouse is behind — likely async-insert loss from a CH node crash-restart,"
      warn "  or a stuck CH ETL collector. Try: kubectl -n $OTEL_NS rollout restart deploy/my-collector-ch-collector"
    fi
    exit 2
  fi

  if [[ "$now" -ge "$(( start + TIMEOUT ))" ]]; then
    warn "TIMEOUT after ${TIMEOUT}s (ClickHouse=$ch, OpenSearch=$os, expected=$EXPECTED)"
    check_pipeline_health "$since" "$baseline_restarts" || true
    exit 1
  fi
  sleep "$INTERVAL"
done
