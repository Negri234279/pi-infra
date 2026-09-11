# Proxmox VE observability

Metrics, probes and alerts for the **Proxmox VE server** (`pve`), surfaced in the
shared Grafana / Alertmanager (→ Discord) like every other host.

| Address | What | Notes |
|---------|------|-------|
| `192.168.1.14` | mgmt NIC (onboard) · `pve.negri.es` | node-exporter :9100 (native, host), SSH probe, PVE API :8006 |
| `192.168.1.15` | pve-exporter LXC (VMID 150) | prometheus-pve-exporter :9221 → job `pve`; polls the API at `192.168.1.14:8006` |
| `10.10.10.10` | 10G Mellanox NIC | isolated point-to-point net (10.10.10.0/24) with the W11 box (`10.10.10.11`); NOT routable from the hub — link health via node-exporter (`PveTenGLinkDown`) |
| `pve-web.negri.es` | web panel | NPM → `https://192.168.1.14:8006` (self-signed upstream) |

## What runs where

Both exporters now live **on the pve node**; the rpi5 hub only scrapes them. Moving
the API poller onto the node it watches keeps the hub stack lean and means the
credentials + polling are local. node-exporter *has* to be native (an LXC can't
expose the real host view), so only the API poller was containerised.

- **On the pve node** (all set up by the Ansible bootstrap, `ansible/`):
  - native `prometheus-node-exporter` (systemd, **on the host** — no container) →
    Prometheus job **`node-pve`** (host CPU/RAM/disk/temp of the 10900KF).
  - a lightweight **LXC** (`pve-exporter`, VMID 150, `192.168.1.15`) running
    `prometheus-pve-exporter` on `:9221` under systemd → Prometheus job **`pve`**:
    PVE REST API metrics (per-node CPU/RAM/uptime, per-guest VM/LXC status, storage
    usage). Its config lives INSIDE the LXC at `/etc/prometheus/pve.yml` (holds the
    API token), written there by the `pve_api_token` role. Built by
    `ansible/roles/pve_exporter_lxc`.
- **On the rpi5 hub** (`core/`, this dir):
  - **Prometheus** scrapes the LXC over the LAN (`192.168.1.15:9221`, job `pve`) and
    node-exporter (`192.168.1.14:9100`, job `node-pve`). No exporter container here.
  - **Blackbox** probes: `pve-ssh` (TCP:22 userspace liveness) and `pve-web` (HTTPS to
    the panel, `http_2xx_insecure` module). The 10G NIC is on an isolated net the hub
    can't reach, so it's watched via node-exporter (`PveTenGLinkDown`), not Blackbox.
  - **Alerts**: `core/prometheus/rules/pve-alerts.yml` (groups `host-pve` + `pve`).
  - **Dashboards**: Grafana folder **Proxmox** — `pve-overview` (committed) and the
    community *Proxmox via Prometheus* (fetched by `scripts/fetch-dashboards.sh`).
    Full host detail is also in *Node Exporter Full* (pick `job=node-pve`).
  - **Homepage** card *Proxmox VE* (native `proxmox` widget).

## Fastest path: Ansible bootstrap

The Ansible bootstrap (`ansible/`, control node = rpi5) does the whole node-side setup
for you — installs native node-exporter, **creates the pve-exporter LXC**, creates the
API token and writes `pve.yml` **inside the LXC**:

```bash
cd ~/pi-infra/ansible && ansible-playbook playbooks/bootstrap-pve.yml
```

That's it for the exporter — there is **no hub-side deploy step** anymore (the exporter
no longer runs on the hub). Just make sure Prometheus points at the LXC IP (already set
in `core/prometheus/prometheus.yml`, job `pve` → `192.168.1.15:9221`) and reload it if
you changed it: `./scripts/deploy.sh`.

See `ansible/README.md`. **If you ran the bootstrap, you're done — skip §1 below.**
The homepage-widget env vars (§2) and the NPM proxy (§3) are the only bits Ansible
does not do.

### Migrating from the old Docker exporter

If you previously ran `pve-exporter` as a Docker container on the hub, after pulling
this change:

```bash
# hub: drop the old container + its stale (now unused) local config
cd ~/pi-infra && docker rm -f pve-exporter 2>/dev/null || true
rm -f core/pve-exporter/pve.yml           # was the hub bind-mount; token now lives in the LXC
./scripts/deploy.sh                        # recreate the stack without pve-exporter
```

The API token from the old setup already exists in PVE, so the bootstrap can't
re-read its secret to write it into the LXC. Rotate it once so Ansible writes fresh
credentials into the LXC:

```bash
# on the pve node (or via ssh root@192.168.1.14)
pveum user token remove prometheus@pve prometheus
# then re-run the bootstrap — it recreates the token and pushes pve.yml into the LXC
```

## Manual alternative — ONLY if you're not using Ansible

> Skip this whole §1 when you used the Ansible bootstrap above; it already created the
> LXC, the token and wrote `pve.yml` inside it. §2 and §3 apply either way.

### 1. LXC + read-only API token (Ansible does all of this for you)

On the PVE node (Datacenter → Shell, or SSH as root), create the token:

```bash
pveum user add prometheus@pve
pveum aclmod / -user prometheus@pve -role PVEAuditor
pveum user token add prometheus@pve prometheus --privsep 0
#   -> copy the printed token "value" NOW (shown only once)
```

Then create a small Debian LXC (e.g. VMID 150, `192.168.1.15`), and inside it:

```bash
apt-get update && apt-get install -y python3 python3-venv
python3 -m venv /opt/pve-exporter
/opt/pve-exporter/bin/pip install prometheus-pve-exporter==3.5.5
mkdir -p /etc/prometheus
# write /etc/prometheus/pve.yml from pve.yml.example, pasting the token value (0600)
# then a systemd unit running:
#   /opt/pve-exporter/bin/pve_exporter --config.file /etc/prometheus/pve.yml --web.listen-address :9221
```

`PVEAuditor` is read-only (no changes to VMs/config). `--privsep 0` lets the token use
the user's full (audit) privileges without a separate ACL. `pve.yml.example` in this
dir is the reference format for the in-LXC config.

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

The exporter runs in the LXC on the pve node, so there's nothing to deploy on the hub.
Verify:

```bash
# on the pve node: the exporter service is up inside the LXC
pct exec 150 -- systemctl is-active pve-exporter

# exporter reachable + authenticated from the hub (expect metrics, not an auth error)
docker compose exec -T prometheus wget -qO- \
  'http://192.168.1.15:9221/pve?target=192.168.1.14&module=default' | head

# both jobs up in Prometheus
docker compose exec -T prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=up%7Bjob=~%22pve%7Cnode-pve%22%7D'
```

If the scrape fails, check (1) the LXC has network + can reach `192.168.1.14:8006`,
(2) `/etc/prometheus/pve.yml` inside the LXC has a valid token (rotate + re-bootstrap
if it's a migration — see above), and (3) no PVE firewall rule is blocking `:9221`.

## Notes

- **`pve` vs `node-pve`**: the API exporter (`pve`, in the LXC) sees the
  *virtualization* layer (guests, storage, cluster); node-exporter (`node-pve`, native
  on the host) sees the *host* (real CPU cores, RAM, disks, coretemp). Both are wanted
  — they don't overlap, and node-exporter must stay on the host to see it truthfully.
- The pve-exporter polls the API on every scrape, so the `pve` job runs at 30s.
- Guest **down** is intentionally NOT alerted (stopped VMs are legitimate). The
  `pve` alert group covers exporter/scrape failure, node offline, and storage full.
