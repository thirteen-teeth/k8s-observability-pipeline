# Copilot Instructions

## Always Update ARCHITECTURE.md

`ARCHITECTURE.md` is the authoritative running document describing this repository's architecture, components, data flows, and configuration.

**After every change to this repository, update `ARCHITECTURE.md` to reflect it.** This includes:

- Adding, removing, or modifying any Kubernetes manifests (deployments, services, configmaps, etc.)
- Changes to Helm values files (e.g., `proof-of-concepts/prometheus/monitoring.yaml`)
- New or modified OTel Collector pipelines, receivers, processors, or exporters
- Changes to Kafka topics, brokers, or operator config
- Changes to ClickHouse cluster layout, schema, or Keeper config
- New scrape targets, ServiceMonitors, or PodMonitors in Prometheus
- Changes to Fluent Bit or Vector config
- New namespaces or install steps

When updating `ARCHITECTURE.md`:
- Keep data flow diagrams, port tables, namespace tables, and component descriptions in sync with actual config files
- Update the relevant section(s) only — do not rewrite sections that were not affected
- Record new ports in the **Key Ports Reference** table
- Record new Kafka topics in the **Topics** table
- Update `additionalScrapeConfigs` examples in the Prometheus section if scrape targets change

## Repository Context

- Primary storage: ClickHouse (Altinity operator), namespace `olap`
- Message queue: Kafka (Strimzi operator), namespace `kafka`
- Log/trace ingestion: OpenTelemetry Collector, namespace `otel`
- Node log collection: Fluent Bit DaemonSet, namespace `logging`; Vector pod as alternative
- Metrics: kube-prometheus-stack Helm release `my-monitoring`, namespace `monitoring`
- Helm install command: `helm upgrade --install my-monitoring prometheus-community/kube-prometheus-stack --version 79.0.0 -f proof-of-concepts/prometheus/monitoring.yaml --namespace monitoring --create-namespace`
