# Commands to install and run the demo

```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add jetstack https://charts.jetstack.io
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add opensearch-operator https://opster.github.io/opensearch-k8s-operator/

helm repo update


# required for jaeger & otel-operator
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.12.0 \
  --set installCRDs=true

# jaeger
helm upgrade --install tracing jaegertracing/jaeger-operator \
  --namespace tracing \
  --create-namespace \
  --version 2.46.2
  --set installCRDs=true

# kafka
helm upgrade --install my-strimzi-cluster-operator oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  --create-namespace \
  --namespace kafka \
  --version 0.38.0 \
  --set installCRDs=true

# otel
helm upgrade --install my-otel-operator open-telemetry/opentelemetry-operator \
  --namespace otel \
  --create-namespace \
  --version 0.36.0

# prometheus
helm upgrade --install my-monitoring prometheus-community/kube-prometheus-stack \
  --version 48.1.1 \
  -f teeth-monitoring.yaml \
  --namespace monitoring \
  --create-namespace

# opensearch
helm upgrade --install os-op opensearch-operator/opensearch-operator \
  --namespace search \
  --create-namespace \
  --version 2.4.0

# clickhouse
# Namespace to install operator into
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-olap}"
# Namespace to install metrics-exporter into
METRICS_EXPORTER_NAMESPACE="${OPERATOR_NAMESPACE}"
# Operator's docker image
OPERATOR_IMAGE="${OPERATOR_IMAGE:-altinity/clickhouse-operator:latest}"
# Metrics exporter's docker image
METRICS_EXPORTER_IMAGE="${METRICS_EXPORTER_IMAGE:-altinity/metrics-exporter:latest}"

# Setup clickhouse-operator into specified namespace
kubectl apply --namespace="${OPERATOR_NAMESPACE}" -f <( \
    curl -s https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator/clickhouse-operator-install-template.yaml | \
        OPERATOR_IMAGE="${OPERATOR_IMAGE}" \
        OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE}" \
        METRICS_EXPORTER_IMAGE="${METRICS_EXPORTER_IMAGE}" \
        METRICS_EXPORTER_NAMESPACE="${METRICS_EXPORTER_NAMESPACE}" \
        envsubst \
)

# zookeeper (required for clickhouse, kafka has built in zookeeper)
kubectl create namespace zoo1ns
kubectl apply -f zookeeper.yaml -n zoo1ns
```
# Commands to run the demo

```
# localhost:8123/play

SELECT * FROM otel.otel_logs
WHERE Timestamp >= NOW() - INTERVAL 5 MINUTE
ORDER BY Timestamp DESC
```

```
export log_date=$(date +%s%N); curl --header "Content-Type: application/json" --request POST --data '{"resourceLogs":[{"resource":{},"scopeLogs":[{"scope":{},"logRecords":[{"timeUnixNano":"'"$log_date"'","body":{"stringValue":"{\"message\":\"King of the Pirates\"}"},"traceId":"","spanId":""}]}]}]}' http://localhost:4318/v1/logs
```

### Tailing Logs in Kafka
```
k -n kafka exec -it teeth-queue-kafka-0 -c kafka -- bin/kafka-topics.sh --bootstrap-server teeth-queue-kafka-brokers.kafka.svc.cluster.local:9092 --list

k -n kafka exec -it teeth-queue-kafka-0 -- bin/kafka-console-consumer.sh --bootstrap-server teeth-queue-kafka-brokers.kafka.svc.cluster.local:9092 --topic otlp_logs
```