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
    node_exporter/         # native prometheus-node-exporter (job node-pve)
    pve_api_token/         # read-only API token + writes core/pve-exporter/pve.yml
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
   (systemd, no Docker on the hypervisor). This is what the hub scrapes as job
   `node-pve` (host CPU/RAM/disk/temp).
3. **pve_api_token** — creates the read-only `prometheus@pve` user + token and writes
   the token into `core/pve-exporter/pve.yml` **on the rpi5** automatically.

Then bring up the hub-side exporter with the new credentials:

```bash
cd ~/pi-infra
./scripts/deploy.sh              # recreates pve-exporter with the written pve.yml
```

Verify:

```bash
docker compose exec -T prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=up%7Bjob=~%22pve%7Cnode-pve%22%7D'
```

## Useful tag runs

```bash
ansible-playbook playbooks/bootstrap-pve.yml --tags observability   # skip postinstall
ansible-playbook playbooks/bootstrap-pve.yml --tags postinstall --check --diff  # dry-run
```

## Notes / conventions

- **Secrets stay out of git.** The only secret produced is the PVE token, written to
  `core/pve-exporter/pve.yml` (already gitignored). No Ansible Vault is needed yet; if
  you add one, keep the vault password file out of git (see `.gitignore`).
- **Idempotency:** the token is created only if missing. If it already exists, PVE
  won't reveal the secret again — the role tells you how to rotate it.
- Roles use only `ansible.builtin`, so no collection install is strictly required to
  bootstrap the node.
