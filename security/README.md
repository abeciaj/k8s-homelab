# Vulnerability scanning

Two tools, covering different layers:

- **[Trivy Operator](https://github.com/aquasecurity/trivy-operator)** runs in the
  cluster and scans every running image for known vulnerabilities (CVEs) and
  secrets baked into images. It also audits workload settings and RBAC, and keeps
  the reports up to date as images change.
- **[kube-bench](https://github.com/aquasecurity/kube-bench)** checks k3s itself
  against the CIS Kubernetes Benchmark: API server flags, file permissions, kubelet
  settings. Run it on demand, not continuously.

## Layout

```
security/values.yaml            Helm overrides for the Trivy Operator chart
security/namespace.yaml         trivy-system, enforcing Pod Security "restricted"
security/network-policies.yaml  Who can reach the Trivy server and operator metrics
security/monitoring.yaml        Extra values when the monitoring stack is installed
security/alerts.yaml            Prometheus alerts for fixable critical CVEs and secrets
security/dashboard.json         Grafana dashboard, loaded by the script
scripts/install-trivy-operator.sh  Installs/upgrades Trivy Operator
scripts/run-kube-bench.sh          Runs the k3s CIS benchmark on a node over SSH
```

## Install Trivy Operator

Install the monitoring stack first if you want metrics and alerts.

```bash
./scripts/install-trivy-operator.sh
```

The first scans start right away and take a few minutes, a few at a time. After
that, an image is rescanned when a workload changes and every 24 hours otherwise,
so new CVEs in images you already run get picked up.

## Reading the reports

Each report is a Kubernetes object next to the workload it describes. List the
vulnerability counts for every image:

```bash
kubectl get vulnerabilityreports -A -o wide
```

To see the CVEs in one image, with the installed and fixed versions, pick a report
name from that list:

```bash
kubectl get vulnerabilityreport -n <namespace> <name> -o jsonpath='{range .report.vulnerabilities[*]}{.severity}{"\t"}{.vulnerabilityID}{"\t"}{.resource}{"\t"}{.installedVersion}{" -> "}{.fixedVersion}{"\n"}{end}'
```

The other reports:

| Report | Command |
|---|---|
| Secrets found in images | `kubectl get exposedsecretreports -A -o wide` |
| Risky workload settings | `kubectl get configauditreports -A -o wide` |
| Over-broad RBAC | `kubectl get rbacassessmentreports -A -o wide` |
| NSA and Pod Security compliance | `kubectl get clustercompliancereports -o wide` |

Reports only list **high and critical vulnerabilities with a fix available**, so
everything in them is something you can act on, usually by bumping a pinned chart
or image version. To see every finding, set `trivy.severity` and
`trivy.ignoreUnfixed` back to the chart defaults in `values.yaml`.

## Dashboard

With the monitoring stack installed, the script also loads a Grafana dashboard,
**Homelab Security** (search for it under **Dashboards**). Grafana picks it up
within a minute; nothing to import.

**Containers (Trivy Operator)**

| Panels | Show |
|---|---|
| Cards | Critical, high, affected images, images scanned, exposed secrets, config issues |
| By severity, Trend | The current split, and how the totals change over time |
| Most vulnerable images, Config issues by namespace | Where to start: the 10 images whose update clears the most findings |
| Issues | Every finding: CVE, severity, score, image, package, installed and fixed version. Click a CVE to open it in NVD; filter any column from its header |

Each image is counted once, even if several workloads run it. The trend only
starts from the install, so it fills in over the following days.

**Nodes (Lynis and debsecan)**

| Panels | Show |
|---|---|
| Hardening index | Each node's Lynis score out of 100: red below 60, orange below 75 |
| Lynis warnings, Fixable CVEs | Per node, green at 0 |
| Last audit | How long ago each node was audited |
| Hardening index over time | One point per audit, so you can see a change move the score |

These come from the Ansible audit play in ansible-homelab
(`ansible-playbook site.yml --tags audit -K`). It writes the results to
`/var/lib/node_exporter/textfile_collector/audit.prom` on each node, and
node-exporter's textfile collector (enabled in `monitoring/values.yaml`) exposes
them to Prometheus. They only change when the audit runs. The alerts for them are
in `monitoring/node-audit-alerts.yaml`.

The dashboard is `security/dashboard.json`, kept in the repo. Changes made in the
Grafana UI are lost when the script runs again, so to change it for good, edit the
dashboard in Grafana, then use **Export → Export as JSON** and save the result over
`dashboard.json`.

## Alerts

With the monitoring stack installed, the script adds three alerts (`alerts.yaml`):

- **CriticalVulnerabilityInImage**: a running image has a critical CVE with a fix
  available.
- **SecretExposedInImage**: a running image contains something that looks like a
  secret (a key, token or password).
- **TrivyOperatorDown**: Prometheus can't scrape the operator.

If you install monitoring after Trivy Operator, re-run the script to add them. Until
Alertmanager has a receiver, they show in Grafana under **Alerting → Alert rules**.

## Run kube-bench

kube-bench's k3s checks read the node's systemd journal, so the script copies the
binary to the node over SSH and runs it there with sudo, then removes it. Nothing
stays installed and no privileged pod is involved. Run it against the server node:

```bash
./scripts/run-kube-bench.sh jay@192.168.0.151
```

It saves the report to `~/kube-bench-<date>.txt`. Each check shows as **PASS**,
**FAIL**, **WARN** (needs a manual look) or **INFO**, with a remediation for each
failure at the end of its section. The agents only run the kubelet, so check them
with the node section alone:

```bash
TARGETS=node ./scripts/run-kube-bench.sh jay@192.168.0.152
```

Not every FAIL needs fixing in a homelab. The k3s CIS hardening guide
(docs.k3s.io/security/hardening-guide) explains each one and the k3s flag that
addresses it. Re-run after k3s upgrades.

## Hardening

- Everything in `trivy-system`, including the scan jobs the operator creates, runs
  as non-root with a read-only filesystem, no capabilities and no host access. The
  namespace enforces Pod Security "restricted", so a pod that asks for more is
  rejected.
- **Supply chain.** The chart is verified against a pinned SHA-256 before install,
  and the operator and Trivy images are pinned by digest, so a re-published chart
  or a repointed image tag (what happened to Trivy in March 2026) is refused rather
  than run.
- **Network.** Nothing can reach pods in `trivy-system` except scan jobs reaching
  the Trivy server (which has no authentication) and Prometheus reaching the
  operator's metrics. The scan jobs and the Trivy server, which handle downloaded
  images and data, can only reach DNS, the Trivy server and the internet: not your
  LAN, the nodes or the Kubernetes API.
- The operator reads every workload and RBAC object in the cluster, which it needs
  in order to scan them. By default it can also read every Secret, to use
  workloads' image pull secrets. That would include the Homelab CA's private key,
  so `values.yaml` turns it off: it only touches Secrets in its own namespace.
  Every image here is public, so nothing is lost. If you add a private registry,
  put its pull secret in `trivy-system` and list it under
  `operator.privateRegistryScanSecretsNames`.

## Upgrading

Trivy releases were briefly compromised in March 2026 (advisory GHSA-69fq-xp46-6x23):
malicious builds were published under trusted version tags. Before bumping anything,
check the project's security advisories. Then update every pin for that version
together:

| Pin | Where | Take it from |
|---|---|---|
| `CHART_VERSION`, `CHART_SHA256` | `scripts/install-trivy-operator.sh` | The chart's `digest` in aquasecurity.github.io/helm-charts/index.yaml |
| `image.tag` (operator) | `security/values.yaml` | The chart's `appVersion`, plus that tag's digest on Docker Hub |
| `trivy.image.tag` | `security/values.yaml` | The chart's default `trivy.image.tag`, plus that tag's digest |
| `KUBE_BENCH_VERSION`, `KUBE_BENCH_SHA256` | `scripts/run-kube-bench.sh` | That release's `checksums.txt` |

Take each checksum from the published source, never by hashing what you downloaded:
that would just pin whatever you got.

`helm upgrade` doesn't update the chart's CRDs. If the release notes mention CRD
changes, apply them first from the chart's `crds/` folder:
`kubectl apply --server-side -f <chart>/crds/`.
