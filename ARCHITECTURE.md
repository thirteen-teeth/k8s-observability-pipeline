# K8s Observability Pipeline — Architecture

> This document is the authoritative running description of this repository. It is updated whenever components, configurations, or data flows change.

---

## Purpose

This repository defines a full-stack observability pipeline running on Kubernetes. It ingests **logs**, **traces**, and **metrics** from applications and infrastructure, routes them through a message queue, and stores them in a distributed OLAP database. A Prometheus + Grafana stack provides real-time metric visibility.

The repository supports **two deployment paths**: a **legacy manual path** (apply the root
and `proof-of-concepts/` manifests with `kubectl`/`helm`) and a **GitOps path** (FluxCD
reconciles the pinned copies under `gitops/`). The GitOps path currently covers ClickHouse,
Kafka, the OTel Collector, OpenSearch, and the Prometheus/Grafana monitoring stack (plus
their operators); Fluent Bit and Vector remain manual-only. OpenSearch is provisioned to **benchmark its
on-disk storage footprint against ClickHouse** for the same OTel-sourced events. See
[GitOps Deployment (FluxCD)](#gitops-deployment-fluxcd).

---

## Components

> **Deployment paths:** The component descriptions and **Install Order** below document the
> **legacy manual path** — the manifests at the repo root and under `proof-of-concepts/`,
> applied with `kubectl`/`helm`. The pinned, environment-aware copies under `gitops/` are
> the **current GitOps path**; their versions and image tags live in the
> [GitOps Deployment (FluxCD)](#gitops-deployment-fluxcd) section and may intentionally
> differ from the legacy values here.

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
| `otlp_logs` | OTel Collector | `my-collector-ch` (→ClickHouse) + `my-collector-os` (→OpenSearch) |
| `otlp_traces` | OTel Collector | `my-collector-ch` (→ClickHouse) + `my-collector-os` (→OpenSearch) |
| `vector_logs` | Vector | ClickHouse or downstream consumer |

> In the GitOps path `otlp_logs`/`otlp_traces` are declared `KafkaTopic`s and consumed by
> the two Kafka→sink ETL collectors over SCRAM-authenticated, ACL-scoped connections — see
> [Kafka → sink ETL collectors (GitOps)](#kafka--sink-etl-collectors-gitops).

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

### 7. OpenSearch (Search Engine — disk-usage benchmark)
- **Operator**: [OpenSearch Kubernetes Operator](https://github.com/opensearch-project/opensearch-k8s-operator) — **GitOps-managed only** (versions in the [GitOps Deployment (FluxCD)](#gitops-deployment-fluxcd) section)
- **Namespace**: `search`
- **Purpose**: an alternative document store provisioned to **benchmark on-disk storage
  footprint against ClickHouse** for the same OTel-sourced events.
- **Cluster** (`teeth-search`): 3 dedicated `cluster_manager` (master) nodes + 3 dedicated
  `data` (+ `ingest`) nodes. OpenSearch 3.6.0.
- **Admin credentials**: OpenSearch 3.x's security plugin enforces a password-strength
  regex on `OPENSEARCH_INITIAL_ADMIN_PASSWORD`, and the operator's auto-generated value
  fails it. A compliant secret (`teeth-search-admin-password`, keys `username`/`password`)
  is therefore committed alongside the cluster, SOPS-encrypted exactly like the ClickHouse
  credentials (see [Secrets management](#secrets-management-sops--age)).
- **TLS**: `spec.security.tls.{transport,http}.generate: true` lets the operator issue a
  self-signed CA plus transport/HTTP/admin certs, enable the security plugin, and use HTTPS
  readiness probes. Without it the operator leaves security disabled and probes nodes over
  plain HTTP while the image still serves TLS on 9200, so nodes never become Ready.
- A legacy experimental manifest exists at `proof-of-concepts/search/search.yaml`
  (OpenSearch 2.10.0) and is **not** part of the legacy install order.
- **Fed by** the `my-collector-os` ETL collector (Kafka→OpenSearch, `mapping.mode: ss4o`),
  which writes the same OTLP events to the `ss4o_logs-*` indices that ClickHouse receives —
  so the two stores hold identical data for a like-for-like disk comparison.

> **Disk-usage benchmark:** a reproducible harness lives at `tests/storage-benchmark/`. It
> sends a seeded, size-deterministic OTLP log corpus (default 100 MiB) through the producer
> collector into Kafka, waits for both sinks to ingest it, compacts them, and reports the
> on-disk footprint of ClickHouse vs OpenSearch for the same events. See
> `tests/storage-benchmark/README.md`.

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

> This section describes the **legacy manual path** (`proof-of-concepts/prometheus/monitoring.yaml`
> + `helm install`). The **GitOps path** now runs its own pinned `kube-prometheus-stack`
> with full per-component scraping and provisioned data sources — see
> [Monitoring (Prometheus + Grafana, GitOps)](#monitoring-prometheus--grafana-gitops).

- **Helm Chart**: `prometheus-community/kube-prometheus-stack` (pinned chart version in the **Install Order** install command below)
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
Vector (Pod) ──► FluentForward ───────────────────────────────► Kafka (SCRAM)
                        │                                              │
                        └─ kafka/logs ──────────► topic: otlp_logs    │
                        └─ kafka/traces ─────────► topic: otlp_traces  │
                                                                       │
Vector ─────────────────────────────────────────► topic: vector_logs  │
                                                                       │
                  ┌────────────────────────────────────────────────────┤
                  │ (GitOps ETL collectors consume otlp_logs/otlp_traces)│
                  ▼                                                      ▼
        my-collector-ch (ETL)                            my-collector-os (ETL)
      consumer group otel-clickhouse                   consumer group otel-opensearch
                  │                                                      │
                  ▼                                                      ▼
         ClickHouse Cluster                                    OpenSearch Cluster
      (shards × replicas, ON-CLUSTER                       (teeth-search, ss4o
       ReplicatedMergeTree, db otel)                         index mappings)
      coordinated by CH Keeper

Windows Host (:9877) ─────────────────────────────────► Prometheus (:30090)
Kafka (broker JMX :9404 + Kafka Exporter) ────────────► Prometheus
ClickHouse (server :9363, Keeper :7000) ──────────────► Prometheus
OpenSearch (:9200 /_prometheus/metrics) ──────────────► Prometheus
OTel Collectors (:8888) ──────────────────────────────► Prometheus
node-exporter / kube-state-metrics ───────────────────► Prometheus
                                                                ▼
                                                       Grafana (:30300)
                              data sources: Prometheus, ClickHouse, OpenSearch
```

---

## Namespaces

| Namespace | Components | GitOps-managed? |
|---|---|---|
| `olap` | ClickHouse Cluster, ClickHouse Keeper | Yes |
| `kafka` | Strimzi Kafka Cluster (`teeth-queue`) | Yes |
| `otel` | OpenTelemetry Collectors (OTLP producer + Kafka→ClickHouse/OpenSearch ETLs) + DaemonSet | Yes |
| `search` | OpenSearch Cluster (`teeth-search`) | Yes |
| `logging` | Fluent Bit DaemonSet | No (manual only) |
| `monitoring` | Prometheus operator, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics (kube-prometheus-stack) | Yes |
| `flux-system` | Flux controllers, HelmRepository sources, `sops-age` decryption secret | GitOps path only |

In the GitOps path, the `olap`, `kafka`, `otel`, `search`, and `monitoring` namespaces are
created by Flux (`gitops/infrastructure/namespaces.yaml`); `logging` is created by its
manual install step.

---

## Install Order

> This is the **legacy manual path** (repo root + `proof-of-concepts/` manifests). For the
> pinned, environment-aware GitOps path, see [GitOps Deployment (FluxCD)](#gitops-deployment-fluxcd).

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

## GitOps Deployment (FluxCD)

The pipeline can be deployed declaratively with [FluxCD](https://fluxcd.io/) instead of
the manual `kubectl apply` steps above. All Flux-managed manifests live under `gitops/`
and are **curated copies** of the source manifests (the experimental `proof-of-concepts/`
alternatives are intentionally excluded).

**Scope:** the GitOps path manages the five operator releases and the ClickHouse, Kafka,
OTel Collector, OpenSearch, and Prometheus/Grafana monitoring workloads. Fluent Bit
(`logging`) and Vector are **not** Flux-managed and are still installed via the manual
steps above.

### Layout

```
gitops/
  clusters/
    local/ | dev/ | prod/      # per-environment Flux Kustomizations
      infrastructure.yaml       # Flux Kustomization -> gitops/infrastructure (wait: true)
      apps.yaml                 # Flux Kustomization -> gitops/apps/base (dependsOn: infrastructure)
      cluster-vars.yaml         # ConfigMap of per-env values (postBuild substituteFrom)
  infrastructure/
    namespaces.yaml             # olap, kafka, otel, search, monitoring
    sources/helmrepositories.yaml   # Altinity, Strimzi, OpenTelemetry, OpenSearch, prometheus-community Helm repos
    operators/                  # HelmReleases: clickhouse-operator, strimzi, otel-operator, opensearch-operator,
                                #   kube-prometheus-stack + monitoring-credentials.yaml (SOPS Grafana/datasource creds)
  apps/
    base/                       # single source of truth for all envs (no overlays)
      platform-endpoints.yaml   # ConfigMap of shared cross-app names/namespaces (postBuild substituteFrom)
      clickhouse/               # keeper.yaml, cluster.yaml, secret.yaml,
                                #   scrapeconfigs.yaml (server/keeper Prometheus ScrapeConfigs) (namespace: olap)
      kafka/                    # queue.yaml (Kafka + KafkaNodePool, SCRAM auth + ACLs) + kafka-metrics ConfigMap,
                                #   topics.yaml (KafkaTopics), users.yaml (KafkaUsers),
                                #   podmonitor.yaml (broker + kafka-exporter PodMonitors),
                                #   sasl-users-secret.yaml (SOPS) (namespace: kafka)
      otel/                     # collector.yaml (OTLP -> Kafka producer), collector-clickhouse.yaml +
                                #   collector-opensearch.yaml (Kafka -> sink ETLs),
                                #   podmonitor.yaml (collector :8888 PodMonitor),
                                #   etl-credentials.yaml (SOPS) (namespace: otel)
      opensearch/               # cluster.yaml (OpenSearchCluster, monitoring plugin enabled), admin-secret.yaml (SOPS),
                                #   users.yaml (OpensearchRole/User/RoleBinding),
                                #   etl-user-secret.yaml (SOPS) (namespace: search)
```

> Secrets are encrypted at rest with **SOPS + age** (see *Secrets management* below).
> The age recipient lives in `.sops.yaml`; the private key (`.sops/age.key`) is
> gitignored and never committed.

### Operators (Flux-managed)

Unlike the manual flow (which only installs the ClickHouse operator), Flux installs five
operator `HelmRelease`s (the `kube-prometheus-stack` release bundles the Prometheus
operator):

| Operator | Namespace | Helm repo | Chart version | Notes |
|---|---|---|---|---|
| Altinity ClickHouse operator | `olap` | `https://docs.altinity.com/clickhouse-operator/` | `0.27.1` | Provides ClickHouse(Keeper)Installation CRDs |
| Strimzi Kafka operator | `kafka` | `https://strimzi.io/charts/` | `1.0.0` | KRaft-only (no ZooKeeper); `watchNamespaces: [kafka]` |
| OpenTelemetry operator | `otel` | `https://open-telemetry.github.io/opentelemetry-helm-charts` | `0.115.0` | `autoGenerateCert` enabled (no cert-manager dependency) |
| OpenSearch operator | `search` | `https://opensearch-project.github.io/opensearch-k8s-operator/` | `3.0.2` | Latest operator line (image appVersion `3.0.0-alpha`), targeting OpenSearch 3.x clusters. The chart's validating webhook defaults to a cert-manager-issued cert, so it's disabled via `webhook.enabled: false` (this repo has no cert-manager); the operator still reconciles `OpenSearchCluster` resources without it. |
| kube-prometheus-stack | `monitoring` | `https://prometheus-community.github.io/helm-charts` | `86.2.3` | Bundles the Prometheus operator, Prometheus, Alertmanager, Grafana, node-exporter, and kube-state-metrics. Its `ServiceMonitor`/`PodMonitor`/`ScrapeConfig` CRDs back the per-component monitors under `gitops/apps/base/**`. See [Monitoring (Prometheus + Grafana, GitOps)](#monitoring-prometheus--grafana-gitops). |

All chart versions are **pinned** (no floating ranges) so Flux reconciles deterministically.
Reconciliation order is enforced by `apps` `dependsOn: infrastructure` plus `wait: true`,
so operator CRDs are established before the application CRs are applied.

### Kafka topology (KRaft)

Strimzi `1.0.0` removed ZooKeeper entirely, so the Flux-managed Kafka uses **KRaft**:

- `Kafka` resource (`kafka.strimzi.io/v1`) annotated `strimzi.io/node-pools: enabled` and
  `strimzi.io/kraft: enabled`; Kafka `4.2.0`, `metadataVersion: "4.2"`.
- A single dual-role `KafkaNodePool` (`dual-role`, 3 replicas, roles `controller,broker`)
  owns the JBOD persistent storage (`kraftMetadata: shared`). `spec.kafka.replicas`,
  `spec.kafka.storage`, and `spec.zookeeper` no longer exist.
- JMX Prometheus Exporter still scrapes the brokers via the `kafka-metrics` ConfigMap; the
  former `zookeeper-metrics-config.yml` key was removed.

> Note: the legacy `proof-of-concepts/kafka/queue.yaml` is still the older v1beta2
> ZooKeeper-based manifest and is **not** Flux-managed.

### Kafka authentication & authorization (GitOps)

Unlike the legacy plaintext bus, the Flux-managed Kafka is an authenticated,
least-privilege bus:

- **Authentication:** both listeners (`plain` 9092 / `tls` 9093) require
  **SCRAM-SHA-512**. 9092 is `SASL_PLAINTEXT` (in-cluster only, no transport encryption);
  9093 is SASL over TLS.
- **Authorization:** `spec.kafka.authorization.type: simple` (the built-in ACL authorizer).
  Anything not granted by an ACL is denied. The Strimzi entity operators are listed as
  `superUsers` so they can keep managing topics/users.
- **Topics** (`gitops/apps/base/kafka/topics.yaml`): `otlp_logs` and `otlp_traces` are
  declared as `KafkaTopic` resources (3 partitions, replication 3) so clients need no
  cluster-level topic-create ACL.
- **Users** (`gitops/apps/base/kafka/users.yaml`): three SCRAM `KafkaUser`s, each scoped to
  exactly what it needs. Passwords are supplied (not auto-generated) from the
  SOPS-encrypted `kafka/kafka-etl-user-passwords` Secret so the same values can be mirrored
  into the collectors' namespace.

  | KafkaUser | ACLs | Used by |
  |---|---|---|
  | `otel-producer` | Write+Describe on `otlp_logs`/`otlp_traces`; IdempotentWrite on cluster | `my-collector-kafka` (OTLP producer) |
  | `otel-clickhouse` | Read+Describe on `otlp_logs`/`otlp_traces`; Read on group `otel-clickhouse` | `my-collector-ch` (Kafka→ClickHouse ETL) |
  | `otel-opensearch` | Read+Describe on `otlp_logs`/`otlp_traces`; Read on group `otel-opensearch` | `my-collector-os` (Kafka→OpenSearch ETL) |

### Kafka → sink ETL collectors (GitOps)

Two additional `OpenTelemetryCollector`s (namespace `otel`) consume the OTLP topics off the
Kafka bus and fan them out to the storage sinks. They are independent deployments (separate
consumer groups), so a future S3 or Datadog ETL can be added the same way without touching
the existing ones.

| Collector | File | Consumer group | Exporter | Schema/mapping creation |
|---|---|---|---|---|
| `my-collector-ch` | `otel/collector-clickhouse.yaml` | `otel-clickhouse` | `clickhouse` → `clickhouse-house.olap:9000`, db `otel`, user `otel_writer` | `create_schema: true` with `cluster_name: replicated` + `table_engine: ReplicatedMergeTree` (DDL run `ON CLUSTER`) |
| `my-collector-os` | `otel/collector-opensearch.yaml` | `otel-opensearch` | `opensearch` → `https://teeth-search.search:9200`, user `otel-writer` | `mapping.mode: ss4o` (creates the `ss4o_*` data streams + field mappings on first write) |

Both consume **logs** and **traces** (the only topics that exist). Reusable config is
maximized within the operator's per-collector inline-config constraint: each collector
defines a **single `kafka` receiver** (the 0.154.0 unified receiver carries per-signal topic
config, so one definition feeds both the logs and traces pipelines) plus one canonical
`memory_limiter`+`batch` processor set shared by both pipelines. The receiver/processor
blocks are kept identical across the two collectors; only the exporter, SCRAM identity, and
consumer group differ. The producer `my-collector-kafka` authenticates to Kafka as
`otel-producer` (SCRAM) via its `kafka/logs` and `kafka/traces` exporters.

The producer's `batch` processor is bounded (`send_batch_size: 800`,
`send_batch_max_size: 800`): the Kafka exporter marshals each batch into a single Kafka
record, and the producer rejects records larger than ~1,000,000 bytes
(`MESSAGE_TOO_LARGE`). Without the upper bound an oversized batch is permanently dropped,
so the cap keeps each `otlp_json` record well under the limit.

Both ETL collectors set `message_marking: { after: true, on_error: false }` on the `kafka`
receiver. The receiver default commits a partition offset the moment a message is claimed,
before the pipeline runs — so any downstream drop (the exporter shedding load when its
`sending_queue` fills, `retry_on_failure` exhausting, or a sink restart) loses
already-committed records with no redelivery. Marking the offset only after a successful
export turns that loss into Kafka backpressure and redelivery: under a large backlog (e.g.
the 1 GiB storage benchmark) records stay on the topic until the sink catches up instead of
being silently dropped. The OpenSearch exporter additionally carries a larger
`sending_queue` (`queue_size: 1000`) to absorb indexing bursts before backpressure engages.

The ClickHouse ETL exporter sets `async_insert: false` (the exporter default is `true`).
Synchronous inserts make each batch a queryable, durable part as soon as the insert
returns, so events show in ClickHouse within ~10s (5s batch flush + insert) and are not
lost if a ClickHouse node restarts mid-buffer.

Each collector reads its passwords from pod env (`spec.env` → `secretKeyRef` →
`otel/otel-etl-credentials`) and references them in the inline config as `$${env:VAR}` — the
`$$` escapes Flux's postBuild substitution so the literal `${env:VAR}` reaches the collector
runtime, while platform-endpoint vars (`${clickhouse_service}`, `${search_service}`,
`${kafka_cluster_name}`, …) are still substituted by Flux.

### Sink users & privileges (GitOps)

Each ETL collector authenticates to its sink as a dedicated least-privilege user, not the
admin/root account:

- **ClickHouse** `otel_writer` (`gitops/apps/base/clickhouse/cluster.yaml`): password in
  `olap/clickhouse-credentials` (key `otel_writer_password`); granted DDL/DML on the `otel`
  database only (`CREATE DATABASE`, `CREATE TABLE/VIEW/ALTER/DROP`, `INSERT/SELECT`), plus
  `SELECT` on `system.*` and the `REMOTE`/`CLUSTER` privileges the replicated `ON CLUSTER`
  DDL requires.
- **OpenSearch** `otel-writer`: provisioned declaratively through the operator's security
  CRDs (`gitops/apps/base/opensearch/users.yaml` — `OpensearchRole` + `OpensearchUser` +
  `OpensearchUserRoleBinding`). The role allows only what the `ss4o` exporter needs — manage
  the SS4O index templates and create/write/manage the `ss4o_*`/`otel-*` index families. The
  user's password is read by the operator from the SOPS-encrypted
  `search/opensearch-etl-credentials` Secret and **hashed into the security plugin by the
  operator**, so no password hash is ever committed to Git.

### Resource requests & limits (GitOps)

Every Flux-managed data-plane workload sets CPU/memory requests and limits so pods get a
guaranteed share and a hard ceiling (the kubelet OOM-kills/throttles at the limit). Values
are hardcoded in the manifests (the per-env knobs in `cluster-vars` tune storage/topology
and OpenSearch memory, not these):

| Workload | File | CPU (req → lim) | Memory (req → lim) | Notes |
|---|---|---|---|---|
| ClickHouse server (per pod) | `clickhouse/cluster.yaml` | 500m → 2 | 1Gi → 2Gi | CH caps `max_server_memory_usage` at ~90% of the cgroup limit |
| ClickHouse Keeper (per pod) | `clickhouse/keeper.yaml` | 1 → 2 | 256M → 4Gi | applied only because `spec.defaults.templates.podTemplate` references the pod template (see below) |
| Kafka broker (per pod) | `kafka/queue.yaml` | 250m → 1 | 1Gi → 2Gi | JVM heap pinned to **512 MiB** (`jvmOptions -Xms/-Xmx`) so the rest is page cache |
| Kafka topic/user operators | `kafka/queue.yaml` | 100m → 500m | 256Mi → 512Mi | each `entityOperator` operator |
| Kafka Exporter | `kafka/queue.yaml` | 50m → 250m | 64Mi → 256Mi | |
| OTel collectors (×3) | `otel/collector*.yaml` | 100m → 1 | 256Mi → 2Gi | limit sits above the `memory_limiter` ceiling (1800 MiB + 500 MiB spike) |
| OpenSearch master (per pod) | `opensearch/cluster.yaml` | 250m → 500m | `${opensearch_master_mem}` (req=lim) | operator auto-sizes JVM heap to ~50% of the limit |
| OpenSearch data (per pod) | `opensearch/cluster.yaml` | 500m → 1 | `${opensearch_data_mem}` (req=lim) | operator auto-sizes JVM heap to ~50% of the limit |

The Kafka broker heap is pinned below Strimzi's default (50% of the memory request, capped
at 5Gi) because Kafka leans on the OS page cache rather than the JVM heap; 512 MiB is enough
for this cluster's throughput and leaves the rest of the 2Gi container limit for page cache
and JVM off-heap. JVM heap units (`512m` = 512 MiB) are powers of two, matching the
Kubernetes `Mi`/`Gi` units.

The ClickHouse Keeper pod template only takes effect because
`spec.defaults.templates.podTemplate: default` references it. The Altinity Keeper operator
ignores `spec.templates.podTemplates` unless a `defaults.templates.podTemplate` (or a
per-cluster reference) names it, so without that line the pinned image, topology spread, and
resource requests/limits silently fall back to the operator defaults (`latest` image, no
spread, no limits).

The operator control-plane pods set explicit resources too (the strimzi and OpenSearch
operators already carry their chart defaults and are left as-is):

| Operator | File | Helm values key | CPU (req → lim) | Memory (req → lim) |
|---|---|---|---|---|
| ClickHouse operator | `operators/clickhouse-operator.yaml` | `operator.resources` | 50m → 500m | 128Mi → 256Mi |
| ClickHouse metrics-exporter | `operators/clickhouse-operator.yaml` | `metrics.resources` | 25m → 250m | 64Mi → 128Mi |
| OTel operator | `operators/otel-operator.yaml` | `manager.resources` | 50m → 500m | 128Mi → 256Mi |
| Prometheus operator | `operators/kube-prometheus-stack.yaml` | `prometheusOperator.resources` | 50m → 500m | 128Mi → 256Mi |
| Prometheus config-reloader | `operators/kube-prometheus-stack.yaml` | `prometheusOperator.prometheusConfigReloader.resources` | 25m → 100m | 32Mi → 64Mi |
| Prometheus | `operators/kube-prometheus-stack.yaml` | `prometheus.prometheusSpec.resources` | 100m → 1 | 512Mi → 1536Mi |
| Alertmanager | `operators/kube-prometheus-stack.yaml` | `alertmanager.alertmanagerSpec.resources` | 25m → 250m | 64Mi → 128Mi |
| Grafana | `operators/kube-prometheus-stack.yaml` | `grafana.resources` | 50m → 500m | 128Mi → 384Mi |
| kube-state-metrics | `operators/kube-prometheus-stack.yaml` | `kube-state-metrics.resources` | 25m → 250m | 64Mi → 256Mi |
| node-exporter | `operators/kube-prometheus-stack.yaml` | `prometheus-node-exporter.resources` | 25m → 100m | 32Mi → 64Mi |

### Monitoring (Prometheus + Grafana, GitOps)

The `monitoring` namespace runs the `kube-prometheus-stack` HelmRelease
(`gitops/infrastructure/operators/kube-prometheus-stack.yaml`) — the Prometheus operator,
Prometheus, Alertmanager, Grafana, node-exporter, and kube-state-metrics. Prometheus and
Grafana are exposed as NodePorts (`30090` / `30300`). The Prometheus operator's monitor
selectors discover monitors **cluster-wide** regardless of Helm-release label
(`serviceMonitorSelectorNilUsesHelmValues: false` plus the matching podMonitor / rule /
probe / scrapeConfig flags), so the per-component monitors under `gitops/apps/base/**` are
picked up. Because the `apps` Kustomization `dependsOn: infrastructure` with `wait: true`,
the operator's CRDs exist before those monitors are applied.

Every pipeline component is scraped:

| Component | Mechanism | File | Endpoint |
|---|---|---|---|
| Kafka brokers | `PodMonitor` (JMX exporter, enabled via `queue.yaml` `metricsConfig`) | `kafka/podmonitor.yaml` | port `tcp-prometheus` (9404) |
| Kafka consumer lag | `PodMonitor` for the Kafka Exporter (enabled via `queue.yaml` `spec.kafkaExporter`) | `kafka/podmonitor.yaml` | port `tcp-prometheus` (9404) |
| ClickHouse server | `ScrapeConfig` | `clickhouse/scrapeconfigs.yaml` | pod IP `:9363` `/metrics` |
| ClickHouse Keeper | `ScrapeConfig` | `clickhouse/scrapeconfigs.yaml` | pod IP `:7000` `/metrics` |
| OTel Collectors (×3) | `PodMonitor` (shared operator labels) | `otel/podmonitor.yaml` | port `metrics` (8888) |
| OpenSearch | operator-generated `ServiceMonitor` (`general.monitoring.enable: true`) | `opensearch/cluster.yaml` | `/_prometheus/metrics` on 9200 |

> ClickHouse's native Prometheus ports (server `9363`, Keeper `7000`) are **not** declared as
> container ports by the Altinity operator, so a `PodMonitor`'s `targetPort` would be dropped
> by the Prometheus operator (it keeps only declared container-port numbers). `ScrapeConfig`s
> are used instead: they discover the pods and rewrite `__address__` to the pod IP plus the
> real metrics port. OpenSearch's monitoring plugin version must match the engine version
> exactly; the latest published exporter is `3.6.0.0`, which is why the cluster is pinned to
> OpenSearch 3.6.0.

#### Grafana data sources

Grafana is provisioned with three data sources so the stored telemetry is queryable
alongside the infrastructure metrics. Its admin password and the ClickHouse/OpenSearch
query credentials come from the SOPS-encrypted `monitoring/grafana-credentials` Secret
(injected as env vars and referenced as `$VARS`, never embedded in plaintext):

| Data source | Plugin | Target | Credentials |
|---|---|---|---|
| Prometheus | built-in | in-cluster Prometheus | — (default data source) |
| ClickHouse | `grafana-clickhouse-datasource` | `clickhouse-house.olap:9000` (native), db `otel` | least-privilege `grafana_reader` user (SELECT on `otel.*`/`system.*` only) |
| OpenSearch | `grafana-opensearch-datasource` | `https://teeth-search.search:9200`, index pattern `ss4o_*` | admin user (`tlsSkipVerify` for the operator's self-signed cert) |

> The OpenSearch data source's **config-page health check** reports `Index not found: ss4o_*`
> by design: the plugin (v2.33.1) validates the probe by looking up the literal `database`
> string as a key in the `_mapping` response, which only ever contains concrete index names,
> so any wildcard pattern fails the probe. **Queries work normally** (they use `_search`,
> which expands the wildcard); the broad `ss4o_*` pattern is kept so the data source spans
> every `ss4o_*` log/trace index rather than a single brittle concrete index.

### Pinned images

All image tags in the `gitops/` copies are pinned (no `latest` / floating tags). The
manifests are the source of truth — see them rather than a hand-synced list:

- `gitops/apps/base/otel/collector.yaml` — OTel Collector image
- `gitops/apps/base/clickhouse/cluster.yaml` — ClickHouse server image
- `gitops/apps/base/clickhouse/keeper.yaml` — ClickHouse Keeper image
- `gitops/apps/base/opensearch/cluster.yaml` — OpenSearch version (`general.version`, operator derives the image)

These intentionally differ from the legacy manual manifests (which still use `latest` /
`head-alpine`); see the **Components** section for the legacy values.

### Secrets management (SOPS + age)

Credentials are never stored in plaintext. Each `Secret` is SOPS-encrypted (only `data` /
`stringData`, per `.sops.yaml`) and Flux decrypts it at apply time.

- `gitops/apps/base/clickhouse/secret.yaml` (`olap/clickhouse-credentials`) — the ClickHouse
  `test` user password (key `password`), the ETL `otel_writer` user password (key
  `otel_writer_password`), and the read-only `grafana_reader` user password (key
  `grafana_reader_password`, mirrored into `grafana-credentials`), referenced by the CR via
  `*/k8s_secret_password` lookups.
- `gitops/apps/base/opensearch/admin-secret.yaml` (`search/teeth-search-admin-password`) —
  the OpenSearch initial admin `username`/`password`.
- `gitops/apps/base/opensearch/etl-user-secret.yaml` (`search/opensearch-etl-credentials`) —
  the plaintext `otel_writer` password the OpenSearch operator hashes server-side (no hash
  in Git).
- `gitops/apps/base/kafka/sasl-users-secret.yaml` (`kafka/kafka-etl-user-passwords`) — the
  SCRAM passwords for the `otel-producer`/`otel-clickhouse`/`otel-opensearch` KafkaUsers.
- `gitops/apps/base/otel/etl-credentials.yaml` (`otel/otel-etl-credentials`) — the
  collector-side copies of the Kafka SCRAM, ClickHouse, and OpenSearch passwords, consumed
  by the three collectors via `spec.env` `secretKeyRef`.
- `gitops/infrastructure/operators/monitoring-credentials.yaml` (`monitoring/grafana-credentials`)
  — the Grafana admin password plus the ClickHouse (`grafana_reader`) and OpenSearch query
  credentials used by the provisioned data sources. This Secret lives under
  `gitops/infrastructure`, so the **`infrastructure.yaml` Flux Kustomization also carries
  `decryption`** (in addition to `apps.yaml`).
- Each cluster's `apps.yaml` **and** `infrastructure.yaml` Flux Kustomizations have
  `decryption: { provider: sops, secretRef: { name: sops-age } }`.
- Edit secrets in place with `sops <file>`; never commit a decrypted `Secret`.
- One-time per cluster, create the decryption key secret from the gitignored private key:
  ```bash
  kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=.sops/age.key
  ```

### Environments & Overrides

All three environments reconcile the **same** `gitops/apps/base` — there are no overlays or
per-env patches. Environment differences are expressed as values in a per-cluster
`cluster-vars` ConfigMap (`gitops/clusters/<env>/cluster-vars.yaml`), which the `apps`
Flux Kustomization consumes via `spec.postBuild.substituteFrom`. The base manifests
reference these with `${var:=default}` syntax, so they also build standalone (the default is
the dev-sized value).

The `apps` Kustomization substitutes from **two** ConfigMaps, in order:

1. `platform-endpoints` (`gitops/apps/base/platform-endpoints.yaml`, `optional: true`) —
   the single canonical home for cross-app wiring conventions (service names and
   namespaces). Consumers compose their connection strings from these vars rather than
   hardcoding DNS, e.g. the OTLP producer targets
   `${kafka_cluster_name}-kafka-brokers.${kafka_namespace}.svc.cluster.local:9092`, the
   ClickHouse CR points its keeper nodes at the keeper operator's headless Service
   `${keeper_service}.${olap_namespace}` (`keeper-chk.olap`), and
   the ETL collectors reach their sinks at
   `${clickhouse_service}.${olap_namespace}.svc.cluster.local:9000` and
   `${search_service}.${search_namespace}.svc.cluster.local:9200`.
   Shared by all environments; marked optional so the first reconcile falls back to the
   base-manifest defaults before the ConfigMap exists.
2. `cluster-vars` (`gitops/clusters/<env>/cluster-vars.yaml`) — per-environment values,
   listed second so they win where keys overlap.

The `apps` Kustomization also stamps platform labels on every managed resource via
`spec.commonMetadata.labels` (`app.kubernetes.io/part-of: observability-platform`,
`app.kubernetes.io/managed-by: flux`, and `environment: <env>`) without mutating selectors.

> The Kafka `kafka-metrics` ConfigMap is annotated
> `kustomize.toolkit.fluxcd.io/substitute: disabled` so its JMX exporter `$1`–`$5` regex
> back-references are not touched by variable substitution.

| `cluster-vars` key | local | dev | prod |
|---|---|---|---|
| `keeper_spread_policy` (keeper topology spread `whenUnsatisfiable`) | `ScheduleAnyway` (single-node) | `DoNotSchedule` | `DoNotSchedule` |
| `keeper_data_size` (keeper data PVC at `/var/lib/clickhouse-keeper`) | 1Gi | 10Gi | 50Gi |
| `ch_data_size` / `ch_log_size` | 1Gi / 512Mi | 5Gi / 2Gi | 100Gi / 10Gi |
| `ch_shards_count` / `ch_replicas_count` (ClickHouse layout, total pods = product) | 3 / 1 | 6 / 1 | 6 / 1 |
| `kafka_storage_size` (node-pool JBOD PVC) | 2Gi | 6Gi | 50Gi |
| `opensearch_disk_size` (OpenSearch data-node PVC; 3 data nodes) | 5Gi | 10Gi | 100Gi |
| `opensearch_master_mem` (OpenSearch master memory request=limit; 3 master nodes) | 1Gi | 1Gi | 1Gi |
| `opensearch_data_mem` (OpenSearch data memory request=limit; 3 data nodes) | 1Gi | 2Gi | 2Gi |

### Bootstrap

```bash
# Add your SSH public key as a deploy key with write access in the repo settings first.
flux bootstrap git \
  --url=ssh://git@github.com/thirteen-teeth/k8s-observability-pipeline \
  --branch=main \
  --path=gitops/clusters/local \   # local | dev | prod
  --private-key-file=/path/to/identity
```

---

## Key Ports Reference

| Component | Port | NodePort | Purpose |
|---|---|---|---|
| OTel Collector | 4317 | 30317 | OTLP gRPC |
| OTel Collector | 4318 | 30318 | OTLP HTTP |
| OTel Collector | 24224 | 30225 | FluentForward |
| OTel Collector | 13133 | — | Health check (internal) |
| OTel Collector | 8888 | — | Prometheus metrics (internal) |
| Vector | 24224 | 30224 | FluentForward |
| Vector | 9598 | — | Prometheus metrics (internal) |
| Fluent Bit | 2020 | — | HTTP health/metrics (internal) |
| ClickHouse server | 9363 | — | Prometheus metrics (internal) |
| ClickHouse Keeper | 2181 | — | ZooKeeper TCP (internal) |
| ClickHouse Keeper | 7000 | — | Prometheus metrics (internal) |
| Kafka | 9092 | — | SASL_PLAINTEXT, SCRAM-SHA-512 (internal) |
| Kafka | 9093 | — | SASL over TLS, SCRAM-SHA-512 (internal) |
| Kafka | 9404 | — | JMX Prometheus metrics (internal) |
| OpenSearch | 9200 | — | REST/HTTP API + `/_prometheus/metrics` (internal) |
| OpenSearch | 9300 | — | Transport (internal) |
| Grafana | — | 30300 | NodePort UI |
| Prometheus | — | 30090 | NodePort UI |
| Windows host exporter | 9877 | — | Custom metrics endpoint (host) |
