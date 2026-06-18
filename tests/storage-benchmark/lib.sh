#!/usr/bin/env bash
# lib.sh — shared configuration and helpers for the ClickHouse-vs-OpenSearch
# storage benchmark. Sourced by the other scripts in this directory.
#
# Every value below can be overridden from the environment, so the same harness
# works against the local cluster and the dev/prod GitOps environments (which
# reconcile the same gitops/apps/base manifests). Pods and credentials are
# resolved live from the cluster by bench_init.

set -euo pipefail

# ---------------------------------------------------------------------------
# Tunables (override via environment)
# ---------------------------------------------------------------------------
: "${OLAP_NS:=olap}"                 # ClickHouse namespace
: "${SEARCH_NS:=search}"             # OpenSearch namespace
: "${OTEL_NS:=otel}"                 # OTel collector namespace

# ClickHouse
: "${CH_CHI:=house}"                 # ClickHouseInstallation name (pod label clickhouse.altinity.com/chi)
: "${CH_CLUSTER:=replicated}"        # cluster name used by ON CLUSTER / cluster() queries
: "${CH_DB:=otel}"                   # database the ETL exporter writes to
: "${CH_LOGS_TABLE:=otel_logs}"      # logs table created by the clickhouse exporter
: "${CH_SECRET:=clickhouse-credentials}"
: "${CH_USER:=otel_writer}"          # least-privilege ETL user (has SELECT system.*, REMOTE, CLUSTER, ALTER)
: "${CH_PW_KEY:=otel_writer_password}"
: "${CH_CONTAINER:=clickhouse}"

# OpenSearch
: "${OS_CLUSTER:=teeth-search}"      # OpenSearchCluster name (pod name prefix)
: "${OS_SECRET:=teeth-search-admin-password}"
: "${OS_CONTAINER:=opensearch}"
: "${OS_LOGS_INDEX_PATTERN:=ss4o_logs-*}"  # ss4o data streams the OpenSearch exporter writes logs to

# OTLP ingest (producer collector — ClusterIP only, reached via port-forward)
: "${OTEL_COLLECTOR_SVC:=my-collector-kafka-collector}"
: "${OTLP_HTTP_PORT:=4318}"          # remote OTLP/HTTP port on the collector service
: "${LOCAL_OTLP_PORT:=4318}"         # local port the harness forwards to

# Resolved by bench_init
CH_POD=""
OS_POD=""
CH_PW=""
OS_USER=""
OS_PW=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_ts()   { date +%H:%M:%S; }
log()   { printf '[%s] %s\n' "$(_ts)" "$*" >&2; }
warn()  { printf '[%s] WARN: %s\n' "$(_ts)" "$*" >&2; }
die()   { printf '[%s] ERROR: %s\n' "$(_ts)" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Resolve live pods + credentials. Idempotent.
# ---------------------------------------------------------------------------
bench_init() {
  command -v kubectl >/dev/null || die "kubectl not found on PATH"

  CH_POD="$(kubectl -n "$OLAP_NS" get pods \
    -l "clickhouse.altinity.com/chi=$CH_CHI" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$CH_POD" ]] || die "no ClickHouse pod found in ns/$OLAP_NS (label clickhouse.altinity.com/chi=$CH_CHI)"

  OS_POD="$(kubectl -n "$SEARCH_NS" get pods -o name 2>/dev/null \
    | grep -m1 "${OS_CLUSTER}-masters" | cut -d/ -f2 || true)"
  [[ -n "$OS_POD" ]] || die "no OpenSearch master pod found in ns/$SEARCH_NS (prefix ${OS_CLUSTER}-masters)"

  CH_PW="$(kubectl -n "$OLAP_NS" get secret "$CH_SECRET" \
    -o jsonpath="{.data.$CH_PW_KEY}" 2>/dev/null | base64 -d || true)"
  [[ -n "$CH_PW" ]] || die "could not read ClickHouse password from secret/$CH_SECRET key $CH_PW_KEY"

  OS_USER="$(kubectl -n "$SEARCH_NS" get secret "$OS_SECRET" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)"
  OS_PW="$(kubectl -n "$SEARCH_NS" get secret "$OS_SECRET" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  [[ -n "$OS_USER" && -n "$OS_PW" ]] || die "could not read OpenSearch admin creds from secret/$OS_SECRET"

  log "ClickHouse pod=$CH_POD user=$CH_USER  |  OpenSearch pod=$OS_POD user=$OS_USER"
}

# ---------------------------------------------------------------------------
# ClickHouse: run a query, stdout = result. Default TSV (no column names).
#   ch_query "<sql>" [extra clickhouse-client args...]
# ---------------------------------------------------------------------------
ch_query() {
  local sql="$1"; shift || true
  kubectl -n "$OLAP_NS" exec -i "$CH_POD" -c "$CH_CONTAINER" -- \
    clickhouse-client -u "$CH_USER" --password "$CH_PW" "$@" --query "$sql"
}

# Cluster-wide count of the logs table (deduped to one replica per shard).
ch_logs_count() {
  ch_query "SELECT count() FROM cluster('$CH_CLUSTER', $CH_DB.$CH_LOGS_TABLE)" 2>/dev/null | tr -d '[:space:]'
}

# Number of active parts for the logs table (used by the compaction settle-wait).
ch_logs_parts() {
  ch_query "SELECT count() FROM cluster('$CH_CLUSTER', system.parts) \
    WHERE database='$CH_DB' AND table='$CH_LOGS_TABLE' AND active" 2>/dev/null | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# OpenSearch: curl against the cluster from inside a master pod.
#   os_curl <METHOD> <path-with-leading-slash> [json-body]
# ---------------------------------------------------------------------------
os_curl() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    kubectl -n "$SEARCH_NS" exec -i "$OS_POD" -c "$OS_CONTAINER" -- \
      curl -sk -u "$OS_USER:$OS_PW" -X "$method" \
      "https://localhost:9200${path}" -H 'Content-Type: application/json' -d "$body"
  else
    kubectl -n "$SEARCH_NS" exec -i "$OS_POD" -c "$OS_CONTAINER" -- \
      curl -sk -u "$OS_USER:$OS_PW" -X "$method" "https://localhost:9200${path}"
  fi
}

# Document count across the ss4o logs indices (0 if none exist).
os_logs_count() {
  os_curl GET "/${OS_LOGS_INDEX_PATTERN}/_count" \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("count",0))
except Exception: print(0)'
}

# Concrete index names matching the logs pattern (one per line).
os_logs_indices() {
  os_curl GET "/_cat/indices/${OS_LOGS_INDEX_PATTERN}?h=index&format=json" \
    | python3 -c 'import json,sys
try:
    for r in json.load(sys.stdin): print(r["index"])
except Exception: pass'
}

# ---------------------------------------------------------------------------
# Health / error verification (used by wait-ingest.sh to catch failures while a
# run is in progress instead of only discovering them at the final timeout).
# ---------------------------------------------------------------------------

# Collector deployments whose logs are scanned for export failures.
: "${OTEL_DEPLOYMENTS:=my-collector-kafka-collector my-collector-ch-collector my-collector-os-collector}"

# Log lines that indicate real pipeline failures (Kafka noise filtered out).
: "${ERROR_PATTERN:=Exporting failed|Permanent error|MESSAGE_TOO_LARGE|Dropping data|not retryable|Connection refused|ACCESS_DENIED|Permanent|level=error|	error	}"

# Total restart count across the ClickHouse server pods. A jump during a run
# means a node crash-restarted (the prime cause of silent async-insert loss).
ch_server_restarts() {
  kubectl -n "$OLAP_NS" get pods -l "clickhouse.altinity.com/chi=$CH_CHI" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
    | awk '{s+=$1} END{print s+0}'
}

# Recent error-level lines from one collector deployment (Kafka rebalance noise
# excluded). Args: <deployment> <since, e.g. 60s> [max-lines]
collector_recent_errors() {
  local deploy="$1" since="$2" maxlines="${3:-4}"
  kubectl -n "$OTEL_NS" logs "deploy/$deploy" --since="$since" 2>/dev/null \
    | grep -E -i "$ERROR_PATTERN" \
    | grep -viE 'franz|kzap|heartbeat errored|REBALANCE_IN_PROGRESS' \
    | tail -n "$maxlines"
}

# Scan all collectors + ClickHouse pod restarts for problems since the run
# started. Prints findings to stderr; returns the number of issues found.
# Args: <since, e.g. 90s> <baseline-restart-count>
check_pipeline_health() {
  local since="$1" baseline="$2" issues=0 errs cur
  for d in $OTEL_DEPLOYMENTS; do
    errs="$(collector_recent_errors "$d" "$since" 4)"
    if [[ -n "$errs" ]]; then
      warn "collector $d reported errors:"
      while IFS= read -r line; do printf '         %s\n' "${line:0:200}" >&2; done <<<"$errs"
      issues=$((issues + 1))
    fi
  done
  cur="$(ch_server_restarts)"
  if [[ -n "$cur" && -n "$baseline" && "$cur" -gt "$baseline" ]]; then
    warn "ClickHouse server pods restarted $((cur - baseline)) time(s) during the run \
(crash-restarts cause acknowledged async inserts to be lost)"
    issues=$((issues + 1))
  fi
  return "$issues"
}
