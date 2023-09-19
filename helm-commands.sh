#!/bin/bash

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add jetstack https://charts.jetstack.io
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts

helm repo update

# required for jaeger & otel-operator
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.12.0 \
  --set installCRDs=true

helm upgrade --install tracing jaegertracing/jaeger-operator \
  --namespace tracing \
  --create-namespace \
  --version 2.46.2
  --set installCRDs=true

helm upgrade --install my-strimzi-cluster-operator oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  --create-namespace \
  --namespace kafka \
  --version 0.66.4 \
  --set installCRDs=true

helm upgrade --install my-otel-operator open-telemetry/opentelemetry-operator \
  --namespace otel \
  --create-namespace \
  --version 0.36.0

helm upgrade --install my-monitoring prometheus-community/kube-prometheus-stack \
  --version 48.1.1 \
  -f teeth-monitoring.yaml \
  --namespace monitoring \
  --create-namespace