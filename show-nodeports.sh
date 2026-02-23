#!/usr/bin/env bash
# show-nodeports.sh — Print all NodePort services configured in this observability stack.
# Queries the live cluster and annotates each port with its purpose.

set -euo pipefail

# Map nodePort number -> description (resilient to Helm-generated service name truncation)
declare -A DESCRIPTIONS=(
  [30090]="Prometheus UI"
  [31555]="Prometheus — Config Reloader Web"
  [30300]="Grafana UI"
  [30317]="OTel Collector — OTLP gRPC"
  [30318]="OTel Collector — OTLP HTTP"
  [30225]="OTel Collector — FluentForward"
  [30224]="Vector — FluentForward"
)

bold=$(tput bold 2>/dev/null || printf "")
reset=$(tput sgr0 2>/dev/null || printf "")
cyan=$(tput setaf 6 2>/dev/null || printf "")
green=$(tput setaf 2 2>/dev/null || printf "")
yellow=$(tput setaf 3 2>/dev/null || printf "")

echo ""
echo "${bold}${cyan}=== K8s Observability NodePorts ===${reset}"
echo ""
printf "%-14s %-42s %-10s %s\n" "NAMESPACE" "SERVICE" "NODEPORT" "DESCRIPTION"
printf "%-14s %-42s %-10s %s\n" "---------" "-------" "--------" "-----------"

found=0

# Query all namespaces at once using JSON for exact names
while IFS='|' read -r ns svc nodeport; do
  ns="${ns// /}"
  svc="${svc// /}"
  nodeport="${nodeport// /}"
  [[ -z "$nodeport" ]] && continue

  desc="${DESCRIPTIONS[$nodeport]:-}"

  if [[ -n "$desc" ]]; then
    printf "${green}%-14s %-42s %-10s %s${reset}\n" "$ns" "$svc" "$nodeport" "$desc"
  else
    printf "${yellow}%-14s %-42s %-10s %s${reset}\n" "$ns" "$svc" "$nodeport" "(unlabelled)"
  fi
  found=1
done < <(kubectl get svc -A --field-selector spec.type=NodePort -o json 2>/dev/null \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
for item in d['items']:
    name = item['metadata']['name']
    ns   = item['metadata']['namespace']
    for p in item['spec']['ports']:
        print(f\"{ns} | {name} | {p.get('nodePort', '')}\")
" 2>/dev/null || true)

if [[ $found -eq 0 ]]; then
  echo "  No NodePort services found. Is the cluster running?"
fi

echo ""
echo "${bold}Host access (replace localhost with node IP if remote):${reset}"
echo "  Prometheus  →  http://localhost:30090"
echo "  Grafana     →  http://localhost:30300"
echo "  OTLP gRPC   →  grpc://localhost:30317"
echo "  OTLP HTTP   →  http://localhost:30318"
echo "  OTel Fluent →  localhost:30225"
echo "  Vector      →  localhost:30224"
echo ""
