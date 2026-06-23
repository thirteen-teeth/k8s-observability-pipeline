# k8s-observability-pipeline

## Deploy with FluxCD (recommended)

Applications are managed as GitOps under [`gitops/`](gitops/). Flux installs the operators (ClickHouse, Strimzi, OpenTelemetry, OpenSearch, and `kube-prometheus-stack`) and then reconciles the application custom resources. All environments (**local**, **dev**, **prod**) share one base; per-environment values are supplied by a `cluster-vars` ConfigMap.

```
gitops/
  clusters/<env>/        # Flux Kustomizations (infrastructure + apps) + cluster-vars ConfigMap
  infrastructure/        # HelmRepositories + operator HelmReleases + namespaces
  apps/
    base/                # single source of truth: ClickHouse keeper/cluster, Kafka (SCRAM auth + topics/users),
                         #   OTel collectors (OTLP→Kafka producer + Kafka→ClickHouse/OpenSearch ETLs), OpenSearch
```

Environment differences (storage PVC sizes; ClickHouse shard/replica layout; keeper
topology-spread policy — relaxed to `ScheduleAnyway` for single-node `local`) live in
`gitops/clusters/<env>/cluster-vars.yaml`
and are injected into the base via the `apps` Kustomization's `postBuild.substituteFrom`.
The base manifests reference them as `${var:=default}`. Cross-app wiring conventions shared
by all environments (service names and namespaces, e.g. how the collector reaches Kafka)
live once in `gitops/apps/base/platform-endpoints.yaml`, which the same `substituteFrom`
also consumes.

### Bootstrap Flux against an environment

Install the [Flux CLI](https://fluxcd.io/flux/installation/), then bootstrap over SSH
pointing `--path` at the desired environment. First add your SSH **public** key as a
deploy key with **write access** under the repo's Settings → Deploy keys (Flux needs
write access to commit its own components during bootstrap):

```bash
# local | dev | prod
flux bootstrap git \
  --url=ssh://git@github.com/thirteen-teeth/k8s-observability-pipeline \
  --branch=main \
  --path=gitops/clusters/local \
  --private-key-file=/path/to/identity
```

If your SSH key has a passphrase, add `--password=<passphrase>`.

Flux then applies `infrastructure` (operators) and, once healthy, the `apps` Kustomization
for that environment (substituting values from its `cluster-vars` ConfigMap). Inspect
reconciliation with:

```bash
flux get kustomizations --watch
flux get helmreleases -A
```

### Secrets (SOPS + age)

Credentials are stored encrypted with [SOPS](https://github.com/getsops/sops)
+ [age](https://github.com/FiloSottile/age) — the ClickHouse credentials
(`gitops/apps/base/clickhouse/secret.yaml`, including the ETL `otel_writer` and read-only
`grafana_reader` passwords), the
OpenSearch admin credentials (`gitops/apps/base/opensearch/admin-secret.yaml`) and ETL user
password (`gitops/apps/base/opensearch/etl-user-secret.yaml`), the Kafka SCRAM user
passwords (`gitops/apps/base/kafka/sasl-users-secret.yaml`), the collectors' copies of
all ETL credentials (`gitops/apps/base/otel/etl-credentials.yaml`), and the Grafana admin /
data-source credentials (`gitops/infrastructure/operators/monitoring-credentials.yaml`).
The age recipient is in `.sops.yaml`; the private key `.sops/age.key` is gitignored and
must **not** be committed. Before bootstrapping a cluster, load the key so Flux can
decrypt:

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=.sops/age.key
```

To edit a secret, use `SOPS_AGE_KEY_FILE=.sops/age.key sops <path-to-secret>` (e.g.
`gitops/apps/base/opensearch/admin-secret.yaml`).

### Access Grafana

Grafana is exposed as a NodePort at [http://localhost:30300](http://localhost:30300)
(Prometheus is at [http://localhost:30090](http://localhost:30090)). The admin login lives
in the SOPS-encrypted `grafana-credentials` Secret; read it back from the cluster with:

```bash
kubectl -n monitoring get secret grafana-credentials -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl -n monitoring get secret grafana-credentials -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Grafana comes provisioned with three data sources (Prometheus, ClickHouse, OpenSearch) — see
`ARCHITECTURE.md` for details.

### Query the stored telemetry (ClickHouse & OpenSearch)

Neither store is exposed outside the cluster, so query them by `exec`-ing into a pod (or
`kubectl port-forward` if you prefer a local client). Both hold the same OTLP-sourced
logs and traces written by the ETL collectors.

**ClickHouse** (namespace `olap`) — the ETL writes the `otel` database with tables
`otel_logs` and `otel_traces` on the `replicated` cluster. Query as the least-privilege
`otel_writer` user (or read-only `grafana_reader`); passwords live in the SOPS-encrypted
`clickhouse-credentials` Secret:

```bash
# Read the otel_writer password and run a query inside a ClickHouse pod
CH_POD=$(kubectl -n olap get pods -l clickhouse.altinity.com/chi=house \
  -o jsonpath='{.items[0].metadata.name}')
CH_PW=$(kubectl -n olap get secret clickhouse-credentials \
  -o jsonpath='{.data.otel_writer_password}' | base64 -d)

# Cluster-wide count (deduped across shards/replicas)
kubectl -n olap exec -i "$CH_POD" -c clickhouse -- \
  clickhouse-client -u otel_writer --password "$CH_PW" \
  --query "SELECT count() FROM cluster('replicated', otel.otel_logs)"

# Sample recent rows
kubectl -n olap exec -i "$CH_POD" -c clickhouse -- \
  clickhouse-client -u otel_writer --password "$CH_PW" \
  --query "SELECT Timestamp, ServiceName, Body FROM cluster('replicated', otel.otel_logs) ORDER BY Timestamp DESC LIMIT 5 FORMAT Vertical"
```

> The `otel_logs`/`otel_traces` tables are `ReplicatedMergeTree` and the data is **sharded**
> across the cluster, so querying the plain `otel.otel_logs` table only sees the rows on the
> pod you `exec` into (often zero). Wrap the table in `cluster('replicated', otel.<table>)`
> to read across all shards.
`teeth-search-admin-password` Secret (the cluster's CA is self-signed, so `curl -k`):

```bash
# Resolve a master pod and the admin credentials
OS_POD=$(kubectl -n search get pods -o name | grep -m1 teeth-search-masters | cut -d/ -f2)
OS_USER=$(kubectl -n search get secret teeth-search-admin-password \
  -o jsonpath='{.data.username}' | base64 -d)
OS_PW=$(kubectl -n search get secret teeth-search-admin-password \
  -o jsonpath='{.data.password}' | base64 -d)

# Document count across the logs indices
kubectl -n search exec -i "$OS_POD" -c opensearch -- \
  curl -sk -u "$OS_USER:$OS_PW" "https://localhost:9200/ss4o_logs-*/_count"

# List the concrete indices
kubectl -n search exec -i "$OS_POD" -c opensearch -- \
  curl -sk -u "$OS_USER:$OS_PW" "https://localhost:9200/_cat/indices/ss4o_logs-*?v"

# Search recent logs
kubectl -n search exec -i "$OS_POD" -c opensearch -- \
  curl -sk -u "$OS_USER:$OS_PW" \
  "https://localhost:9200/ss4o_logs-*/_search?size=5&sort=time:desc" \
  -H 'Content-Type: application/json'
```

### Preview what an environment renders (no cluster needed)

```bash
# Raw base (tokens unresolved):
kubectl kustomize gitops/apps/base

# Resolved for an env (export that env's cluster-vars values first):
kubectl kustomize gitops/apps/base | flux envsubst
```

### Validate changes before they merge

Pull requests (and pushes to `main`) that touch `gitops/**` run the `validate` GitHub
Actions workflow (`.github/workflows/validate.yml`) — cluster-free static checks that
catch the most common breakages before Flux reconciles them: `yamllint`, repo-invariant
policy checks (every `Secret` SOPS-encrypted, images and Helm charts pinned),
`kustomize build`, and `kubeconform` schema validation. See the **Validation (CI)** section
in `ARCHITECTURE.md`.

Run the policy checks locally:

```bash
python3 tests/policy/check_manifests.py
```