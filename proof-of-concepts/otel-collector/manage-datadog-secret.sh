#!/bin/bash

# Script to securely manage Datadog API key for OpenTelemetry Collector

NAMESPACE="${NAMESPACE:-otel}"
SECRET_NAME="datadog-api-key"

case "$1" in
  "create")
    if [ -z "$2" ]; then
      echo "Usage: $0 create <api-key>"
      echo "Example: $0 create your-datadog-api-key-here"
      exit 1
    fi
    
    echo "Creating Datadog API key secret in namespace $NAMESPACE..."
    kubectl create secret generic $SECRET_NAME \
      --from-literal=api-key="$2" \
      -n $NAMESPACE
    echo "Secret created successfully!"
    ;;
    
  "update")
    if [ -z "$2" ]; then
      echo "Usage: $0 update <new-api-key>"
      echo "Example: $0 update your-new-datadog-api-key-here"
      exit 1
    fi
    
    echo "Updating Datadog API key secret in namespace $NAMESPACE..."
    kubectl delete secret $SECRET_NAME -n $NAMESPACE 2>/dev/null || true
    kubectl create secret generic $SECRET_NAME \
      --from-literal=api-key="$2" \
      -n $NAMESPACE
    echo "Secret updated successfully!"
    ;;
    
  "delete")
    echo "Deleting Datadog API key secret from namespace $NAMESPACE..."
    kubectl delete secret $SECRET_NAME -n $NAMESPACE
    echo "Secret deleted successfully!"
    ;;
    
  "verify")
    echo "Verifying secret exists in namespace $NAMESPACE..."
    if kubectl get secret $SECRET_NAME -n $NAMESPACE >/dev/null 2>&1; then
      echo "✓ Secret '$SECRET_NAME' exists in namespace '$NAMESPACE'"
      echo "Secret created: $(kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.metadata.creationTimestamp}')"
    else
      echo "✗ Secret '$SECRET_NAME' not found in namespace '$NAMESPACE'"
      exit 1
    fi
    ;;
    
  *)
    echo "Datadog API Key Secret Manager"
    echo ""
    echo "Usage: $0 {create|update|delete|verify} [api-key]"
    echo ""
    echo "Commands:"
    echo "  create <api-key>    Create a new secret with the provided API key"
    echo "  update <api-key>    Update existing secret with new API key"
    echo "  delete              Delete the secret"
    echo "  verify              Check if secret exists"
    echo ""
    echo "Environment variables:"
    echo "  NAMESPACE           Kubernetes namespace (default: otel)"
    echo ""
    echo "Examples:"
    echo "  $0 create dd1234567890abcdef"
    echo "  $0 update dd0987654321fedcba"
    echo "  $0 verify"
    echo "  NAMESPACE=monitoring $0 create dd1234567890abcdef"
    exit 1
    ;;
esac
