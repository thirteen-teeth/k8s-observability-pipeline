# k8s-observability-pipeline

## Deploy with FluxCD (recommended)

Applications are managed as GitOps under [`gitops/`](gitops/). Flux installs the operators (ClickHouse, Strimzi, OpenTelemetry, etc.) and then reconciles the application custom resources, with per-environment overrides for **local**, **dev**, and **prod**.

```
gitops/
  clusters/<env>/        # Flux Kustomizations: infrastructure + apps (per environment)
  infrastructure/        # HelmRepositories + operator HelmReleases + namespaces
  apps/
    base/                # curated ClickHouse keeper/cluster, Kafka, OTel collector
    overlays/<env>/      # storage sizes + pod anti-affinity overrides
```

Environment differences (storage PVC sizes; keeper pod anti-affinity is disabled for
single-node `local`) live in `gitops/apps/overlays/<env>/kustomization.yaml`.

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

Flux then applies `infrastructure` (operators) and, once healthy, the `apps` overlay
for that environment. Inspect reconciliation with:

```bash
flux get kustomizations --watch
flux get helmreleases -A
```

### Secrets (SOPS + age)

ClickHouse credentials are stored encrypted with [SOPS](https://github.com/getsops/sops)
+ [age](https://github.com/FiloSottile/age) (`gitops/apps/base/clickhouse/secret.yaml`).
The age recipient is in `.sops.yaml`; the private key `.sops/age.key` is gitignored and
must **not** be committed. Before bootstrapping a cluster, load the key so Flux can
decrypt:

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=.sops/age.key
```

To edit a secret, use `SOPS_AGE_KEY_FILE=.sops/age.key sops gitops/apps/base/clickhouse/secret.yaml`.

### Preview what an environment renders (no cluster needed)

```bash
kubectl kustomize gitops/apps/overlays/local
```