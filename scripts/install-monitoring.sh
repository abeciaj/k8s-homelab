#!/usr/bin/env bash
# Install or upgrade kube-prometheus-stack into the "monitoring" namespace.
# On first run it asks for a Grafana admin password (or generates one).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pinned so a re-run doesn't silently jump major versions. To upgrade, read the
# chart's upgrade notes first: helm upgrade does not update CRDs.
CHART_VERSION="${CHART_VERSION:-92.13.1}"

for bin in kubectl helm; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

echo "==> Checking nodes"
kubectl get nodes
if kubectl get nodes --no-headers | awk '$2 != "Ready" { bad=1 } END { exit !bad }'; then
  echo "error: not all nodes are Ready — fix the cluster (Part 2) before installing monitoring" >&2
  exit 1
fi

if ! kubectl get storageclass local-path >/dev/null 2>&1; then
  echo "error: storage class local-path not found — it ships with k3s unless installed with --disable local-storage" >&2
  exit 1
fi

echo "==> Adding Helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update

echo "==> Namespace"
kubectl apply -f "${REPO_ROOT}/monitoring/namespace.yaml"

echo "==> Grafana admin Secret"
if kubectl get secret -n monitoring grafana-admin >/dev/null 2>&1; then
  echo "    grafana-admin already exists, leaving it as is"
else
  # Prompted rather than taken from an env var or flag, so it stays out of shell
  # history, process listings and Helm's release history.
  pw=""
  read -rsp "    Grafana admin password (leave empty to generate one): " pw || true
  echo
  [[ -n "$pw" ]] || pw="$(openssl rand -base64 24)"
  printf '%s' "$pw" | kubectl create secret generic grafana-admin -n monitoring \
    --from-literal=admin-user=admin --from-file=admin-password=/dev/stdin
  unset pw
fi

echo "==> Installing kube-prometheus-stack ${CHART_VERSION}"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "${CHART_VERSION}" \
  --namespace monitoring \
  -f "${REPO_ROOT}/monitoring/values.yaml"

echo "==> Applying network policies"
kubectl apply -f "${REPO_ROOT}/monitoring/network-policies.yaml"

echo "==> Node audit alerts"
kubectl apply -f "${REPO_ROOT}/monitoring/node-audit-alerts.yaml"

echo "==> Done. Watch pods come up with:"
echo "    kubectl get pods -n monitoring -w"
