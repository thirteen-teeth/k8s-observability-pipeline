# k8s-observability-pipeline

## Deploy with FluxCD (recommended)

Applications are managed as GitOps under [`gitops/`](gitops/). Flux installs the operators (ClickHouse, Strimzi, OpenTelemetry, OpenSearch) and then reconciles the application custom resources. All environments (**local**, **dev**, **prod**) share one base; per-environment values are supplied by a `cluster-vars` ConfigMap.

```
gitops/
  clusters/<env>/        # Flux Kustomizations (infrastructure + apps) + cluster-vars ConfigMap
  infrastructure/        # HelmRepositories + operator HelmReleases + namespaces
  apps/
    base/                # single source of truth: ClickHouse keeper/cluster, Kafka, OTel collector, OpenSearch
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
(`gitops/apps/base/clickhouse/secret.yaml`) and the OpenSearch admin credentials
(`gitops/apps/base/opensearch/admin-secret.yaml`).
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

### Preview what an environment renders (no cluster needed)

```bash
# Raw base (tokens unresolved):
kubectl kustomize gitops/apps/base

# Resolved for an env (export that env's cluster-vars values first):
kubectl kustomize gitops/apps/base | flux envsubst
```