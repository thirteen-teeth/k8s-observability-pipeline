```
SELECT * FROM otel.otel_logs
WHERE Timestamp >= NOW() - INTERVAL 5 MINUTE
ORDER BY Timestamp DESC
```

export log_date=$(date +%s%N); curl --header "Content-Type: application/json" --request POST --data '{"resourceLogs":[{"resource":{},"scopeLogs":[{"scope":{},"logRecords":[{"timeUnixNano":"'"$log_date"'","body":{"stringValue":"{\"message\":\"King of the Pirates\"}"},"traceId":"","spanId":""}]}]}]}' http://localhost:4318/v1/logs



k -n kafka exec -it teeth-queue-kafka-0 -c kafka -- bin/kafka-topics.sh --bootstrap-server teeth-queue-kafka-brokers.kafka.svc.cluster.local:9092 --list

k -n kafka exec -it teeth-queue-kafka-0 -- bin/kafka-console-consumer.sh --bootstrap-server teeth-queue-kafka-brokers.kafka.svc.cluster.local:9092 --topic otlp_logs