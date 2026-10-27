# cert-manager + Homelab CA

A private certificate authority for `*.home.lab`, run by
[cert-manager](https://cert-manager.io). Grafana, Forgejo and anything added later
get real certificates that your devices trust, renewed automatically.

## Layout

```
cert-manager/values.yaml        Helm overrides for the cert-manager chart
cert-manager/homelab-ca.yaml    The CA certificate and the ClusterIssuers
cert-manager/monitoring.yaml    Extra values when the monitoring stack is installed
cert-manager/alerts.yaml        Prometheus alerts for certificates
scripts/install-cert-manager.sh Installs/upgrades everything and exports the CA
```

## How it works

```
selfsigned-bootstrap ──signs──▶ Homelab CA (10 years, home.lab names only)
                                    │
                         ClusterIssuer homelab-ca
                                    │ signs, renews at 30 days left
              ┌─────────────────────┼─────────────────────┐
         grafana-tls           forgejo-tls           <future>-tls
       (90-day certificates, stored as Secrets and served by Traefik)
```

1. `selfsigned-bootstrap` exists only to sign the CA certificate once.
2. The **Homelab CA** is a 10-year ECDSA certificate. Its private key stays in the
   `homelab-ca` Secret in the `cert-manager` namespace.
3. The `homelab-ca` **ClusterIssuer** signs certificates for any namespace.
4. An Ingress asks for one with an annotation and a `secretName`. cert-manager
   issues it, stores it in that Secret and renews it automatically.

The CA has an X.509 **name constraint**: it can only sign `home.lab` names. Your
devices trust it for everything, so this limits the damage if its key ever leaks.
It can't be used to impersonate a real website.

## Install

Install the monitoring stack first if you want certificate alerts (see Alerts).

```bash
./scripts/install-cert-manager.sh
```

The script installs cert-manager (pinned as `CHART_VERSION`), creates the CA,
waits until it's ready and saves the **public** CA certificate to
`~/homelab-ca.crt`. Re-running it is safe; it never replaces an existing CA.

## Trust the CA on your devices

Do this once per device. After that, every `*.home.lab` certificate is trusted.

| Device | How |
|---|---|
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/homelab-ca.crt` |
| Firefox | Uses its own store. If it still warns, set `security.enterprise_roots.enabled` to `true` in `about:config`, or import the file under **Settings → Privacy & Security → Certificates** |
| Debian/Ubuntu | `sudo cp homelab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |
| Windows | In an admin terminal: `certutil -addstore -f Root homelab-ca.crt` |
| iPhone/iPad | AirDrop or email the file, install the profile in **Settings**, then turn it on under **General → About → Certificate Trust Settings** |
| Git (any OS) | Git may use its own list: `git config --global http.https://forgejo.home.lab/.sslCAInfo ~/homelab-ca.crt` |

## Using it for a new service

Add the annotation and a `tls` block with a `secretName` to the Ingress:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: homelab-ca
spec:
  tls:
    - secretName: myapp-tls
      hosts:
        - myapp.home.lab
```

The name must end in `.home.lab`, or the name constraint makes browsers reject it.

## Checking it

Every certificate should be `READY True`. A new one takes a few seconds to issue.

```bash
kubectl get certificate -A
kubectl describe certificate -n monitoring grafana-tls
```

From your workstation, `Verify return code: 0 (ok)` means the chain is trusted:

```bash
openssl s_client -connect grafana.home.lab:443 -servername grafana.home.lab \
  -CAfile ~/homelab-ca.crt </dev/null 2>/dev/null | grep 'Verify return code'
```

If that passes but the browser still warns, fully quit and reopen it (Cmd+Q on
macOS). Browsers remember certificate decisions for sites already visited.

## Keep an offline copy of the CA

Every device trusts this exact CA. If the `homelab-ca` Secret is lost (a rebuilt
cluster, say), the script creates a new CA and every device has to trust it again.
Copy it once, after the first install:

```bash
kubectl get secret -n cert-manager homelab-ca -o yaml |
  grep -vE '^\s+(resourceVersion|uid|creationTimestamp):' | pbcopy
```

Paste it into a password manager as a secure note. Don't save it as a plain file:
it contains the CA's private key. To restore, apply it before running the install
script, and cert-manager reuses it instead of creating a new CA:

```bash
kubectl create namespace cert-manager
pbpaste | kubectl apply -f -
```

## Alerts

If the monitoring stack is installed, the script has Prometheus scrape
cert-manager and adds three alerts (`alerts.yaml`):

- **CertificateNotReady**: a certificate has been failing for 15 minutes.
- **CertificateExpiringSoon**: under 14 days left. Renewal happens at 30, so this
  means renewal is failing.
- **CertManagerDown**: Prometheus can't scrape cert-manager.

If you install monitoring after cert-manager, re-run the script to add them. Until
Alertmanager has a receiver, they show in Grafana under **Alerting → Alert rules**.

## Hardening

- The CA's private key never leaves the cluster. The script exports only the public
  certificate.
- The name constraint limits the CA to `home.lab`, even for a device that trusts it.
- cert-manager's chart already runs non-root, with a read-only root filesystem,
  all Linux capabilities dropped and seccomp `RuntimeDefault`.

## Upgrading

The chart version is pinned as `CHART_VERSION` in `scripts/install-cert-manager.sh`.
cert-manager supports upgrading one minor version at a time (1.21 → 1.22, not
1.21 → 1.23). Read the release notes, bump the version and re-run the script.
