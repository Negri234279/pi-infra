# Ansible — fleet control from the rpi5

The **rpi5 is the Ansible control node**. Playbooks here bootstrap and integrate the
other machines (starting with the Proxmox VE server) into the pi-infra stack. Ansible
runs *on* the rpi5 and reaches the managed nodes over the LAN by SSH.

```
ansible/
  ansible.cfg              # points at inventory/, roles/ (run playbooks from here)
  inventory/hosts.yml      # rpi5 (local) · pve (192.168.1.14) · rpi3 (192.168.1.6)
  group_vars/all.yml       # shared vars
  requirements.yml         # optional Galaxy collections
  playbooks/
    site.yml               # everything
    bootstrap-pve.yml      # fresh Proxmox → into the stack
  roles/
    proxmox_postinstall/   # repos, nag, dist-upgrade, base pkgs, timezone
    node_exporter/         # native prometheus-node-exporter on the host (job node-pve)
    pve_exporter_lxc/      # LXC on the node running prometheus-pve-exporter (job pve)
    pve_api_token/         # read-only API token + writes pve.yml INSIDE that LXC
```

## One-time: set up the control node (on the rpi5)

```bash
sudo apt update && sudo apt install -y ansible          # Debian/RPiOS package is fine
cd ~/pi-infra/ansible
# (optional, for future community modules)
ansible-galaxy collection install -r requirements.yml

# Passwordless SSH to the fresh Proxmox (root SSH is on by default on a new install):
ssh-copy-id root@192.168.1.14

ansible -m ping proxmox                                 # expect: pve | SUCCESS
```

## Bootstrap the Proxmox node

Proxmox freshly installed, nothing changed → run the whole thing:

```bash
ansible-playbook playbooks/bootstrap-pve.yml
```

What it does (all idempotent — safe to re-run):

1. **proxmox_postinstall** — disables the paid *enterprise* apt repos, adds
   *pve-no-subscription*, removes the "No valid subscription" login nag,
   `apt dist-upgrade`s the box, installs base tools, sets the timezone.
   > A dist-upgrade may install a new kernel — **reboot** the node afterwards when
   > convenient. Set `pve_apt_upgrade: false` (group_vars) to skip the upgrade.
2. **node_exporter** — installs the native `prometheus-node-exporter` on `:9100`
   (systemd, **on the host** — an LXC can't expose the real host view). Scraped by the
   hub as job `node-pve` (host CPU/RAM/disk/temp).
3. **pve_exporter_lxc** — creates a lightweight Debian LXC on the node (VMID 150,
   `192.168.1.15`) running `prometheus-pve-exporter` on `:9221` under systemd. This is
   the job `pve` target, scraped by the hub over the LAN. Replaces the old Docker
   container that ran on the hub.
4. **pve_api_token** — creates the read-only `prometheus@pve` user + token and pushes
   the token into `/etc/prometheus/pve.yml` **inside the LXC** (via `pct push`), then
   restarts the exporter service.

No hub-side deploy step is needed for the exporter anymore. Verify (from the hub):

```bash
docker compose exec -T prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=up%7Bjob=~%22pve%7Cnode-pve%22%7D'
```

> **LXC IP.** `pve_exporter_lxc_ip` (group_vars/proxmox.yml, default `192.168.1.15/24`)
> must be a FREE LAN address and must match the `pve` job's target in
> `core/prometheus/prometheus.yml`. Change both together if you pick a different IP.
>
> **Migrating** from the old Docker exporter (rotate the pre-existing token so Ansible
> can write it into the LXC): see *Migrating from the old Docker exporter* in
> `core/pve-exporter/README.md`.

## Useful tag runs

```bash
ansible-playbook playbooks/bootstrap-pve.yml --tags observability   # skip postinstall
ansible-playbook playbooks/bootstrap-pve.yml --tags postinstall --check --diff  # dry-run
```

## Runs in Grafana (logs + annotations)

Wrap playbook runs with `run.sh` to surface them in the existing stack — no new
services, it reuses the journal→Alloy→Loki pipe and Grafana:

```bash
./run.sh playbooks/bootstrap-pve.yml            # same args as ansible-playbook
```

- **Logs (always on).** The run is copied into the systemd journal tagged
  `ansible`; Alloy already ships the journal to Loki, so in Grafana → Explore:
  `{job="systemd-journal", host="rpi5", identifier="ansible"}`. Live colored output
  still shows on your terminal. `profile_tasks` (in `ansible.cfg`) adds per-task
  timings to that log.
- **Annotations (opt-in).** Copy `.env.local.example` → `.env.local` and set
  `GRAFANA_URL` + a service-account `GRAFANA_API_KEY`. Then every run drops a
  start/end annotation on the dashboards (red if it fails), via the
  `community.grafana.grafana_annotations` callback. Install collections first:
  `ansible-galaxy collection install -r requirements.yml`.

`ansible-playbook` directly still works; you just don't get the journal copy or the
annotation. The relabel rule that exposes the `identifier` label lives in
`core/alloy/config.alloy` — reload Alloy after pulling (`./scripts/deploy.sh`).

## Notes / conventions

- **Secrets stay out of git.** The only secret produced is the PVE token, written to
  `/etc/prometheus/pve.yml` **inside the pve-exporter LXC** (never on the hub, never in
  the repo). No Ansible Vault is needed yet; if you add one, keep the vault password
  file out of git (see `.gitignore`).
- **Idempotency:** the token is created only if missing. If it already exists, PVE
  won't reveal the secret again — the role tells you how to rotate it.
- Roles use only `ansible.builtin`, so no collection install is strictly required to
  bootstrap the node.
