#!/bin/bash

# Script to send test messages to Vector server via Fluentd protocol
# This runs a temporary pod in Kubernetes that sends test logs to Vector

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
VECTOR_SERVICE="vector-server-service"
VECTOR_PORT="24224"
NAMESPACE="${1:-default}"

echo -e "${YELLOW}Sending test message to Vector server...${NC}"
echo "Service: $VECTOR_SERVICE"
echo "Port: $VECTOR_PORT"
echo "Namespace: $NAMESPACE"
echo ""

# Create a temporary pod that sends a test message using netcat
kubectl run vector-test-sender \
  --image=alpine:latest \
  --restart=Never \
  --rm \
  -i \
  --namespace="$NAMESPACE" \
  --command -- sh -c "
    apk add --no-cache curl netcat-openbsd jq > /dev/null 2>&1
    
    # Create a test message in Fluentd's forward protocol format
    # Using JSON format that Vector can parse
    
    echo -e '${GREEN}Sending test message to Vector...${NC}'
    
    # Simple approach: use netcat to send raw data
    # Format: tag, timestamp, record
    MESSAGE='{\"message\": \"Test log from shell script\", \"level\": \"info\", \"timestamp\": \"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'\", \"source\": \"test-script\", \"hostname\": \"test-pod\"}'
    
    echo \"Test message content: \$MESSAGE\"
    echo \"\"
    
    # Send message using echo and netcat
    # Note: This is a simplified version. For production, use proper Fluentd client
    echo \"\$MESSAGE\" | nc -w 5 $VECTOR_SERVICE $VECTOR_PORT || {
      echo -e '${RED}Failed to send message. Is Vector service accessible?${NC}'
      exit 1
    }
    
    echo -e '${GREEN}Message sent successfully!${NC}'
    echo \"\"
    echo 'You can verify the message was received by checking:'
    echo '1. Vector logs: kubectl logs vector-server'
    echo '2. Kafka topic (if configured): kubectl exec -it <kafka-pod> -- kafka-console-consumer --bootstrap-server localhost:9092 --topic vector_logs --from-beginning'
    echo '3. Vector metrics: kubectl port-forward service/vector-server-service 9598:9598 then visit http://localhost:9598/metrics'
  "

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo -e "${GREEN}✓ Test message sent successfully!${NC}"
else
  echo -e "${RED}✗ Failed to send test message${NC}"
  exit $EXIT_CODE
fi
