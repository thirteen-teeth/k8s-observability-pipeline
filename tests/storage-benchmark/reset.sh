#!/usr/bin/env bash
# reset.sh — return both sinks to an empty baseline before a benchmark run.
#
#   * ClickHouse: ALTER TABLE ... DELETE WHERE 1 (the otel_writer ETL user has
#     ALTER but not TRUNCATE/OPTIMIZE, and this removes all rows synchronously
#     without dropping the table the exporter created via create_schema).
#   * OpenSearch: delete the ss4o_logs-* indices by concrete name (wildcard
#     deletes are blocked by action.destructive_requires_name). The exporter
#     recreates the data stream + mappings on the next write.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh
bench_init

log "Resetting ClickHouse $CH_DB.$CH_LOGS_TABLE (ALTER ... DELETE WHERE 1)"
ch_query "ALTER TABLE $CH_DB.$CH_LOGS_TABLE ON CLUSTER $CH_CLUSTER DELETE WHERE 1 SETTINGS mutations_sync=2" >/dev/null
ch_remaining="$(ch_logs_count)"
[[ "$ch_remaining" == "0" ]] || warn "ClickHouse still reports $ch_remaining rows after delete"

log "Resetting OpenSearch indices matching $OS_LOGS_INDEX_PATTERN"
mapfile -t indices < <(os_logs_indices)
if [[ ${#indices[@]} -eq 0 ]]; then
  log "  no matching OpenSearch indices to delete"
else
  for idx in "${indices[@]}"; do
    [[ -n "$idx" ]] || continue
    log "  deleting index $idx"
    os_curl DELETE "/$idx" >/dev/null
  done
fi
os_remaining="$(os_logs_count)"
[[ "$os_remaining" == "0" ]] || warn "OpenSearch still reports $os_remaining docs after delete"

log "Reset complete (ClickHouse rows=$ch_remaining, OpenSearch docs=$os_remaining)"
