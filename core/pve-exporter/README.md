# Proxmox VE observability

Metrics, probes and alerts for the **Proxmox VE server** (`pve`), surfaced in the
shared Grafana / Alertmanager (→ Discord) like every other host.

| Address | What | Notes |
|---------|------|-------|
| `192.168.1.14` | mgmt NIC (onboard) · `pve.negri.es` | node-exporter :9100, SSH probe, PVE API :8006 |
| `10.10.10.10` | 10G Mellanox NIC | isolated point-to-point net (10.10.10.0/24) with the W11 box (`10.10.10.11`); NOT routable from the hub — link health via node-exporter (`PveTenGLinkDown`) |
| `pve-web.negri.es` | web panel | NPM → `https://192.168.1.14:8006` (self-signed upstream) |

## What runs where

- **On the pve node** (installed by the Ansible bootstrap, `ansible/`):
  native `prometheus-node-exporter` (systemd, no Docker on the hypervisor) →
  Prometheus job **`node-pve`** (host CPU/RAM/disk/temp of the 10900KF).
- **On the rpi5 hub** (`core/`, this dir):
  - **pve-exporter** → job **`pve`**: PVE REST API metrics (per-node CPU/RAM/uptime,
    per-guest VM/LXC status, storage usage). Config `core/pve-exporter/pve.yml`
    (gitignored — holds the API token; copy from `pve.yml.example`).
  - **Blackbox** probes: `pve-ssh` (TCP:22 userspace liveness) and `pve-web` (HTTPS to
    the panel, `http_2xx_insecure` module). The 10G NIC is on an isolated net the hub
    can't reach, so it's watched via node-exporter (`PveTenGLinkDown`), not Blackbox.
  - **Alerts**: `core/prometheus/rules/pve-alerts.yml` (groups `host-pve` + `pve`).
  - **Dashboards**: Grafana folder **Proxmox** — `pve-overview` (committed) and the
    community *Proxmox via Prometheus* (fetched by `scripts/fetch-dashboards.sh`).
    Full host detail is also in *Node Exporter Full* (pick `job=node-pve`).
  - **Homepage** card *Proxmox VE* (native `proxmox` widget).

## Fastest path: Ansible bootstrap

The Ansible bootstrap (`ansible/`, control node = rpi5) does the node-side setup for
you — installs native node-exporter AND creates the API token, writing this file
(`core/pve-exporter/pve.yml`) automatically:

```bash
cd ~/pi-infra/ansible && ansible-playbook playbooks/bootstrap-pve.yml
cd ~/pi-infra && ./scripts/deploy.sh          # bring up pve-exporter with the token
```

See `ansible/README.md`. **If you ran the bootstrap, you're done — skip §1 below.**
The homepage-widget env vars (§2) and the NPM proxy (§3) are the only bits Ansible
does not do.

## Manual alternative — ONLY if you're not using Ansible

> Skip this whole §1 when you used the Ansible bootstrap above; it already created the
> token and wrote `pve.yml`. §2 and §3 apply either way.

### 1. Read-only API token for pve-exporter (Ansible does this for you)

In the PVE node shell (Datacenter → Shell, or SSH as root):

```bash
pveum user add prometheus@pve
pveum aclmod / -user prometheus@pve -role PVEAuditor
pveum user token add prometheus@pve prometheus --privsep 0
#   -> copy the printed token "value" NOW (shown only once)
```

Then on the hub:

```bash
cp core/pve-exporter/pve.yml.example core/pve-exporter/pve.yml
# edit pve.yml: paste the token value into token_value
```

`PVEAuditor` is read-only (no changes to VMs/config). `--privsep 0` lets the token use
the user's full (audit) privileges without a separate ACL.

### 2. (Optional) same token for the homepage widget

The homepage *Proxmox VE* card can reuse the same token. In `.env` set:

```
PVE_TOKEN_ID=prometheus@pve!prometheus
PVE_TOKEN_SECRET=<the token value>
```

Empty → the card still links + pings, just no live widget data.

### 3. Publish the panel via NPM (already noted as done)

`pve-web.negri.es` → `https://192.168.1.14:8006`. In NPM the upstream is HTTPS with a
self-signed cert, so enable the proxy host with SSL and **don't** verify the upstream
cert (NPM's "Websockets Support" on is also recommended for the noVNC console).

## Deploy / verify

Config lives in the hub stack, so a normal `scripts/deploy.sh` picks it up (it
recreates `pve-exporter` when `core/pve-exporter/` changes — single-file bind mount).
Verify from the hub:

```bash
# pve-exporter reachable and authenticated (expect metrics, not an auth error)
docker compose exec -T prometheus wget -qO- \
  'http://pve-exporter:9221/pve?target=192.168.1.14&module=default' | head

# both jobs up
docker compose exec -T prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=up%7Bjob=~%22pve%7Cnode-pve%22%7D'
```

## Notes

- **`pve` vs `node-pve`**: the API exporter (`pve`) sees the *virtualization* layer
  (guests, storage, cluster); node-exporter (`node-pve`) sees the *host* (real CPU
  cores, RAM, disks, coretemp). Both are wanted — they don't overlap.
- The pve-exporter polls the API on every scrape, so the `pve` job runs at 30s.
- Guest **down** is intentionally NOT alerted (stopped VMs are legitimate). The
  `pve` alert group covers exporter/scrape failure, node offline, and storage full.
