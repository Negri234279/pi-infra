# Ansible — fleet control from the rpi5

The **rpi5 is the Ansible control node**. Playbooks here bootstrap and integrate the
other machines (starting with the Proxmox VE server) into the pi-infra stack. Ansible
runs *on* the rpi5 and reaches the managed nodes over the LAN by SSH.

```
ansible/
  ansible.cfg              # points at inventory/, roles/ (run playbooks from here)
  inventory/
    hosts.yml              # rpi5 (local) · pve (192.168.1.14) · rpi3 (192.168.1.6) · dev-vm
    group_vars/            # all.yml (shared) · proxmox.yml · dev.yml — MUST live next to
                           # the inventory so playbooks load them (not just ad-hoc runs)
  requirements.yml         # optional Galaxy collections
  playbooks/
    site.yml               # everything
    bootstrap-pve.yml      # fresh Proxmox → into the stack
    provision-dev-vm.yml   # Ubuntu 24.04 dev VM on the pve node (VSCode Remote-SSH)
  roles/
    proxmox_postinstall/   # repos, nag, dist-upgrade, base pkgs, timezone
    node_exporter/         # native prometheus-node-exporter on the host (job node-pve)
    pve_exporter_lxc/      # LXC on the node running prometheus-pve-exporter (job pve)
    pve_api_token/         # read-only API token + writes pve.yml INSIDE that LXC
    coolercontrol/         # nct6687d DKMS driver + CoolerControl web UI (fan/PWM control)
    dev_vm_template/       # build a cloud-init template from the Ubuntu 24.04 cloud image
    dev_vm/                # clone the template → the `dev` VM (cloud-init: user/key/IP)
    dev_workstation/       # inside the VM: Docker + fnm/Node 24 + dev tooling
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
   it into `/etc/prometheus/pve.yml` **inside the LXC** (via `pct push`), then restarts
   the exporter. It ALSO creates a **separate** read-only identity for the homepage
   widget (`homepage@pve!homepage`) and prints its secret once — paste it into `.env`
   as `PVE_TOKEN_ID` / `PVE_TOKEN_SECRET`, then `./scripts/deploy.sh`. Keeping the two
   tokens separate means rotating the exporter token never breaks the homepage widget.
   (Set `pve_homepage_token_manage: false` to skip the homepage token on a run.)
5. **coolercontrol** — builds the out-of-tree `nct6687d` kernel driver via DKMS (the
   MSI Z490 ACE uses a Nuvoton **NCT6687-D** the mainline kernel can't drive) and
   installs the **CoolerControl** daemon **on the host**, with its built-in web UI on
   `:11987`. Open `http://192.168.1.14:11987` to set fan curves for the board headers.
   > Runs on the host, not an LXC — the kernel module lives on the host and writing to
   > `/sys/class/hwmon/*/pwmN` from a container is blocked on PVE 8. If `nct6683` was
   > already bound to the chip, the first run can't load `nct6687` until a **reboot** —
   > reboot once and re-run `--tags coolercontrol`.

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
ansible-playbook playbooks/bootstrap-pve.yml --tags coolercontrol   # just fan control
ansible-playbook playbooks/bootstrap-pve.yml --tags postinstall --check --diff  # dry-run
```

## Provision the dev VM (VSCode Remote-SSH from Windows 11)

A reproducible **Ubuntu 24.04** development VM on the pve node: Docker + Compose v2,
and **fnm** managing **Node 24** as the default with `.nvmrc` / `.node-version`
auto-switch on `cd` (so React / Next / Nest / TS projects each pin their own Node).

**1. Put your SSH keys in place** (`inventory/group_vars/proxmox.yml → dev_vm_authorized_keys`)
— both are public keys, safe to commit:

```powershell
# On Windows 11 — create a key if you don't have one, then print it:
ssh-keygen -t ed25519            # once
type $env:USERPROFILE\.ssh\id_ed25519.pub
```
```bash
# On the rpi5 control node — print its key (so the 2nd play can connect):
cat ~/.ssh/id_ed25519.pub
```

Paste both lines into `dev_vm_authorized_keys` (replace the placeholders). Confirm
`dev_vm_ip` (inventory/group_vars/proxmox.yml) is a **free** LAN address and matches the
`dev-vm` host's `ansible_host` in `inventory/hosts.yml`.

**2. Provision** (from `~/pi-infra/ansible` on the rpi5):

```bash
ansible-playbook playbooks/provision-dev-vm.yml          # template → clone → configure
```

Idempotent. What it does:

1. **dev_vm_template** — downloads the Ubuntu 24.04 cloud image (checksum-verified) and
   builds a cloud-init template (VMID `9000`). Built once; rebuild the base with
   `-e dev_vm_rebuild_template=true`.
2. **dev_vm** — full-clones the template into the `dev` VM (VMID `200`, **6 vCPU /
   8 GB / 100 GB**), applies cloud-init (user `dev`, your SSH keys, static IP), starts
   it and waits for SSH.
3. **dev_workstation** — base dev/CLI packages, **Docker CE + Compose v2** (user in the
   `docker` group), and **fnm** with Node 24 default + corepack (pnpm/yarn) + global
   `typescript`, `ts-node`, `@nestjs/cli`.

**3. Connect from Windows 11.** Add to `%USERPROFILE%\.ssh\config`:

```
Host dev-vm
    HostName 192.168.1.16
    User dev
    IdentityFile ~/.ssh/negri
```

Then in VSCode: **Remote-SSH: Connect to Host… → dev-vm**. Open a terminal and
`node -v` → `v24.x`. Drop a `.nvmrc` (e.g. `20`) in a project and `cd` into it — fnm
switches automatically.

**Recreate the VM** (clean, reproducible rebuild — **wipes the VM**, keep code in git):

```bash
ansible-playbook playbooks/provision-dev-vm.yml -e dev_vm_recreate=true
```

Handy tag runs:

```bash
ansible-playbook playbooks/provision-dev-vm.yml --tags template      # (re)build template
ansible-playbook playbooks/provision-dev-vm.yml --tags vm            # just the clone/config
ansible-playbook playbooks/provision-dev-vm.yml --tags workstation   # reconfigure the guest
```

> **Ordering:** the second play connects to the VM as the `dev` user, so the rpi5
> control node's public key MUST be in `dev_vm_authorized_keys` too — otherwise the
> guest-config play can't log in.

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
