#!/usr/bin/env python3
"""Deterministic OTLP log generator + sender for the storage benchmark.

Generates a size-deterministic corpus of synthetic-but-realistic structured log
records for a given seed and streams them to an OTLP/HTTP `/v1/logs` endpoint
(the producer collector, reached via `kubectl port-forward`). For a fixed seed the
record count, shape, and on-the-wire byte size are identical across runs, so two
runs that differ only in a ClickHouse/OpenSearch *config* setting are directly
comparable. Record timestamps default to the current wall clock (so rows stay
within the ClickHouse TTL); the byte size is unaffected since epoch-nanosecond
timestamps are always 19 digits.

"100 MB of logs" is defined here as the cumulative size of the OTLP/JSON request
bodies put on the wire (`--target-bytes`, default 100 MiB). The exact bytes sent
and record count are printed as a JSON summary on the final stdout line so the
orchestrator can record them.
"""
from __future__ import annotations

import argparse
import json
import sys
import time

try:
    import requests
except ImportError:  # pragma: no cover
    sys.exit("ERROR: the 'requests' package is required — run: pip install -r requirements.txt")

from random import Random

# Record timestamps are anchored to the current wall clock so they fall within
# the ClickHouse logs-table TTL (otel exporter sets ttl: 720h). A fixed historic
# base time would put every record decades past the TTL, so the first TTL merge
# would silently delete all rows in ClickHouse (OpenSearch has no TTL and would
# keep them) — making the storage comparison meaningless. The byte SIZE of a
# record is unaffected (epoch-nanosecond timestamps are always 19 digits), so the
# corpus size stays deterministic for a given seed even though the exact
# timestamp values shift per run. Override with --base-time-ns for a fully
# reproducible corpus (keep it within the TTL window).
DEFAULT_BASE_TIME_NS = None  # resolved at runtime to "now" unless overridden
TIME_STEP_NS = 1_000_000  # 1 ms between consecutive records

SERVICES = [
    ("checkout", "shop"), ("payments", "shop"), ("cart", "shop"),
    ("inventory", "warehouse"), ("shipping", "warehouse"),
    ("auth", "platform"), ("gateway", "platform"), ("search", "platform"),
    ("recommendations", "ml"), ("notifications", "comms"),
]
ENVIRONMENTS = ["production", "staging"]
SEVERITIES = [  # (number, text) — OTLP severity numbers
    (5, "DEBUG"), (9, "INFO"), (9, "INFO"), (9, "INFO"),
    (13, "WARN"), (17, "ERROR"), (21, "FATAL"),
]
METHODS = ["GET", "GET", "GET", "POST", "PUT", "DELETE", "PATCH"]
PATHS = [
    "/api/v1/users/{id}", "/api/v1/orders/{id}", "/api/v1/products/{id}",
    "/api/v1/cart", "/api/v1/checkout", "/healthz", "/metrics",
    "/api/v1/search?q={q}", "/api/v1/recommendations", "/login",
]
STATUS_CODES = [200, 200, 200, 201, 204, 301, 400, 401, 403, 404, 500, 503]
MESSAGES = [
    "request completed",
    "request failed with upstream error",
    "cache miss for key {key}",
    "user session validated",
    "payment authorized for order {id}",
    "inventory reservation succeeded",
    "rate limit exceeded for client",
    "database query executed",
    "retrying connection to downstream service",
    "configuration reloaded from source",
]
REGIONS = ["us-east-1", "us-west-2", "eu-west-1", "ap-southeast-1"]


def _hex(rng: Random, nbytes: int) -> str:
    return "".join("%02x" % rng.getrandbits(8) for _ in range(nbytes))


def make_record(rng: Random, idx: int, base_time_ns: int) -> dict:
    """Build one OTLP logRecord dict. In OTLP/JSON, 64-bit ints are strings."""
    sev_num, sev_text = rng.choice(SEVERITIES)
    method = rng.choice(METHODS)
    path = rng.choice(PATHS).format(id=rng.randint(1, 999999), q="widget", key=rng.randint(1, 9999))
    status = rng.choice(STATUS_CODES)
    duration_ms = rng.randint(1, 4000)
    msg = rng.choice(MESSAGES).format(
        id=rng.randint(1, 999999), key=rng.randint(1, 9999), q="widget")
    ts = base_time_ns + idx * TIME_STEP_NS
    return {
        "timeUnixNano": str(ts),
        "observedTimeUnixNano": str(ts),
        "severityNumber": sev_num,
        "severityText": sev_text,
        "body": {"stringValue": f'{method} {path} -> {status} ({duration_ms}ms): {msg}'},
        "traceId": _hex(rng, 16),
        "spanId": _hex(rng, 8),
        "attributes": [
            {"key": "http.method", "value": {"stringValue": method}},
            {"key": "http.target", "value": {"stringValue": path}},
            {"key": "http.status_code", "value": {"intValue": str(status)}},
            {"key": "http.duration_ms", "value": {"intValue": str(duration_ms)}},
            {"key": "client.address", "value": {"stringValue":
                f"{rng.randint(1,254)}.{rng.randint(0,255)}.{rng.randint(0,255)}.{rng.randint(1,254)}"}},
            {"key": "user.id", "value": {"stringValue": f"user-{rng.randint(1, 50000):05d}"}},
            {"key": "thread.id", "value": {"intValue": str(rng.randint(1, 256))}},
        ],
    }


def make_request_body(rng: Random, start_idx: int, n: int, base_time_ns: int) -> tuple[str, int]:
    """One ExportLogsServiceRequest with n records under a single resource."""
    name, ns = rng.choice(SERVICES)
    resource_attrs = [
        {"key": "service.name", "value": {"stringValue": name}},
        {"key": "service.namespace", "value": {"stringValue": ns}},
        {"key": "deployment.environment", "value": {"stringValue": rng.choice(ENVIRONMENTS)}},
        {"key": "cloud.region", "value": {"stringValue": rng.choice(REGIONS)}},
        {"key": "host.name", "value": {"stringValue": f"{name}-{rng.randint(0, 9)}"}},
        {"key": "k8s.pod.name", "value": {"stringValue": f"{name}-{_hex(rng, 4)}-{_hex(rng, 2)}"}},
    ]
    records = [make_record(rng, start_idx + i, base_time_ns) for i in range(n)]
    body = {
        "resourceLogs": [{
            "resource": {"attributes": resource_attrs},
            "scopeLogs": [{
                "scope": {"name": "benchmark.generator", "version": "1.0.0"},
                "logRecords": records,
            }],
        }]
    }
    return json.dumps(body, separators=(",", ":")), n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--endpoint", default="http://localhost:4318/v1/logs")
    ap.add_argument("--target-bytes", type=int, default=100 * 1024 * 1024,
                    help="stop once cumulative request-body bytes reach this (default 100 MiB)")
    ap.add_argument("--batch-records", type=int, default=1500,
                    help="log records per OTLP request")
    ap.add_argument("--seed", type=int, default=1234,
                    help="RNG seed — identical seed => same corpus size/shape")
    ap.add_argument("--base-time-ns", type=int, default=None,
                    help="epoch-nanosecond base for record timestamps "
                         "(default: now; keep within the ClickHouse TTL window)")
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--max-retries", type=int, default=5)
    args = ap.parse_args()

    base_time_ns = args.base_time_ns if args.base_time_ns is not None else time.time_ns()

    rng = Random(args.seed)
    session = requests.Session()
    headers = {"Content-Type": "application/json"}

    sent_bytes = 0
    records = 0
    reqs = 0
    rejected = 0
    next_mark = 10 * 1024 * 1024

    print(f"Target {args.target_bytes / 1048576:.1f} MiB to {args.endpoint} "
          f"(seed={args.seed}, batch={args.batch_records})", file=sys.stderr)

    while sent_bytes < args.target_bytes:
        body, n = make_request_body(rng, records, args.batch_records, base_time_ns)
        payload = body.encode("utf-8")

        for attempt in range(1, args.max_retries + 1):
            try:
                resp = session.post(args.endpoint, data=payload,
                                    headers=headers, timeout=args.timeout)
                if resp.status_code == 200:
                    try:
                        ps = resp.json().get("partialSuccess") or {}
                        rejected += int(ps.get("rejectedLogRecords", 0) or 0)
                    except ValueError:
                        pass
                    break
                if 400 <= resp.status_code < 500:
                    return _fail(f"server rejected batch (HTTP {resp.status_code}): {resp.text[:300]}")
                raise requests.RequestException(f"HTTP {resp.status_code}")
            except requests.RequestException as exc:
                if attempt == args.max_retries:
                    return _fail(f"giving up after {attempt} attempts: {exc}")
                print(f"  retry {attempt} after error: {exc}", file=sys.stderr)

        sent_bytes += len(payload)
        records += n
        reqs += 1
        if sent_bytes >= next_mark:
            print(f"  sent {sent_bytes / 1048576:6.1f} MiB  "
                  f"{records:,} records  {reqs} requests", file=sys.stderr)
            next_mark += 10 * 1024 * 1024

    if rejected:
        print(f"WARNING: collector reported {rejected} rejected log records", file=sys.stderr)

    summary = {"sent_bytes": sent_bytes, "records": records,
               "requests": reqs, "rejected": rejected, "seed": args.seed}
    print(json.dumps(summary))
    print(f"Done: {sent_bytes / 1048576:.1f} MiB in {records:,} records "
          f"({reqs} requests)", file=sys.stderr)
    return 0


def _fail(msg: str) -> int:
    print(f"ERROR: {msg}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
