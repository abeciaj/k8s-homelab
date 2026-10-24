#!/usr/bin/env bash
# Print the Grafana admin password from the grafana-admin Secret.
set -euo pipefail

kubectl get secret -n monitoring grafana-admin \
  -o jsonpath="{.data.admin-password}" | base64 --decode
echo
