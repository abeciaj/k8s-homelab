#!/usr/bin/env bash
# Run the CIS Kubernetes Benchmark for k3s (kube-bench) on a node over SSH.
# The k3s checks read the node's systemd journal, so kube-bench runs on the host
# itself rather than in a pod. Nothing is left installed on the node.
#
# Usage: ./scripts/run-kube-bench.sh <user>@<node-ip>
# On an agent node, set TARGETS=node: it has no control plane to check.
set -euo pipefail
# The report describes the node's weak spots, so keep it readable only by you.
umask 077

# Pinned with its SHA-256 from the release's checksums file. Update both together.
KUBE_BENCH_VERSION="${KUBE_BENCH_VERSION:-0.16.0}"
KUBE_BENCH_SHA256="${KUBE_BENCH_SHA256:-82dbc7e598740dc9344d41f8ad0b8210d57c4c00bdb2c5f1d8a69a2b98baddcf}"
BENCHMARK="${BENCHMARK:-k3s-cis-1.24}"
TARGETS="${TARGETS:-master,controlplane,etcd,node,policies}"
REPORT="${REPORT:-$HOME/kube-bench-$(date +%Y-%m-%d).txt}"

target="${1:-}"
if [[ -z "$target" ]]; then
  echo "usage: $0 <user>@<node-ip>" >&2
  exit 1
fi

tarball="kube-bench_${KUBE_BENCH_VERSION}_linux_amd64.tar.gz"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "==> Downloading kube-bench ${KUBE_BENCH_VERSION}"
curl -fsSL -o "${workdir}/${tarball}" \
  "https://github.com/aquasecurity/kube-bench/releases/download/v${KUBE_BENCH_VERSION}/${tarball}"
echo "${KUBE_BENCH_SHA256}  ${workdir}/${tarball}" | shasum -a 256 -c - >/dev/null \
  || { echo "error: checksum mismatch for ${tarball}" >&2; exit 1; }

arch="$(ssh "$target" uname -m)"
if [[ "$arch" != "x86_64" ]]; then
  echo "error: ${target} is ${arch}; this script only fetches the amd64 build" >&2
  exit 1
fi

echo "==> Running ${BENCHMARK} on ${target} (asks for your sudo password)"
remote="$(ssh "$target" mktemp -d)"
scp -q "${workdir}/${tarball}" "${target}:${remote}/"
# -t so sudo can prompt. The cleanup runs even if the benchmark fails.
ssh -t "$target" "cd ${remote} && tar -xzf ${tarball} && \
  sudo ./kube-bench run --config-dir cfg --config cfg/config.yaml \
    --benchmark ${BENCHMARK} --targets ${TARGETS}; \
  status=\$?; rm -rf ${remote}; exit \$status" | tr -d '\r' | tee "$REPORT"

echo "==> Report saved to ${REPORT}"
