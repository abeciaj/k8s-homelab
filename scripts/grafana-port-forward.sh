#!/usr/bin/env bash
# Forward Grafana to http://localhost:3000 (login: admin / scripts/grafana-password.sh).
set -euo pipefail

kubectl port-forward -n monitoring svc/monitoring-grafana "${PORT:-3000}:80"
