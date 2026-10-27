# Forgejo + Forgejo Actions

A self-hosted Git server ([Forgejo](https://forgejo.org)) and CI/CD runner (Forgejo
Actions) on the k3s cluster from the **Back to On-Prem** series.

## Layout

```
forgejo/values.yaml            Helm overrides for the Forgejo chart (hardened app.ini)
forgejo/namespaces.yaml        forgejo (Pod Security: restricted), forgejo-runner (privileged)
forgejo/runner.yaml            Actions runner + Docker-in-Docker sidecar
forgejo/network-policies.yaml  Who can reach Forgejo; what CI jobs can reach
forgejo/coredns-custom.yaml    Resolves forgejo.home.lab to Traefik inside the cluster
scripts/install-forgejo.sh     Installs/upgrades everything and registers the runner
```

## What this installs

1. **Forgejo**, from the official chart (`oci://code.forgejo.org/forgejo-helm/forgejo`),
   with SQLite on a `local-path` volume and an HTTPS Ingress at `forgejo.home.lab`,
   using a certificate from the Homelab CA.
2. **A Forgejo Actions runner** that runs jobs from `.forgejo/workflows/*.yml`, using
   GitHub Actions-compatible syntax. It's a plain manifest, based on the runner's
   official Kubernetes example: no maintained Helm chart for the runner exists.

## Prerequisites

- The k3s cluster from Part 2, all nodes `Ready`, with `kubectl` and `helm` on your
  workstation. The monitoring stack isn't required.
- cert-manager and the Homelab CA, with the CA trusted on your workstation (see
  "Trusted certificates" in the main README).
- `openssl` and `xxd` (both included with macOS and most Linux distributions).

## Install

Run `./scripts/install-cert-manager.sh` first if you haven't already, then:

```bash
./scripts/install-forgejo.sh
```

On the first run it asks for:

1. **An admin username and password**, for administration only. Leave the
   password empty to generate one.
2. **An everyday username and email**, for a normal, non-admin account you use for
   your own repos. Forgejo prints a one-time password for it and asks for a new one
   at first login. Set `FORGEJO_USER` and `FORGEJO_USER_EMAIL` to skip these prompts.

It then installs the chart, registers the runner for the everyday account's repos
and applies the network policies. Re-running upgrades in place and leaves both
accounts and the runner registration alone.

Then point the hostname at any node, setting `NODE_IP` to one of your nodes' IPs:

```bash
NODE_IP=192.168.0.151
echo "$NODE_IP forgejo.home.lab" | sudo tee -a /etc/hosts
```

Open **https://forgejo.home.lab** and log in with each account once. Forgejo asks
you to set up two-factor authentication: scan the QR code with an authenticator
app, and save the recovery codes it shows somewhere safe. To print a generated
admin password:

```bash
kubectl get secret -n forgejo forgejo-admin -o jsonpath='{.data.password}' | base64 --decode; echo
```

Use the everyday account from then on, and the admin account only for
administration. As the everyday user, **Settings → Actions → Runners** should list
`k3s-runner` as online.

## Using Git

SSH is disabled, so clone and push over HTTPS. Create an access token under
**Settings → Applications** and use it as the password; your account password
won't work for Git once 2FA is on.

Git on macOS uses its own certificate list, not the Keychain, so point it at the
Homelab CA for this host only:

```bash
git config --global http.https://forgejo.home.lab/.sslCAInfo ~/homelab-ca.crt
```

## Test the runner

Add `.forgejo/workflows/test.yml` to any repo owned by the everyday account:

```yaml
on: [push]
jobs:
  hello:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: echo "CI is running on my own hardware"
```

Push a commit, and the job appears under the repo's **Actions** tab.

`actions/checkout` clones from `https://forgejo.home.lab`, the same address your
browser uses. Inside the cluster, `coredns-custom.yaml` resolves that name to Traefik,
and job containers trust the Homelab CA for that host only: Git through a
host-scoped `sslCAInfo`, Node through `NODE_EXTRA_CA_CERTS`, which adds to its
built-in list rather than replacing it.

## Hardening

**Forgejo**

- Runs the rootless image as UID 1000 with a read-only root filesystem, no Linux
  capabilities and no Kubernetes API token. The `forgejo` namespace enforces Pod
  Security `restricted`, so Kubernetes refuses anything less locked down.
- The admin login lives in the `forgejo-admin` Secret, which the install script
  creates from a hidden prompt. It never appears in a file, in shell history or in
  Helm's release history. `passwordMode: initialOnlyNoReset` sets it on the first
  install only, so changing it in the UI sticks.
- Every account must use two-factor authentication
  (`GLOBAL_TWO_FACTOR_REQUIREMENT: all`). Git and the API then need access tokens,
  so a leaked password alone gets nobody in.
- Registration is closed, nothing is visible without logging in, and new
  repositories are private. Passwords need 12+ characters with mixed case and digits.
- Daily work happens in a non-admin account, so a leaked token or session from
  everyday use can't change instance settings or other users.
- HTTPS only, with a certificate from the Homelab CA and secure, `SameSite=strict`
  session cookies. Sessions are stored in the database, so restarts and upgrades
  don't log you out. The SSH server is off, so there's no extra port to expose.
  OpenID sign-in and update checks are off.
- Only Traefik (for the Ingress) and the runner can reach Forgejo's web port.

**Runner**

- The runner container is unprivileged, non-root, with a read-only root filesystem.
  Only the Docker-in-Docker sidecar is privileged, and only the `forgejo-runner`
  namespace allows that.
- Jobs don't get access to the Docker daemon (`docker_host: "-"`). A job that could
  reach the privileged daemon could start a privileged container and take over the
  node. The trade-off: jobs can't run `docker build`.
- Jobs can reach Forgejo (directly, and through Traefik for `actions/checkout`), DNS
  and the internet, but not your LAN, the nodes, the Kubernetes API or other pods.
  Nothing can connect in to the runner.
- The runner is scoped to the everyday account, so only that account's repos can
  send it jobs. Any other account added later can't run code on it.
- Registration uses a shared secret generated by the install script. It's passed on
  stdin and stored only in the `forgejo-runner` Secret, never in a file or ConfigMap.

## The Docker-in-Docker trade-off

The runner needs a container engine for each job. Mounting the node's own Docker or
containerd socket would hand every job root on the node. Docker-in-Docker gives the
runner its own engine instead, but that engine has to run privileged, which is still
root-equivalent on the node if something escapes it.

For your own repos on a single-user homelab, that's a reasonable trade-off, and it's
the setup the runner's own Kubernetes example uses. Don't run untrusted code through
it, such as pull requests from strangers. That needs stronger isolation (gVisor, Kata
Containers, or a separate VM).

## Changing the admin password

Change it in the UI: **Settings → Account**. The Secret is only read on the first
install, so update it too if you want it to stay in sync.

If you lose your 2FA device, log in with a recovery code. If those are gone too,
remove 2FA from the command line, then set it up again at the next login:

```bash
kubectl exec -n forgejo deploy/forgejo -c forgejo -- \
  forgejo admin user reset-mfa --username <user>
```

## Upgrading

The chart version is pinned as `CHART_VERSION` in `scripts/install-forgejo.sh`, and the
runner and Docker images in `forgejo/runner.yaml`. Read the release notes, bump the
version and re-run the script. Forgejo upgrades its database on start, so back up
the `gitea-shared-storage` volume first.
