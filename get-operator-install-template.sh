#!/bin/bash
# This script generates clickhouse-operator-install.yaml file from the template

# Namespace to install operator into
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-olap}"
# Namespace to install metrics-exporter into
METRICS_EXPORTER_NAMESPACE="${OPERATOR_NAMESPACE}"
# Operator's docker image
OPERATOR_IMAGE="${OPERATOR_IMAGE:-altinity/clickhouse-operator:latest}"
# Metrics exporter's docker image
METRICS_EXPORTER_IMAGE="${METRICS_EXPORTER_IMAGE:-altinity/metrics-exporter:latest}"


curl -s https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator/clickhouse-operator-install-template.yaml | \
        OPERATOR_IMAGE="${OPERATOR_IMAGE}" \
        OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE}" \
        METRICS_EXPORTER_IMAGE="${METRICS_EXPORTER_IMAGE}" \
        METRICS_EXPORTER_NAMESPACE="${METRICS_EXPORTER_NAMESPACE}" \
        envsubst > clickhouse-operator-install.yaml
