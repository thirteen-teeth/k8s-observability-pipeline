#!/usr/bin/env bash
# compact.sh — force both engines into a stable, comparable on-disk state before
# measuring, so storage numbers reflect a fully-merged steady state rather than
# whatever transient segment/part layout exists right after ingest.
#
#   * OpenSearch: _flush, then _forcemerge to a single segment, then _refresh.
#   * ClickHouse: OPTIMIZE TABLE ... FINAL when the user is allowed to (cleanest);
#     the least-privilege otel_writer ETL user lacks the OPTIMIZE grant, so this
#     falls back to a settle-wait that polls system.parts until the active part
#     count stops changing (background merges have quiesced). To always force a
#     full merge, run as a user with `GRANT OPTIMIZE ON otel.*` (see README).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-120}"
SETTLE_INTERVAL="${SETTLE_INTERVAL:-5}"

bench_init

# --- OpenSearch -------------------------------------------------------------
log "OpenSearch: flush + forcemerge(max_num_segments=1) + refresh on $OS_LOGS_INDEX_PATTERN"
os_curl POST "/${OS_LOGS_INDEX_PATTERN}/_flush" >/dev/null 2>&1 || warn "OpenSearch flush returned non-zero"
os_curl POST "/${OS_LOGS_INDEX_PATTERN}/_forcemerge?max_num_segments=1" >/dev/null 2>&1 \
  || warn "OpenSearch forcemerge returned non-zero"
os_curl POST "/${OS_LOGS_INDEX_PATTERN}/_refresh" >/dev/null 2>&1 || warn "OpenSearch refresh returned non-zero"

# --- ClickHouse -------------------------------------------------------------
if ch_query "OPTIMIZE TABLE $CH_DB.$CH_LOGS_TABLE ON CLUSTER $CH_CLUSTER FINAL" >/dev/null 2>&1; then
  log "ClickHouse: OPTIMIZE FINAL completed"
else
  warn "ClickHouse OPTIMIZE not permitted for user $CH_USER — settling via background merges"
  deadline=$(( $(date +%s) + SETTLE_TIMEOUT ))
  prev=-1; stable=0
  while :; do
    cur="$(ch_logs_parts || echo -1)"; cur="${cur:--1}"
    if [[ "$cur" == "$prev" && "$cur" -ge 0 ]]; then
      stable=$((stable + 1))
      [[ "$stable" -ge 2 ]] && { log "ClickHouse part count stable at $cur"; break; }
    else
      stable=0
    fi
    prev="$cur"
    if [[ "$(date +%s)" -ge "$deadline" ]]; then
      warn "ClickHouse merge settle timed out after ${SETTLE_TIMEOUT}s (active parts=$cur)"
      break
    fi
    sleep "$SETTLE_INTERVAL"
  done
fi

log "Compaction complete"
