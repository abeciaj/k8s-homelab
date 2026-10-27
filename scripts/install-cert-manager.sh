#!/usr/bin/env bash
# Install or upgrade cert-manager and the Homelab CA, then save the CA certificate
# locally so you can trust it on your devices. Safe to re-run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pinned so a re-run doesn't silently jump versions. Read the upgrade notes before
# bumping it: cert-manager upgrades one minor version at a time.
CHART_VERSION="${CHART_VERSION:-v1.21.3}"
CA_FILE="${CA_FILE:-$HOME/homelab-ca.crt}"

for bin in kubectl helm; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

# Metrics and alerts only if the monitoring stack (and its CRDs) is installed.
monitoring=false
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  monitoring=true
fi
extra_values=()
if $monitoring; then
  extra_values+=(-f "${REPO_ROOT}/cert-manager/monitoring.yaml")
fi

echo "==> Installing cert-manager ${CHART_VERSION}"
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version "${CHART_VERSION}" \
  --namespace cert-manager \
  --create-namespace \
  -f "${REPO_ROOT}/cert-manager/values.yaml" \
  "${extra_values[@]+"${extra_values[@]}"}" \
  --wait --timeout 10m

if $monitoring; then
  echo "==> Certificate alerts"
  kubectl apply -f "${REPO_ROOT}/cert-manager/alerts.yaml"
else
  echo "==> Monitoring stack not installed, skipping metrics and alerts"
fi

echo "==> Homelab CA"
kubectl apply -f "${REPO_ROOT}/cert-manager/homelab-ca.yaml"
kubectl wait -n cert-manager certificate/homelab-ca --for=condition=Ready --timeout=2m
kubectl wait clusterissuer/homelab-ca --for=condition=Ready --timeout=2m

# Only the public certificate. The private key never leaves the cluster.
kubectl get secret -n cert-manager homelab-ca -o jsonpath='{.data.ca\.crt}' | base64 --decode > "${CA_FILE}"
echo "    CA certificate saved to ${CA_FILE}"

echo "==> Done. Trust the CA on this Mac (once; asks for your password):"
echo "    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${CA_FILE}"
