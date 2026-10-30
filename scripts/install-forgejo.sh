#!/usr/bin/env bash
# Install or upgrade Forgejo and its Actions runner.
# On first run it asks for the Forgejo admin login (or generates a password),
# creates an everyday non-admin account and registers the runner for that account's
# repos. Re-runs leave all three alone and upgrade in place.
# FORGEJO_USER and FORGEJO_USER_EMAIL skip the everyday-account prompts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pinned so a re-run doesn't silently jump major versions. Read the chart's
# release notes before bumping it.
CHART_VERSION="${CHART_VERSION:-17.3.2}"
RUNNER_NAME="${RUNNER_NAME:-k3s-runner}"

for bin in kubectl helm openssl xxd; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

echo "==> Checking nodes"
kubectl get nodes
if kubectl get nodes --no-headers | awk '$2 != "Ready" { bad=1 } END { exit !bad }'; then
  echo "error: not all nodes are Ready — fix the cluster (Part 2) before installing Forgejo" >&2
  exit 1
fi

if ! kubectl get storageclass local-path >/dev/null 2>&1; then
  echo "error: storage class local-path not found — it ships with k3s unless installed with --disable local-storage" >&2
  exit 1
fi

if ! kubectl get clusterissuer homelab-ca >/dev/null 2>&1; then
  echo "error: ClusterIssuer homelab-ca not found — run scripts/install-cert-manager.sh first" >&2
  exit 1
fi

echo "==> Namespaces"
kubectl apply -f "${REPO_ROOT}/forgejo/namespaces.yaml"

echo "==> Forgejo admin Secret"
if kubectl get secret -n forgejo forgejo-admin >/dev/null 2>&1; then
  echo "    forgejo-admin already exists, leaving it as is"
else
  # Prompted rather than taken from an env var or flag, so it stays out of shell
  # history, process listings and Helm's release history.
  user=""
  read -rp "    Forgejo admin username [forgejo-admin] ('admin' is reserved): " user || true
  user="${user:-forgejo-admin}"
  pw=""
  read -rsp "    Forgejo admin password (leave empty to generate one): " pw || true
  echo
  [[ -n "$pw" ]] || pw="$(openssl rand -base64 24)"
  printf '%s' "$pw" | kubectl create secret generic forgejo-admin -n forgejo \
    --from-literal=username="$user" --from-file=password=/dev/stdin
  unset pw
fi

echo "==> Installing Forgejo chart ${CHART_VERSION}"
helm upgrade --install forgejo oci://code.forgejo.org/forgejo-helm/forgejo \
  --version "${CHART_VERSION}" \
  --namespace forgejo \
  -f "${REPO_ROOT}/forgejo/values.yaml" \
  --wait --timeout 10m

forgejo_cli() {
  kubectl exec -i -n forgejo deploy/forgejo -c forgejo -- forgejo "$@"
}

echo "==> Everyday account and Actions runner"
if kubectl get secret -n forgejo-runner forgejo-runner >/dev/null 2>&1; then
  echo "    forgejo-runner already exists, leaving it as is"
else
  # A non-admin account for daily work; the runner only takes jobs from its repos.
  user="${FORGEJO_USER:-}"
  [[ -n "$user" ]] || read -rp "    Everyday (non-admin) username: " user
  [[ -n "$user" ]] || { echo "error: a username is required" >&2; exit 1; }
  # Not grep -q: exiting early can fail the pipeline under pipefail.
  if forgejo_cli admin user list | awk 'NR > 1 { print $2 }' | grep -x "$user" >/dev/null; then
    echo "    user $user already exists"
  else
    email="${FORGEJO_USER_EMAIL:-}"
    [[ -n "$email" ]] || read -rp "    Email for $user (empty = $user@forgejo.home.lab): " email
    # Forgejo requires one, but this instance sends no mail, so a placeholder works.
    [[ -n "$email" ]] || email="$user@forgejo.home.lab"
    # Prints a one-time password; Forgejo makes the user change it at first login.
    forgejo_cli admin user create --username "$user" --email "$email" --random-password
  fi

  # Offline registration: Forgejo and the runner share a random 40-hex secret.
  # The runner's UUID is the first 16 characters read as raw bytes; the token is
  # the whole secret. Passed on stdin, so it never appears in a process listing.
  # Forgejo 15 defines --secret-stdin as a string flag but only checks that it's
  # set, so it needs a value; "-" is the usual stand-in for stdin.
  secret="$(openssl rand -hex 20)"
  printf '%s' "$secret" | forgejo_cli forgejo-cli actions register \
    --name "$RUNNER_NAME" --scope "$user" --secret-stdin=-
  uuid="$(printf '%s' "${secret:0:16}" | xxd -p | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
  printf '%s' "$secret" | kubectl create secret generic forgejo-runner -n forgejo-runner \
    --from-literal=uuid="$uuid" --from-file=token=/dev/stdin
  unset secret
fi

echo "==> Cluster DNS for forgejo.home.lab"
# CoreDNS doesn't reload imported files on its own, so restart it only on a change.
dns_out="$(kubectl apply -f "${REPO_ROOT}/forgejo/coredns-custom.yaml")"
echo "$dns_out"
if ! grep -q ' unchanged$' <<<"$dns_out"; then
  kubectl rollout restart deploy/coredns -n kube-system
  kubectl rollout status deploy/coredns -n kube-system --timeout=2m
fi

echo "==> Applying runner and network policies"
# Only the public CA certificate, so job containers can trust forgejo.home.lab.
kubectl get secret -n cert-manager homelab-ca -o jsonpath='{.data.ca\.crt}' | base64 --decode |
  kubectl create configmap homelab-ca -n forgejo-runner --from-file=ca.crt=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
runner_out="$(kubectl apply -f "${REPO_ROOT}/forgejo/runner.yaml")"
echo "$runner_out"
# The runner reads its config only at startup.
if grep -q 'configmap/forgejo-runner-config configured' <<<"$runner_out"; then
  kubectl rollout restart deploy/forgejo-runner -n forgejo-runner
fi
kubectl apply -f "${REPO_ROOT}/forgejo/network-policies.yaml"
kubectl rollout status deploy/forgejo-runner -n forgejo-runner --timeout=5m

echo "==> Done. Next:"
echo "    point forgejo.home.lab at any node's IP in /etc/hosts (see forgejo/README.md)"
echo "    open https://forgejo.home.lab   (set up 2FA when asked)"
echo "    kubectl get secret -n forgejo forgejo-admin -o jsonpath='{.data.password}' | base64 --decode; echo"
