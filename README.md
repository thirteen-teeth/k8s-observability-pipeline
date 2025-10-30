### Install ClickHouse Operator
```bash
# Optional - get the latest operator install template
bash get-operator-install-template.sh

kubectl create namespace olap
kubectl apply -f clickhouse-operator-install.yaml
```

### Install ClickHouse Cluster
```bash
kubectl apply -f clickhouse-keeper.yaml -n olap
kubectl apply -f clickhouse-cluster.yaml -n olap
```

### Install Kafka Cluster
```bash
kubectl apply -f proof-of-concepts/kafka/queue.yaml -n kafka
```

### Install Opentelemetry Collector
```bash
kubectl apply -f proof-of-concepts/otel-collector/otel-deployment-kafka.yaml -n otel
kubectl delete -f proof-of-concepts/otel-collector/otel-deployment-kafka.yaml -n otel
```