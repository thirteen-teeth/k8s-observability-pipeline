#!/bin/bash

# Deploy Vector ConfigMap and Pod to consume from Kafka and print to stdout

echo "Deploying Vector ConfigMap..."
kubectl apply -f vector-configmap.yaml

echo "Deploying Vector Interactive Pod..."
kubectl apply -f vector-interactive-pod.yaml

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/vector-interactive -n kafka --timeout=60s

echo ""
echo "Vector pod is ready! You can now run Vector interactively with:"
echo "kubectl -n kafka exec -it vector-interactive -- vector --config /etc/vector/vector.yaml"
echo ""
echo "Or you can get a shell in the pod with:"
echo "kubectl -n kafka exec -it vector-interactive -- /bin/bash"
echo ""
echo "To clean up when done:"
echo "kubectl delete pod vector-interactive -n kafka"
echo "kubectl delete configmap vector-config -n kafka"
