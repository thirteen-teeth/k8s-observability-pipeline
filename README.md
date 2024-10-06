### Install ClickHouse Operator
```bash
# Optional - get the latest operator install template
chmod +x get-operator-install-template.sh
./get-operator-install-template.sh

kubectl create namespace olap
kubectl apply -f clickhouse-operator-install.yaml
```

### Install ClickHouse Cluster
```bash
kubectl apply -f clickhouse-keeper.yaml -n olap
kubectl apply -f clickhouse-cluster.yaml -n olap
```

