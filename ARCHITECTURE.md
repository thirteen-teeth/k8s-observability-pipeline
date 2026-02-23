# K8s Observability Pipeline — Architecture

> This document is the authoritative running description of this repository. It is updated whenever components, configurations, or data flows change.

---

## Purpose

This repository defines a full-stack observability pipeline running on Kubernetes. It ingests **logs**, **traces**, and **metrics** from applications and infrastructure, routes them through a message queue, and stores them in a distributed OLAP database. A Prometheus + Grafana stack provides real-time metric visibility.

---

## Components

### 1. ClickHouse (OLAP Storage)
- **Operator**: [Altinity ClickHouse Operator](https://github.com/Altinity/clickhouse-operator) — installed via `clickhouse-operator-install.yaml`
- **Namespace**: `olap`
- **Cluster** (`clickhouse-cluster.yaml`):
  - 2 shards × 2 replicas (4 pods total)
  - Image: `clickhouse/clickhouse-server:23.3.8.21`
  - Storage: 5Gi data + 2Gi logs per pod via PVCs
  - User: `test` / `qwerty` with full grants on all IPs
- **ClickHouse Keeper** (`clickhouse-keeper.yaml`):
  - ZooKeeper-compatible consensus layer for replication coordination
  - 3 replicas (`chk-0..2`) in namespace `olap`
  - DNS alias: `zookeeper.olap.svc` on port `2181`
  - Prometheus metrics exposed on port `7000` at `/metrics`
  - Image: `clickhouse/clickhouse-keeper:head-alpine`

#### Schema (`clickhouse-tables/`)
Two variants are maintained:

| Directory | Purpose |
|---|---|
| `clickhouse-exporter-originals/` | Original single-node schema |
| `replicated-cluster-sql/` | Replicated schema for the 2-shard/2-replica cluster |

Tables: `logs`, `traces`, `histogram_metrics`, `summary_metrics` — all keyed for OTLP-shaped data.

---

### 2. Kafka (Message Queue)
- **Operator**: [Strimzi](https://strimzi.io/)
- **Namespace**: `kafka`
- **Cluster** (`proof-of-concepts/kafka/queue.yaml`): `teeth-queue`
  - 3 brokers, Kafka 3.6.0
  - Internal plaintext listener: `teeth-queue-kafka-brokers.kafka.svc.cluster.local:9092`
  - Internal TLS listener on port `9093`
  - Replication factor: 3, min ISR: 2
  - Storage: 6Gi JBOD per broker
  - ZooKeeper: 3 replicas, 1Gi storage each

#### Topics
| Topic | Producer | Consumer (intended) |
|---|---|---|
| `otlp_logs` | OTel Collector | ClickHouse or downstream consumer |
| `otlp_traces` | OTel Collector | ClickHouse or downstream consumer |
| `vector_logs` | Vector | ClickHouse or downstream consumer |

#### Metrics
- JMX Prometheus Exporter enabled on both Kafka brokers and ZooKeeper via `kafka-metrics` ConfigMap
- Scraped by Prometheus via `queue-service-monitor.yaml`

---

### 3. OpenTelemetry Collector
- **Operator**: [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator)
- **Namespace**: `otel`
- **Image**: `otel/opentelemetry-collector-contrib:latest`

#### Deployment Mode (`otel-deployment-kafka.yaml`) — primary
Receives signals from applications and ships to Kafka:

| Receiver | Protocol | Port | NodePort |
|---|---|---|---|
| `fluentforward` | Fluent protocol | `24224` | `30225` |
| `otlp` | gRPC | `4317` | `30317` |
| `otlp` | HTTP | `4318` | `30318` |

NodePort service defined in `otel-nodeport-service.yaml` — supplements the ClusterIP service auto-created by the OTel Operator.

Processors: `batch` (1000/5s), `memory_limiter` (1800MiB), `resourcedetection/system`, `resource` (upserts `service.name`)

Exporters:
- `kafka/logs` → topic `otlp_logs`
- `kafka/traces` → topic `otlp_traces`

Extensions: `health_check` (13133), `pprof` (1777), `zpages` (55679)

#### DaemonSet Mode (`otel-daemonset.yaml`) — WIP
- Collects pod logs directly from `/var/log/pods` on each node
- Supports CRI-O, containerd, and Docker log formats via regex routing
- Not yet fully wired to an exporter

#### Other Collector Configs (alternatives/experiments)
| File | Exporter |
|---|---|
| `otel-deployment-datadog.yaml` | Datadog |
| `otel-deployment-opensearch.yaml` | OpenSearch |
| `otel-deployment-elasticsearch.yaml` | Elasticsearch |
| `otel-deployment-small-house.yaml` | ClickHouse (direct) |

---

### 4. Fluent Bit (Node Log Collector)
- **Mode**: DaemonSet
- **Namespace**: `logging`
- **Config** (`fluent-bit-configmap.yaml`):
  - Input: `tail` on `/var/log/containers/*.log` with Docker parser
  - Filter: Kubernetes metadata enrichment (`Kube_URL`, CA, token)
  - Output: `stdout` (JSON lines) — intended to be forwarded to OTel Collector or Vector
  - HTTP server on port `2020` for health/metrics
- RBAC: `fluent-bit-account.yml` defines ServiceAccount + ClusterRole

---

### 5. Vector (Alternative Log Aggregator)
- **Mode**: Single Pod (not DaemonSet)
- **Namespace**: varies (applied directly)
- **Config** (`vector-complete.yaml`):
  - Source: `fluent` listener on port `24224`
  - Transform: `remap` — adds `@timestamp`, attempts JSON parse of `.message`
  - Sinks:
    - `kafka_sink` → topic `vector_logs` on `teeth-queue-kafka-brokers.kafka.svc.cluster.local:9092`, JSON encoded
    - `prometheus_exporter` → exposes internal Vector metrics at port `9598`
  - Service: **NodePort** — FluentForward on port `24224` / nodePort `30224`; metrics on `9598` (ClusterIP only)
  - ServiceMonitor: `vector-server-monitor` with label `release: my-monitoring` for Prometheus scraping

---

### 6. Prometheus + Grafana (Metrics)
- **Helm Chart**: `prometheus-community/kube-prometheus-stack` version `79.0.0`
- **Release name**: `my-monitoring`
- **Namespace**: `monitoring`
- **Values** (`proof-of-concepts/prometheus/monitoring.yaml`):

```yaml
grafana:
  enabled: true
  service:
    type: NodePort
    nodePort: 30300       # Grafana UI accessible at http://localhost:30300
prometheus:
  service:
    type: NodePort
    nodePort: 30090       # Prometheus UI accessible at http://localhost:30090
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: windows-host-metrics   # Scrapes metrics from Windows host machine
        static_configs:
          - targets:
              - host.docker.internal:9877
        metrics_path: /metrics
        scheme: http
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: hostpath
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi
prometheus-node-exporter:
  hostRootFsMount:
    enabled: false
```

**Scrape targets:**
| Target | Source |
|---|---|
| `host.docker.internal:9877/metrics` | Windows host machine (custom exporter) |
| Vector ServiceMonitor | Vector internal metrics (port 9598) |
| Kafka PodMonitor | Kafka JMX metrics |
| ClickHouse Keeper | Internal metrics (port 7000) |

**NodePort exposure:**
- Prometheus UI: `http://localhost:30090`
- Grafana UI: `http://localhost:30300`

---

## Data Flow

```
Applications / Pods
        │
        ├─── OTLP (gRPC/HTTP) ──────────────────────────────────────►┐
        │                                                              │
        └─── FluentForward ──────────► OTel Collector (Deployment) ──►┤
                                                                       │
Fluent Bit (DaemonSet) ──► FluentForward ──────────────────────────►  │
                                                                       ▼
Vector (Pod) ──► FluentForward ────────────────────────────────────► Kafka
                        │                                              │
                        └─ kafka/logs ──────────► topic: otlp_logs    │
                        └─ kafka/traces ─────────► topic: otlp_traces  │
                                                                       │
Vector ─────────────────────────────────────────► topic: vector_logs  │
                                                                       ▼
                                                              ClickHouse Cluster
                                                           (2 shards × 2 replicas)
                                                          coordinated by CH Keeper

Windows Host (:9877) ─────────────────────────────────► Prometheus (:30090)
Vector metrics (:9598) ───────────────────────────────► Prometheus
Kafka JMX ────────────────────────────────────────────► Prometheus
                                                                ▼
                                                            Grafana
```

---

## Namespaces

| Namespace | Components |
|---|---|
| `olap` | ClickHouse Cluster, ClickHouse Keeper |
| `kafka` | Strimzi Kafka Cluster (`teeth-queue`) |
| `otel` | OpenTelemetry Collector (Deployment + DaemonSet) |
| `logging` | Fluent Bit DaemonSet |
| `monitoring` | Prometheus, Grafana (kube-prometheus-stack) |

---

## Install Order

```bash
# 1. ClickHouse Operator
kubectl create namespace olap
kubectl apply -f clickhouse-operator-install.yaml

# 2. ClickHouse Keeper + Cluster
kubectl apply -f clickhouse-keeper.yaml -n olap
kubectl apply -f clickhouse-cluster.yaml -n olap

# 3. Kafka (requires Strimzi operator pre-installed)
kubectl apply -f proof-of-concepts/kafka/queue.yaml -n kafka

# 4. OTel Collector (requires OTel Operator pre-installed)
kubectl apply -f proof-of-concepts/otel-collector/otel-deployment-kafka.yaml -n otel

# 5. Prometheus + Grafana
helm upgrade --install my-monitoring prometheus-community/kube-prometheus-stack \
  --version 79.0.0 \
  -f proof-of-concepts/prometheus/monitoring.yaml \
  --namespace monitoring \
  --create-namespace
```

---

## Key Ports Reference

| Component | Port | NodePort | Purpose |
|---|---|---|---|
| OTel Collector | 4317 | 30317 | OTLP gRPC |
| OTel Collector | 4318 | 30318 | OTLP HTTP |
| OTel Collector | 24224 | 30225 | FluentForward |
| OTel Collector | 13133 | — | Health check (internal) |
| Vector | 24224 | 30224 | FluentForward |
| Vector | 9598 | — | Prometheus metrics (internal) |
| Fluent Bit | 2020 | — | HTTP health/metrics (internal) |
| ClickHouse Keeper | 2181 | — | ZooKeeper TCP (internal) |
| ClickHouse Keeper | 7000 | — | Prometheus metrics (internal) |
| Kafka | 9092 | — | Plaintext (internal) |
| Kafka | 9093 | — | TLS (internal) |
| Grafana | — | 30300 | NodePort UI |
| Prometheus | — | 30090 | NodePort UI |
| Windows host exporter | 9877 | — | Custom metrics endpoint (host) |
