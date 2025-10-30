#!/bin/bash

# Simple and reliable script to send test messages to Vector server
# Uses a pre-defined Kubernetes Job

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
VECTOR_SERVICE="${VECTOR_SERVICE:-vector-server-service}"
VECTOR_PORT="${VECTOR_PORT:-24224}"
NAMESPACE="${1:-default}"
MESSAGE="${2:-Test message from Kubernetes}"

echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}   Vector Test Message Sender${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "  Service:    $VECTOR_SERVICE"
echo "  Port:       $VECTOR_PORT"
echo "  Namespace:  $NAMESPACE"
echo "  Message:    $MESSAGE"
echo ""

# Create temporary YAML file
TEMP_YAML=$(mktemp /tmp/vector-test-XXXXX.yaml)

cat > "$TEMP_YAML" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: vector-test-sender
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
  - name: fluent-bit
    image: fluent/fluent-bit:latest
    command: ["/bin/sh"]
    args:
    - -c
    - |
      cat > /fluent-bit.conf <<'FBEOF'
      [SERVICE]
          Flush        1
          Log_Level    info

      [INPUT]
          Name         dummy
          Tag          test.log
          Dummy        {"message": "$MESSAGE", "level": "info", "source": "k8s-test", "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "test": true}
          Rate         1

      [OUTPUT]
          Name         forward
          Match        *
          Host         $VECTOR_SERVICE
          Port         $VECTOR_PORT
      FBEOF
      
      echo "✓ Starting Fluent Bit..."
      timeout 5 /fluent-bit/bin/fluent-bit -c /fluent-bit.conf || true
      echo "✓ Messages sent!"
EOF

echo -e "${YELLOW}Creating test pod...${NC}"
kubectl apply -f "$TEMP_YAML"

echo -e "${YELLOW}Waiting for pod to complete...${NC}"
kubectl wait --for=condition=Ready pod/vector-test-sender -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
sleep 6

echo ""
echo -e "${YELLOW}Pod logs:${NC}"
kubectl logs vector-test-sender -n "$NAMESPACE" 2>/dev/null || echo "Pod may have completed already"

echo ""
echo -e "${YELLOW}Cleaning up test pod...${NC}"
kubectl delete pod vector-test-sender -n "$NAMESPACE" --ignore-not-found=true

# Cleanup temp file
rm -f "$TEMP_YAML"

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Test completed!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Verification:${NC}"
echo "1. Check Vector logs:"
echo "   kubectl logs vector-server -n $NAMESPACE"
echo ""
echo "2. Check Vector metrics:"
echo "   kubectl port-forward service/$VECTOR_SERVICE 9598:9598 -n $NAMESPACE"
echo "   curl http://localhost:9598/metrics | grep sent_events_total"
echo ""
echo "3. Check Kafka topic (if configured):"
echo "   # List topics to find your vector_logs topic"
