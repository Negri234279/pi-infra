# TrueNAS SCALE observability (`hosts/truenas/`)

Monitors the **TrueNAS SCALE 25.10 "Goldeye"** NAS (`192.168.1.18`, panel `nas-web.negri.es`)
from the hub's Prometheus + Grafana. This is the OS/ZFS side; the BMC/IPMI side is separate
(`core/ipmi-exporter/`, job `ipmi`).

This directory holds a **standalone compose that runs ON the NAS** (its native Docker), not on
the hub — the same pattern as `hosts/rpi3/`. It is **not** part of the hub's root `include:` and
is never brought up by `./scripts/deploy.sh`; the Ansible playbook deploys it to the NAS. Only the
hub-side pieces (Prometheus job, alerts, Grafana dashboards) live under `core/`.

## Why this path

TrueNAS's built-in reporting **is netdata**, which already instruments everything on the box
(ZFS pools + ARC, per-disk SMART/temperatures, sensors, CPU/RAM/network, and the Docker apps).
But the only **native, supported** way to export it is the **Graphite** line protocol — there is
no built-in Prometheus endpoint, and the netdata web UI was removed in 25.04+.

So we bridge it:

```
TrueNAS netdata ──(Reporting Exporter, GRAPHITE push, :9109)──► graphite_exporter (container on
  the NAS, TrueNAS mapping baked in) ──(:9108 /metrics)──► hub Prometheus (job `truenas`,
  scraped over the LAN at 192.168.1.18:9108) ──► Grafana (folder "nas")
```

The exporter image is
[`Supporterino/truenas-graphite-to-prometheus`](https://github.com/Supporterino/truenas-graphite-to-prometheus)
— `graphite_exporter` with a TrueNAS-specific `graphite_mapping.conf` compiled in, so metrics
land as `zfs_pool`, `disk_temperature`, `cpu_temperature`, `truenas_arcstats`, `disk_bytes_used`,
etc., all labelled `job="truenas"` (the mapping keys off the `truenas.` prefix — do not change it).

SNMP was rejected (it can't see ZFS/SMART) and a standalone Graphite/Whisper TSDB was rejected
(redundant with the existing Prometheus).

## Pieces

| Where | What | Managed by |
|-------|------|------------|
| TrueNAS (midclt) | netdata → Graphite Reporting Exporter | `ansible/roles/truenas_reporting_exporter` |
| TrueNAS (Docker) | `graphite-exporter` container (`docker-compose.yml`) | `ansible/roles/truenas_docker_stack` |
| Hub Prometheus | job `truenas` (`192.168.1.18:9108`) | `core/prometheus/prometheus.yml` |
| Hub Prometheus | alerts (group `truenas`) | `core/prometheus/rules/truenas-alerts.yml` |
| Hub Grafana | dashboards (folder "nas") | `core/grafana/dashboards/nas/truenas-*.json` |

## Provision

From the hub (`~/pi-infra/ansible`):

```bash
./run.sh playbooks/bootstrap-truenas.yml            # everything
./run.sh playbooks/bootstrap-truenas.yml --tags reporting   # just the netdata exporter
./run.sh playbooks/bootstrap-truenas.yml --tags docker      # just the container
```

Prerequisites:
- **SSH enabled** on TrueNAS with the hub's key authorized for `truenas_admin` (see the `nas`
  group in `ansible/inventory/hosts.yml`).
- **Apps/Docker initialised with a pool** (Apps must be pointed at a data pool once in the UI),
  otherwise there is no Docker engine for `truenas_docker_stack` to use.
- `truenas_apps_dir` in `ansible/inventory/group_vars/nas.yml` set to a real path on your pool.

Then, on the hub, pick up the new Prometheus job + rules + dashboards with `./scripts/deploy.sh`
from the repo root.

## Nextcloud (private Drive) — opt-in

A self-contained Nextcloud (own Postgres + Redis, so it does NOT depend on the hub's shared
Postgres) runs on the NAS for a Google-Drive-like cloud, **LAN/VPN only** (no public exposure).
Files live on dedicated ZFS datasets (`<pool>/nextcloud`, `<pool>/nextcloud-db`) so they get
snapshots.

```bash
cp hosts/truenas/nextcloud.env.example hosts/truenas/nextcloud.env   # fill in the passwords
./run.sh playbooks/bootstrap-truenas.yml --tags nextcloud            # deploy (opt-in tag)
```
Then reach it at `http://192.168.1.18:8080` (mgmt LAN / WireGuard) or, for **max transfer speed**,
`http://nas.negri.es:8080` — that name resolves to `10.10.10.13` (the 10 GbE link) in DNS — from
the box wired to the 10G segment (which is isolated, so only the directly-connected host reaches
it). All of `192.168.1.18`, `10.10.10.13` and `nas.negri.es` are in `NEXTCLOUD_TRUSTED_DOMAINS`.
Log in with the admin user from `nextcloud.env`. For full 10G throughput also enable jumbo frames
(MTU 9000) on both NICs of that point-to-point link.

**Logs → Grafana:** the stack includes an Alloy sidecar (`nextcloud-alloy`) that tails
`data/nextcloud.log` (JSON) and pushes it to the hub's Loki (published on `:3100`) with
`job="nextcloud"`, `instance="truenas"`. The role enables the `admin_audit` app + `loglevel=1` so
login/file/share events are recorded. View them in Grafana → folder **nas** → **Nextcloud Logs**
(`core/grafana/dashboards/nas/nextcloud-logs.json`, Loki datasource). Requires the hub's Loki port
change deployed (`core/docker-compose.yml`). Compose: `hosts/truenas/nextcloud.compose.yml` (relative binds
`./html`, `./data`, `../nextcloud-db`). Role: `ansible/roles/truenas_nextcloud`. It is gated behind
the `nextcloud` tag, so a normal observability bootstrap never touches it. `nextcloud.env` is
gitignored (`hosts/**/*.env`). To later add TLS/a hostname, front it with NPM restricted to the
LAN/VPN and set `NEXTCLOUD_OVERWRITEPROTOCOL=https`.

## Notes

- The `graphite_exporter` expires a metric 5 min after its last push, so if netdata stops
  pushing, `/metrics` empties out — that's what `TrueNasNoData` watches (rather than only `up`,
  since the container itself stays reachable).
- `netdata.conf` tweaks shipped by the mapping repo are **not used**: they don't survive a
  TrueNAS OS update (immutable root fs), and the default netdata charts already cover what the
  dashboards need. Configure the export purely through the middleware (the Ansible role).
