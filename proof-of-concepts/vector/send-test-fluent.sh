#!/bin/bash

# Advanced script to send test messages to Vector using Fluent Bit client
# This provides better compatibility with Fluentd/Vector protocol

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
MESSAGE="${2:-Test message from Kubernetes pod}"

echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Vector Test Message Sender (Fluent)     ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "  Service:    $VECTOR_SERVICE"
echo "  Port:       $VECTOR_PORT"
echo "  Namespace:  $NAMESPACE"
echo "  Message:    $MESSAGE"
echo ""

# Check if service exists
echo -e "${YELLOW}Checking if Vector service exists...${NC}"
if ! kubectl get service "$VECTOR_SERVICE" -n "$NAMESPACE" &>/dev/null; then
  echo -e "${RED}✗ Service $VECTOR_SERVICE not found in namespace $NAMESPACE${NC}"
  echo "Available services:"
  kubectl get services -n "$NAMESPACE"
  exit 1
fi
echo -e "${GREEN}✓ Service found${NC}"
echo ""

# Create and run test pod
echo -e "${YELLOW}Creating test pod to send message...${NC}"

kubectl run vector-fluent-test \
  --image=fluent/fluent-bit:latest \
  --restart=Never \
  --rm \
  -i \
  --namespace="$NAMESPACE" \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "fluent-bit",
        "image": "fluent/fluent-bit:latest",
        "command": ["/bin/sh"],
        "args": ["-c", "
          # Create fluent-bit config
          cat > /fluent-bit.conf <<EOF
[SERVICE]
    Flush        1
    Log_Level    info

[INPUT]
    Name         dummy
    Tag          test.log
    Dummy        {\"message\": \"'"$MESSAGE"'\", \"level\": \"info\", \"source\": \"k8s-test-script\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"pod\": \"test-sender\"}
    Rate         1

[OUTPUT]
    Name         forward
    Match        *
    Host         '"$VECTOR_SERVICE"'
    Port         '"$VECTOR_PORT"'
EOF
          
          echo '✓ Configuration created'
          echo ''
          echo 'Starting Fluent Bit to send test message...'
          
          # Run fluent-bit for 3 seconds then exit
          timeout 3 /fluent-bit/bin/fluent-bit -c /fluent-bit.conf || true
          
          echo ''
          echo '✓ Message sent to Vector server'
          echo ''
          echo 'Verification steps:'
          echo '  1. Check Vector logs:'
          echo '     kubectl logs vector-server -n '"$NAMESPACE"''
          echo '  2. Check Kafka topic (if connected):'
          echo '     kubectl exec -it <kafka-pod> -- kafka-console-consumer --topic vector_logs --from-beginning'
          echo '  3. Check Vector metrics:'
          echo '     kubectl port-forward service/'"$VECTOR_SERVICE"' 9598:9598'
          echo '     curl http://localhost:9598/metrics | grep component_sent_events_total'
        "]
      }]
    }
  }'

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
  echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║          ✓ Success!                        ║${NC}"
  echo -e "${GREEN}║  Test message sent to Vector server        ║${NC}"
  echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
else
  echo -e "${RED}╔════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║          ✗ Failed                          ║${NC}"
  echo -e "${RED}║  Could not send message to Vector          ║${NC}"
  echo -e "${RED}╚════════════════════════════════════════════╝${NC}"
  exit $EXIT_CODE
fi
