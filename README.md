# k8s-homelab

A 3-node k3s homelab on Debian, from the **Back to On-Prem** series. This repo holds
the monitoring layer from Part 3: kube-prometheus-stack (Prometheus, Grafana,
Alertmanager, node-exporter, kube-state-metrics) plus a Grafana Ingress via k3s's Traefik.
It also holds a self-hosted Git server with CI/CD (Forgejo + Forgejo Actions); see
[forgejo/README.md](forgejo/README.md). For vulnerability scanning of running images
(Trivy Operator) and a CIS benchmark of k3s itself (kube-bench), see
[security/README.md](security/README.md).

## Layout

```
monitoring/values.yaml      Helm overrides for kube-prometheus-stack
monitoring/grafana-ingress.yaml   HTTPS Ingress for grafana.home.lab (Traefik)
monitoring/network-policies.yaml  Limits who can reach Prometheus, Alertmanager, Grafana
monitoring/node-audit-alerts.yaml Alerts on the Ansible node audit results (Lynis, debsecan)
scripts/install-monitoring.sh     Checks nodes, installs/upgrades the chart
scripts/grafana-password.sh       Prints the Grafana admin password
scripts/grafana-port-forward.sh   Forwards Grafana to localhost:3000
scripts/install-forgejo.sh        Installs/upgrades Forgejo and its Actions runner
scripts/install-cert-manager.sh   Installs cert-manager and the Homelab CA
scripts/install-trivy-operator.sh Installs/upgrades Trivy Operator
scripts/run-kube-bench.sh         Runs the k3s CIS benchmark on a node over SSH
forgejo/                          Forgejo values, runner, namespaces, network policies
cert-manager/                     cert-manager values and the Homelab CA
security/                         Trivy Operator values, alerts, network policies
```

## Prerequisites

Helm and kubectl run on your workstation (laptop), not on the cluster nodes. Both are clients:
they talk to the k3s API server on port 6443, and the cluster schedules the pods onto every node.

1. **A working k3s cluster** with all nodes `Ready` (from Part 2).

2. **kubectl and Helm on your workstation.** On macOS:

   ```bash
   brew install kubectl helm
   ```

   On Linux, use `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`
   and the [kubectl install docs](https://kubernetes.io/docs/tasks/tools/).

3. **A kubeconfig for the cluster.** k3s writes one on the server node at
   `/etc/rancher/k3s/k3s.yaml`. It is root-only and points at `127.0.0.1`, so copy it with
   sudo and swap in the server's IP. On Linux, drop the `''` after `sed -i`:

   ```bash
   mkdir -p ~/.kube
   ssh <user>@<server-ip> sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
   sed -i '' 's/127.0.0.1/<server-ip>/' ~/.kube/config
   chmod 600 ~/.kube/config
   ```

   If you already have a `~/.kube/config` for other clusters, save the file as
   `~/.kube/k3s-homelab.yaml` instead and `export KUBECONFIG=~/.kube/k3s-homelab.yaml`.
   If `sudo` on the node needs a password, the one-liner above can't prompt for it.
   Instead, SSH in, run `sudo cat /etc/rancher/k3s/k3s.yaml`, and paste the output
   into the file.

4. **Check that it works.** All 3 nodes should show `STATUS Ready`:

   ```bash
   kubectl get nodes
   helm version
   ```

## Trusted certificates

cert-manager runs a private **Homelab CA** that issues certificates for `*.home.lab`.
Grafana and Forgejo get theirs automatically and renew them before they expire.
Install it before the Grafana Ingress or Forgejo, then trust the CA once per device.
On macOS:

```bash
./scripts/install-cert-manager.sh
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/homelab-ca.crt
```

See [cert-manager/README.md](cert-manager/README.md) for other devices, keeping an
offline copy of the CA, alerts and adding certificates to new services.

## Quick start

Install. On first run it asks for a Grafana admin password (empty = generate one):

```bash
./scripts/install-monitoring.sh
kubectl get pods -n monitoring -w
```

First look: print the admin password, then forward Grafana and log in as `admin` at
http://localhost:3000. The port-forward runs until you press Ctrl+C:

```bash
./scripts/grafana-password.sh
./scripts/grafana-port-forward.sh
```

For a stable LAN address with no port-forward, apply the Ingress and point
grafana.home.lab at any node's IP:

```bash
kubectl apply -f monitoring/grafana-ingress.yaml
NODE_IP=192.168.0.151
echo "$NODE_IP grafana.home.lab" | sudo tee -a /etc/hosts
```

The Ingress serves HTTPS only, with a certificate from the Homelab CA (see
"Trusted certificates"). Plain `http://` isn't routed.

Starting dashboards: **Node Exporter / Nodes**, **Kubernetes / Compute Resources / Cluster**,
**Kubernetes / Compute Resources / Namespace (Pods)**.

**If ufw is already on your nodes** with per-port rules from the cluster setup, Prometheus
can only scrape node-exporter on its own node. The others time out, and the Nodes dashboard
shows one machine. Allow 9100 from the cluster, and nothing else, on each node:

```bash
for node in <node1-ip> <node2-ip> <node3-ip>; do
  ssh -t <user>@$node 'for src in <node1-ip> <node2-ip> <node3-ip> 10.42.0.0/16; do
    sudo ufw allow from $src to any port 9100 proto tcp comment node-exporter; done'
done
```

## What `values.yaml` changes from the chart defaults

- **Persistent storage.** Prometheus (10Gi) and Grafana (2Gi) store data on `local-path`
  volumes, so metrics and dashboards survive pod restarts. `local-path` pins each volume
  to one node, so losing that node loses the data until Longhorn replaces it.
- **Retention.** Prometheus keeps metrics for 15 days or 8GB, whichever limit is hit first.
- **Resource limits.** Memory requests and limits for Prometheus and Grafana.
- **k3s fixes.** Scraping of the scheduler, controller-manager, kube-proxy and etcd is turned
  off. k3s embeds them, so they would otherwise show as permanently down.

The chart version is pinned in `scripts/install-monitoring.sh` (`CHART_VERSION`). To upgrade,
read the chart's upgrade notes first, because `helm upgrade` does not update the CRDs.

## Hardening

### In this repo

- **Grafana password in a Secret.** The install script asks for the password and stores it
  in the `grafana-admin` Secret. It never appears in shell history, process listings or Helm's
  release history. Grafana only applies it the first time it starts. To change it later:

  ```bash
  kubectl exec -n monitoring deploy/monitoring-grafana -c grafana -- \
    grafana cli admin reset-admin-password '<new-password>'
  ```

  Then update the Secret to the same value so `grafana-password.sh` stays correct.
  Note that `'<new-password>'` on the command line lands in your shell history; prefix the
  command with a space if your shell is set to skip those (zsh: `setopt HIST_IGNORE_SPACE`).

- **Network policies.** Prometheus and Alertmanager have no login. `network-policies.yaml`
  lets only pods in the `monitoring` namespace reach them, and only Traefik reach Grafana.
  `kubectl port-forward` still works.

- **Grafana settings.** Sign-up, anonymous access, Gravatar, external snapshots and
  usage reporting are explicitly off in `values.yaml`.

### On your laptop and nodes

These run outside the repo, so the install script doesn't do them.

**Protect the kubeconfig.** `~/.kube/config` holds a cluster-admin certificate. Anyone
with the file controls the cluster. Lock down the file, and on macOS check that
`fdesetup status` says "FileVault is On":

```bash
chmod 600 ~/.kube/config
fdesetup status
```

Never commit it. Kubernetes can't revoke a client certificate, so if the file leaks the
only fix is rotating the cluster CA (`k3s certificate rotate-ca`; see the k3s docs). That
re-issues every certificate in the cluster.

**Firewall each node.** By default every node exposes the k3s API (6443) and node-exporter
(9100, unauthenticated host metrics) to the whole LAN. Run this on **each** node,
replacing the `<...>` placeholders. Add the SSH rule first, or enabling ufw will lock
you out. The rules allow, in order:

1. SSH and the k3s API (for kubectl and helm) from your laptop.
2. Everything from the other cluster nodes: API, kubelet, flannel VXLAN, node-exporter.
3. The k3s pod and service networks. Without these, pod traffic breaks.
4. Traefik on 80/443 from the LAN, only needed for the Grafana and Forgejo Ingresses.

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow from <laptop-ip> to any port 22 proto tcp
sudo ufw allow from <laptop-ip> to any port 6443 proto tcp

sudo ufw allow from <node1-ip>
sudo ufw allow from <node2-ip>
sudo ufw allow from <node3-ip>

sudo ufw allow from 10.42.0.0/16
sudo ufw allow from 10.43.0.0/16

sudo ufw allow from <lan-cidr> to any port 80,443 proto tcp

sudo ufw enable
sudo ufw status numbered
```

Afterwards, `kubectl get nodes` from the laptop should still work. From any other machine
on the LAN, `curl http://<node-ip>:9100/metrics` should hang.

**Encrypt Secrets at rest.** Unless the server was started with `--secrets-encryption`,
k3s stores Secrets, including `grafana-admin`, unencrypted in its datastore. On the
server node, check first:

```bash
sudo k3s secrets-encrypt status
```

If it says `Encryption Status: Disabled`, turn it on, re-encrypt the Secrets that
already exist, and check that the status now says `Enabled`:

```bash
sudo k3s secrets-encrypt enable
sudo systemctl restart k3s
sudo k3s secrets-encrypt reencrypt
sudo k3s secrets-encrypt status
```

Take a backup of `/var/lib/rancher/k3s/server` first. The steps differ for multi-server
clusters, so check the k3s docs for your version.

## Next up

MetalLB (real LoadBalancer IPs), Longhorn (replicated storage), Pi-hole (LAN DNS + ad-blocking).
