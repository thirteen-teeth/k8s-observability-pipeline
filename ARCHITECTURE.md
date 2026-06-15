# K8s Observability Pipeline — Architecture

> This document is the authoritative running description of this repository. It is updated whenever components, configurations, or data flows change.

---

## Purpose

This repository defines a full-stack observability pipeline running on Kubernetes. It ingests **logs**, **traces**, and **metrics** from applications and infrastructure, routes them through a message queue, and stores them in a distributed OLAP database. A Prometheus + Grafana stack provides real-time metric visibility.

The repository supports **two deployment paths**: a **legacy manual path** (apply the root
and `proof-of-concepts/` manifests with `kubectl`/`helm`) and a **GitOps path** (FluxCD
reconciles the pinned copies under `gitops/`). The GitOps path currently covers ClickHouse,
Kafka, the OTel Collector, and OpenSearch (plus their operators); Prometheus/Grafana,
Fluent Bit, and Vector remain manual-only. OpenSearch is provisioned to **benchmark its
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

### 7. OpenSearch (Search Engine — disk-usage benchmark)
- **Operator**: [OpenSearch Kubernetes Operator](https://github.com/opensearch-project/opensearch-k8s-operator) — **GitOps-managed only** (versions in the [GitOps Deployment (FluxCD)](#gitops-deployment-fluxcd) section)
- **Namespace**: `search`
- **Purpose**: an alternative document store provisioned to **benchmark on-disk storage
  footprint against ClickHouse** for the same OTel-sourced events.
- **Cluster** (`teeth-search`): 3 dedicated `cluster_manager` (master) nodes + 3 dedicated
  `data` (+ `ingest`) nodes. OpenSearch 3.7.0.
- **Admin credentials**: OpenSearch 3.x's security plugin enforces a password-strength
  regex on `OPENSEARCH_INITIAL_ADMIN_PASSWORD`, and the operator's auto-generated value
  fails it. A compliant secret (`teeth-search-admin-password`, keys `username`/`password`)
  is therefore committed alongside the cluster, mirroring how the ClickHouse credentials are
  stored. It is fine for this throwaway benchmark cluster; rotate/seal it before any
  non-throwaway use.
- **TLS**: `spec.security.tls.{transport,http}.generate: true` lets the operator issue a
  self-signed CA plus transport/HTTP/admin certs, enable the security plugin, and use HTTPS
  readiness probes. Without it the operator leaves security disabled and probes nodes over
  plain HTTP while the image still serves TLS on 9200, so nodes never become Ready.
- A legacy experimental manifest exists at `proof-of-concepts/search/search.yaml`
  (OpenSearch 2.10.0) and is **not** part of the legacy install order.

> **Not yet wired:** the OTel Collector does not currently export to OpenSearch — only the
> cluster is provisioned. Feeding it OTLP data (e.g. a Kafka→OpenSearch collector like the
> experimental `proof-of-concepts/otel-collector/otel-deployment-opensearch.yaml`) is the
> remaining step before the disk-usage benchmark can run.

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

| Namespace | Components | GitOps-managed? |
|---|---|---|
| `olap` | ClickHouse Cluster, ClickHouse Keeper | Yes |
| `kafka` | Strimzi Kafka Cluster (`teeth-queue`) | Yes |
| `otel` | OpenTelemetry Collector (Deployment + DaemonSet) | Yes |
| `search` | OpenSearch Cluster (`teeth-search`) | Yes |
| `logging` | Fluent Bit DaemonSet | No (manual only) |
| `monitoring` | Prometheus, Grafana (kube-prometheus-stack) | No (manual only) |
| `flux-system` | Flux controllers, HelmRepository sources, `sops-age` decryption secret | GitOps path only |

In the GitOps path, the `olap`, `kafka`, `otel`, and `search` namespaces are created by Flux
(`gitops/infrastructure/namespaces.yaml`); `logging` and `monitoring` are created by their
manual install steps.

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

**Scope:** the GitOps path manages the four operators and the ClickHouse, Kafka, OTel
Collector, and OpenSearch workloads only. Prometheus/Grafana (`monitoring`), Fluent Bit
(`logging`), and Vector are **not** Flux-managed and are still installed via the manual
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
    namespaces.yaml             # olap, kafka, otel, search
    sources/helmrepositories.yaml   # Altinity, Strimzi, OpenTelemetry, OpenSearch Helm repos
    operators/                  # HelmReleases: clickhouse-operator, strimzi, otel-operator, opensearch-operator
  apps/
    base/                       # single source of truth for all envs (no overlays)
      platform-endpoints.yaml   # ConfigMap of shared cross-app names/namespaces (postBuild substituteFrom)
      clickhouse/               # keeper.yaml, cluster.yaml, secret.yaml (namespace: olap)
      kafka/                    # queue.yaml (Kafka + KafkaNodePool) + kafka-metrics ConfigMap (namespace: kafka)
      otel/                     # collector.yaml (namespace: otel)
      opensearch/               # cluster.yaml (OpenSearchCluster, namespace: search)
```

> Secrets are encrypted at rest with **SOPS + age** (see *Secrets management* below).
> The age recipient lives in `.sops.yaml`; the private key (`.sops/age.key`) is
> gitignored and never committed.

### Operators (Flux-managed)

Unlike the manual flow (which only installs the ClickHouse operator), Flux installs all
four operators as `HelmRelease` resources:

| Operator | Namespace | Helm repo | Chart version | Notes |
|---|---|---|---|---|
| Altinity ClickHouse operator | `olap` | `https://docs.altinity.com/clickhouse-operator/` | `0.27.1` | Provides ClickHouse(Keeper)Installation CRDs |
| Strimzi Kafka operator | `kafka` | `https://strimzi.io/charts/` | `1.0.0` | KRaft-only (no ZooKeeper); `watchNamespaces: [kafka]` |
| OpenTelemetry operator | `otel` | `https://open-telemetry.github.io/opentelemetry-helm-charts` | `0.115.0` | `autoGenerateCert` enabled (no cert-manager dependency) |
| OpenSearch operator | `search` | `https://opensearch-project.github.io/opensearch-k8s-operator/` | `3.0.2` | Latest operator line (image appVersion `3.0.0-alpha`), targeting OpenSearch 3.x clusters. The chart's validating webhook defaults to a cert-manager-issued cert, so it's disabled via `webhook.enabled: false` (this repo has no cert-manager); the operator still reconciles `OpenSearchCluster` resources without it. |

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

ClickHouse credentials are no longer stored in plaintext. The `test` user password now
comes from a Kubernetes Secret referenced by the CR
(`test/k8s_secret_password: olap/clickhouse-credentials/password`).

- `gitops/apps/base/clickhouse/secret.yaml` is a SOPS-encrypted `Secret` (only `data` /
  `stringData` are encrypted, per `.sops.yaml`).
- Each cluster's `apps.yaml` Flux Kustomization has
  `decryption: { provider: sops, secretRef: { name: sops-age } }`.
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
   hardcoding DNS, e.g. the OTel collector targets
   `${kafka_cluster_name}-kafka-brokers.${kafka_namespace}.svc.cluster.local:9092` and the
   ClickHouse CR points its keeper nodes at `chk-N.${keeper_service}.${olap_namespace}`.
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
| Vector | 24224 | 30224 | FluentForward |
| Vector | 9598 | — | Prometheus metrics (internal) |
| Fluent Bit | 2020 | — | HTTP health/metrics (internal) |
| ClickHouse Keeper | 2181 | — | ZooKeeper TCP (internal) |
| ClickHouse Keeper | 7000 | — | Prometheus metrics (internal) |
| Kafka | 9092 | — | Plaintext (internal) |
| Kafka | 9093 | — | TLS (internal) |
| OpenSearch | 9200 | — | REST/HTTP API (internal) |
| OpenSearch | 9300 | — | Transport (internal) |
| Grafana | — | 30300 | NodePort UI |
| Prometheus | — | 30090 | NodePort UI |
| Windows host exporter | 9877 | — | Custom metrics endpoint (host) |
