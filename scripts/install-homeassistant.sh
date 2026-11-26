#!/usr/bin/env bash
# Install or upgrade Home Assistant at https://ha.home.lab (LAN only).
# Safe to re-run: the configuration in its volume is never overwritten.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

command -v kubectl >/dev/null || { echo "error: kubectl not found on PATH" >&2; exit 1; }

if ! kubectl get storageclass local-path >/dev/null 2>&1; then
  echo "error: storage class local-path not found — it ships with k3s unless installed with --disable local-storage" >&2
  exit 1
fi
if ! kubectl get clusterissuer homelab-ca >/dev/null 2>&1; then
  echo "error: ClusterIssuer homelab-ca not found — run scripts/install-cert-manager.sh first" >&2
  exit 1
fi

echo "==> Namespace and network policies"
kubectl apply -f "${REPO_ROOT}/homeassistant/namespace.yaml"
kubectl apply -f "${REPO_ROOT}/homeassistant/network-policies.yaml"

echo "==> Home Assistant"
kubectl apply -f "${REPO_ROOT}/homeassistant/homeassistant.yaml"
# The first start installs Python packages, so this can take a few minutes.
kubectl rollout status deploy/homeassistant -n homeassistant --timeout=10m

echo "==> Done. Next (see homeassistant/README.md):"
echo "    point ha.home.lab at any node's IP in /etc/hosts"
echo "    open https://ha.home.lab and create the owner account"
