# core/backup — daily restic backups → NAS

Self-contained backup runner for the whole Pi stack. A single container (`backup`)
builds from this dir, keeps its own schedule (Alpine `crond`), and every night:

1. Takes **consistent dumps** of the stateful services that can't be copied live —
   `pg_dumpall` (whole Postgres cluster), Redis `SAVE`, coreforge SQLite `.backup`.
2. Writes **one restic snapshot** covering those dumps + the app data volumes
   (mounted read-only) + the on-disk repo tree (the gitignored secrets, NPM data and
   TLS certs, homepage/mktxp/ipmi configs, ansible vault…).
3. Applies **GFS retention** (`forget --prune`, keep-daily/weekly/monthly).
4. Reports: node-exporter **textfile metrics** (`pi_backup_*`) + a **healthchecks.io**
   ping (start / success / fail).

The repo lives on the NAS, mounted here as the NFS-backed docker volume `nas-backup`
(→ `/backup` in the container). TrueNAS also takes **ZFS snapshots** of that dataset
(Ansible role `truenas_backup_target`) — the immutability layer that protects the
restic repo itself. Together = the "2" of 3-2-1; the offsite "1" is future work.

## What is and isn't backed up

**In:** Postgres (powerlog, proxy_control, …), `powerlog-redis-data`, coreforge SQLite,
`rust-stats-data`, `wol-data-prod`, `wg-easy-data`, `grafana-data`, NPM `data/` +
`letsencrypt/`, and every gitignored secret in the repo tree.

**Out (on purpose):** the observability TSDBs (Prometheus / Loki / Tempo / Alloy /
Alertmanager, core and per-app) — they self-regenerate and would bloat/churn the repo.

## Setup (one-time)

1. On the NAS, create the dataset + NFS export + snapshot task:
   `cd ansible && ./run.sh playbooks/bootstrap-truenas.yml --tags backup`
2. Fill the backup vars in `.env` (see `.env.example`): **`RESTIC_PASSWORD`**
   (⚠ store it OFFLINE too — without it the repo is unrecoverable), retention,
   `BACKUP_HEALTHCHECK_URL`, and `NAS_BACKUP_ADDR`/`NAS_BACKUP_EXPORT` if not default.
3. Deploy: `./scripts/deploy.sh` (or `docker compose up -d --build backup`).
   The entrypoint `restic init`s the repo on first run.

## Operating it

- Run a backup now: `docker compose exec backup /usr/local/bin/backup.sh`
- List restore points: `docker compose exec backup restic snapshots`
- Check integrity: `docker compose exec backup restic check`

Restore procedures (full DR, single volume, single DB) live in **`docs/backups.md`**.
