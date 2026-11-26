# Home Assistant

[Home Assistant](https://www.home-assistant.io) (the container install) at
**https://ha.home.lab**, with a certificate from the Homelab CA. LAN only: nothing
is reachable from the internet.

## Layout

```
homeassistant/namespace.yaml         Pod Security "baseline" (the container runs as root)
homeassistant/homeassistant.yaml     Deployment, config volume, Service, Ingress
homeassistant/network-policies.yaml  Only Traefik in; LAN and internet out, not the cluster
scripts/install-homeassistant.sh     Installs/upgrades all of it
```

## Prerequisites

- The k3s cluster from Part 2, with `kubectl` on your workstation (see the main
  README).
- cert-manager and the Homelab CA, with the CA trusted on your workstation (see
  [cert-manager/README.md](../cert-manager/README.md)).
- The `local-path` storage class, which k3s ships with. The script checks for it
  and for the CA.

## Install

```bash
./scripts/install-homeassistant.sh
```

The first start takes a few minutes while Home Assistant installs the packages for
its default integrations. Then point the hostname at any node, setting `NODE_IP` to
one of your nodes' IPs:

```bash
NODE_IP=192.168.0.151
echo "$NODE_IP ha.home.lab" | sudo tee -a /etc/hosts
```

Open **https://ha.home.lab** and create the owner account. During onboarding,
set your home's location and time zone: Home Assistant uses them for sun-based
automations and history.

## What's configured

On the first start, an init container writes two files to the config volume:

- **`configuration.yaml`**, with Home Assistant's defaults.
- **`.storage/http`**, which tells Home Assistant to trust the pod network, where
  Traefik runs. Home Assistant rejects every request that comes through a reverse
  proxy it doesn't trust, with `400: Bad Request`.

The proxy setting goes in `.storage/http`, not in an `http:` block in
`configuration.yaml`. Home Assistant imports an `http:` block from YAML only as a
trial that must be confirmed in the UI, and the UI can't be reached through
Traefik until the proxy is trusted. Don't add an `http:` block to
`configuration.yaml`.

After the first start, both files in the volume are yours: re-running the script
never overwrites them. To edit `configuration.yaml`:

```bash
kubectl exec -it -n homeassistant deploy/homeassistant -- vi /config/configuration.yaml
kubectl rollout restart deploy/homeassistant -n homeassistant
```

Most settings and all integrations are configured in the UI instead.

## Devices and discovery

The pod uses the cluster's pod network, not your LAN directly. What that means:

| Works | Doesn't work yet |
|---|---|
| Cloud integrations (Tuya, Google, Tapo cloud, weather, etc.) | Automatic discovery of devices (mDNS, SSDP, HomeKit), so they don't show up under **Discovered** |
| Local devices you add by IP address (Philips Hue bridge, Shelly, ESPHome, many Wi-Fi plugs) | Devices that only work through broadcast discovery, like Chromecast and some Sonos setups |
| The mobile app on your home Wi-Fi | Bluetooth, Zigbee and Z-Wave dongles (no USB passthrough) |

For discovery, the pod needs `hostNetwork: true` in `homeassistant.yaml`. That
shares the node's network stack, which Pod Security "baseline" blocks, so the
namespace would need `enforce: privileged`, as `monitoring` has for node-exporter.
For Zigbee or Z-Wave, a network-attached coordinator or Zigbee2MQTT on a small
separate device keeps the dongle out of Kubernetes. Both are deliberate next steps,
not defaults.

## Caveats

- **One node.** `local-path` pins the config volume to the node where it was
  created. If that node is down, so is Home Assistant, until Longhorn replaces
  `local-path`.
- **No add-ons.** The add-on store only exists in Home Assistant OS. Anything you'd
  install as an add-on (Mosquitto, Zigbee2MQTT, ESPHome) runs as its own
  Deployment instead.
- **Scanned by Trivy.** The image shows up on the Homelab Security dashboard (see
  [security/README.md](../security/README.md)).

## Hardening

- **No Kubernetes API access.** The pod has its own ServiceAccount with no token
  mounted.
- **Network.** Only Traefik can reach the UI. Home Assistant can reach your LAN
  (for devices) and the internet (for integrations and updates), but not the
  cluster nodes, other pods or the Kubernetes API, so a compromised integration
  can't pivot into the cluster. The node IPs are in `network-policies.yaml`;
  change them if yours differ.
- **Pod Security "baseline".** The container runs as root, which "restricted"
  forbids, but it gets no privileges beyond the runtime's defaults: no privilege
  escalation, the `RuntimeDefault` seccomp profile, no host access. Applying the
  manifests prints "restricted" warnings because of that; they're expected.
- **Image pinned by digest.** A repointed tag can't change what runs.
- **Accounts.** Create the owner account with a strong password, then turn on
  multi-factor authentication under your profile (**Profile → Security**).

## Upgrading

Home Assistant releases monthly, with patch releases in between. Pick a release
that's at least a week old, read its release notes for breaking changes, then
update the tag and digest in `homeassistant.yaml` (both the init and the main
container) and re-run the script. The digest for each version is listed on the
image's package page, github.com/home-assistant/core/pkgs/container/home-assistant.

Home Assistant migrates its database on start. Back up first: **Settings → System
→ Backups** creates a backup in the config volume, which you can download.
