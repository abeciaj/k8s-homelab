#!/usr/bin/env bash
# Install or upgrade Trivy Operator, which scans every image running in the cluster
# for known vulnerabilities and exposed secrets, and audits workload config and RBAC.
# Safe to re-run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pinned with the chart's SHA-256 from the repo's index.yaml, so a re-published
# chart is refused. Trivy releases were briefly compromised in March 2026: before
# bumping, check github.com/aquasecurity/trivy/security/advisories and update the
# checksum and the image digests in security/values.yaml together.
CHART_VERSION="${CHART_VERSION:-0.37.0}"
CHART_SHA256="${CHART_SHA256:-6d23f16d950496d17253258ca2e52bd068959041298e66c0652bf0841ccedf69}"

for bin in kubectl helm; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

if ! kubectl get storageclass local-path >/dev/null 2>&1; then
  echo "error: storage class local-path not found — it ships with k3s unless installed with --disable local-storage" >&2
  exit 1
fi

# Metrics and alerts only if the monitoring stack (and its CRDs) is installed.
monitoring=false
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  monitoring=true
fi
extra_values=()
if $monitoring; then
  extra_values+=(-f "${REPO_ROOT}/security/monitoring.yaml")
fi

echo "==> Namespace"
kubectl apply -f "${REPO_ROOT}/security/namespace.yaml"

echo "==> Downloading trivy-operator ${CHART_VERSION}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
helm pull trivy-operator --repo https://aquasecurity.github.io/helm-charts/ \
  --version "${CHART_VERSION}" --destination "$workdir"
chart="${workdir}/trivy-operator-${CHART_VERSION}.tgz"
echo "${CHART_SHA256}  ${chart}" | shasum -a 256 -c - >/dev/null \
  || { echo "error: checksum mismatch for trivy-operator ${CHART_VERSION}" >&2; exit 1; }

echo "==> Installing trivy-operator ${CHART_VERSION}"
helm upgrade --install trivy-operator "$chart" \
  --namespace trivy-system \
  -f "${REPO_ROOT}/security/values.yaml" \
  "${extra_values[@]+"${extra_values[@]}"}" \
  --wait --timeout 10m

echo "==> Network policies"
kubectl apply -f "${REPO_ROOT}/security/network-policies.yaml"

if $monitoring; then
  echo "==> Vulnerability alerts and Grafana dashboard"
  kubectl apply -f "${REPO_ROOT}/security/alerts.yaml"
  # Grafana's sidecar loads any ConfigMap labelled grafana_dashboard=1.
  kubectl create configmap trivy-dashboard -n trivy-system \
    --from-file=container-vulnerabilities.json="${REPO_ROOT}/security/dashboard.json" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml \
    | kubectl apply -f -
else
  echo "==> Monitoring stack not installed, skipping metrics and alerts"
fi

echo "==> Done. The first scans take a few minutes. Then:"
echo "    kubectl get vulnerabilityreports -A -o wide"
