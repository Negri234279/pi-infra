# Backups & restore runbook (rpi5 → NAS)

Nightly, encrypted, deduplicated backups of the **whole Pi stack** into a **restic** repo
on the **NAS** (`tank/backups/rpi5`), with **GFS retention** and a **ZFS-snapshot**
immutability layer. This is the "2" of a 3‑2‑1 strategy; the offsite "1" is deferred until
a second machine exists (then: `restic copy` to it / to Backblaze B2 — see *Future*).

```
                 ┌── restic (Capa A: retención lógica de puntos de restauración)
 rpi5 ──nightly──┤
 (00:00)         └─► NFS ─► tank/backups/rpi5 ──ZFS snapshots (Capa B: inmutabilidad)
                                (NAS, RAIDZ2)      00:30, keep 2w   [solo desde el NAS]
```

- **Capa A — restic `forget --prune`**: how many restore points exist in the repo
  (keep‑daily 14 / weekly 8 / monthly 6). Your "vuelve al martes pasado".
- **Capa B — ZFS snapshots of the dataset**: protect the restic repo *files* themselves.
  Read‑only, destroyable only from the NAS → if the Pi is compromised or a prune goes
  wrong, yesterday's snapshot still holds an intact repo.

## What is backed up

Captured in a single restic snapshot each night:

| Source | How | Why special |
|---|---|---|
| **Postgres** (powerlog, proxy_control, …) | `pg_dumpall` (logical) | a live file copy of the PG volume can be torn/corrupt |
| **coreforge** SQLite | `sqlite3 .backup` (online, WAL‑safe) | consistent copy without stopping the app |
| **powerlog Redis** | `redis-cli SAVE` then copy `powerlog-redis-data` | flush BullMQ jobs (AOF) to disk first |
| `rust-stats-data`, `wol-data-prod` | file copy (RO) | plain app data |
| `wg-easy-data` | file copy (RO) | **WireGuard keys + clients** — losing it = re‑enroll every device |
| `grafana-data` | file copy (RO) | users / API keys / annotations (dashboards come from git) |
| NPM `data/` + `letsencrypt/` | file copy (RO, via `/repo`) | proxy hosts DB + TLS certs |
| **all gitignored secrets** | file copy (RO, via `/repo`) | `.env`, `apps/**/*.env`, `hosts/**/*.env`, `secrets/`, `mktxp.conf`, `ipmi.yml`, `pve.yml`, `homepage/config`, `ansible/.vault_pass`, … |

The `/repo` mount is the whole repo checkout (read‑only), so the snapshot is a complete
point‑in‑time of the deployed tree — code *and* the on‑disk secrets — not just volumes.

**Deliberately NOT backed up:** the observability TSDBs — Prometheus / Loki / Tempo /
Alloy / Alertmanager (core and per‑app). They self‑regenerate and would bloat and churn
the repo (bad for dedup). The stack is rebuilt from git; only the working‑tree secrets
(above) matter for DR.

## ⚠ The one thing you must store offline: `RESTIC_PASSWORD`

The repo is encrypted with `RESTIC_PASSWORD` (in `.env`). **Without it the backups are
unrecoverable.** `.env` itself lives on the Pi *and* inside the backups it protects — a
chicken‑and‑egg for disaster recovery. **Store `RESTIC_PASSWORD` in your password manager
(offline).** It is your single most important restore dependency.

---

## First‑time setup

**1. NAS side** (dataset + NFS export locked to the Pi + periodic ZFS snapshot task):

```bash
cd ansible
./run.sh playbooks/bootstrap-truenas.yml --tags backup
```

Idempotent (midclt). Creates `tank/backups/rpi5`, the NFS export for `192.168.1.7`
(`maproot=root` so restic owns its files), ensures the NFS service is up, and a daily
00:30 snapshot task keeping 2 weeks. Tune in `ansible/roles/truenas_backup_target/defaults`.

**2. Pi side** — fill `.env` (see `.env.example`, "Backups" section):

```
RESTIC_PASSWORD=<long random — ALSO saved offline!>
BACKUP_HEALTHCHECK_URL=https://hc-ping.com/<uuid>   # optional but recommended
# retention / schedule / NAS addr defaults are fine unless the NAS moved
```

Create the healthchecks.io check first (period **1 day**, grace a few hours).

**3. Deploy** (builds the image, mounts the NFS volume, `restic init`s the repo):

```bash
./scripts/deploy.sh          # or: docker compose up -d --build backup
```

**4. Verify** the first run:

```bash
docker compose exec backup /usr/local/bin/backup.sh   # run one now
docker compose exec backup restic snapshots           # should list one snapshot
docker compose exec backup restic check               # repo integrity
```

### Visibility (Grafana)

- **Dashboard "Pi · backups"** (`core/grafana/dashboards/pi-backups.json`, folder Infra): last
  backup age / result / warnings / duration, restic repo size + snapshot count, the NAS ZFS
  snapshot age + count, trend charts, and the live `backup` container logs (Loki).
- **Pi metrics** `pi_backup_*` come from node-exporter's textfile collector (job=node); restic
  has no live‑progress metric — watch the logs panel for that.
- **NAS snapshot metrics** (age/count of `tank/backups/rpi5`) are pushed by
  `truenas_metrics_pusher` into the graphite_exporter and land on job=truenas as a passthrough
  (matched by `__name__` regex). ⚠ VERIFY the exact metric name after the first scrape.
- **Alerts** (`core/prometheus/rules/backup-alerts.yml`): `BackupTooOld`, `BackupLastRunFailed`,
  `BackupMetricsAbsent`, `BackupContainerDown` (Pi side) and `BackupNasSnapshotStale`,
  `BackupNasSnapshotMetricAbsent` (NAS side). All go to Discord; **critical** ones (e.g.
  `BackupTooOld`) also go to **email** via Alertmanager's Gmail smarthost — set `SMTP_PASSWORD`
  in `.env` (a Gmail *app password*). See `core/alertmanager/alertmanager.yml`.

### ⚠ Failure mode: NAS unreachable at container start (auto-recovered)

The `backup` container mounts the NAS repo as a docker `local` NFS volume, mounted at
container-**create** time with `hard`. If the NAS is unreachable right then — it reboots, or
powers off for a while — the mount fails with `no route to host`, the container exits 255, and
docker's `restart: unless-stopped` does **not** retry a create-time mount failure. It then stays
dead until restarted by hand.

This bit us **2026-09-18 → 09-21**: the rpi5 rebooted at ~19:45 while the NAS was off, the mount
failed, and three nightly backups were silently missed (only `BackupTooOld` caught it, 26h later,
on Discord — which went unwatched). Two mitigations are now in place:

- **`backup-guard.timer`** (`scripts/backup-guard.sh`, install via `scripts/systemd/README.md`)
  runs every 5 min, `docker start`s the container the moment the NAS is reachable again, and
  publishes `pi_backup_container_running` → alert `BackupContainerDown` (>6h).
- **Email** on critical alerts, so a missed backup reaches a channel you actually read.

If the container is down *now*: `docker start backup` (once the NAS is up) — or just wait ≤5 min
for the guard. To run the skipped backup immediately: `docker exec backup /usr/local/bin/backup.sh`.

---

## Restore procedures

All commands run inside the `backup` container (it has restic + the NAS repo mounted):

```bash
docker compose exec backup sh          # RESTIC_REPOSITORY/PASSWORD already in the env
restic snapshots                       # find the snapshot id / date you want
```

Paths inside a snapshot: `/dump/...` (the DB dumps), `/volumes/<name>` (app volumes),
`/repo/...` (secrets, NPM data, configs).

### A) Restore a single app volume

Example: roll `rust-stats-data` back to the latest snapshot.

```bash
# 1. Extract the volume's files to a scratch dir on the NAS mount (or /tmp).
docker compose exec backup \
  restic restore latest --include /volumes/rust-stats-data --target /backup/_restore

# 2. Stop the app, replace the volume contents, restart.
docker compose stop rust-stats-scraper
docker run --rm \
  -v pi-infra_rust-stats-data:/dst \
  -v /var/lib/docker/volumes/pi-infra_nas-backup/_data/_restore/volumes/rust-stats-data:/src:ro \
  alpine sh -c 'rm -rf /dst/* && cp -a /src/. /dst/'
docker compose up -d rust-stats-scraper
```

(Adjust the volume name if different — `docker volume ls`. `wg-easy-data`, `wol-data-prod`,
`grafana-data`, `powerlog-redis-data` follow the same pattern; stop the owning service first.)

### B) Restore a single database

**Postgres — one DB or the whole cluster:**

```bash
# Stream the dump straight from restic into psql (whole cluster: roles + all DBs).
docker compose exec backup sh -c \
  'restic dump latest /dump/postgres/pg_dumpall.sql.gz | gunzip' \
  | docker exec -i postgres psql -U postgres
```

For a single DB, extract the dump, edit/split it, then `psql -d <db> -f`. (pg_dumpall is a
plain SQL cluster dump; `\c <db>` sections delimit each database.)

**coreforge SQLite:**

```bash
docker compose exec backup restic restore latest \
  --include /dump/coreforge/coreforge.db --target /backup/_restore
docker compose stop coreforge-app
# copy /backup/_restore/dump/coreforge/coreforge.db into the coreforge-data volume as
# coreforge.prod.db (see apps/coreforge/docker-compose.yml notes), then:
docker compose up -d coreforge-app
```

### C) Full disaster recovery (new SD/NVMe)

1. Reinstall the OS + Docker on the Pi; apply the freeze‑hardening (see
   `[[prod-host-rpi5-freeze-hardening]]`).
2. `git clone` the repo to `~/pi-infra`.
3. Recreate the shared networks: `./scripts/create-network.sh`.
4. Restore the secrets + NPM data first, from the NAS repo. With the repo reachable over
   NFS, run restic from a throwaway container (the stack isn't up yet):
   ```bash
   docker run --rm -it \
     -e RESTIC_REPOSITORY=/backup/restic \
     -e RESTIC_PASSWORD='<from your password manager>' \
     -v pi-infra_nas-backup:/backup \    # or mount the NFS export directly
     -v ~/pi-infra:/repo \
     restic/restic restore latest --include /repo --target /
   ```
   This drops `.env`, all `*.env`, `secrets/`, NPM `data/`+`letsencrypt/`, configs back
   into the checkout. (Alternatively restore to `/tmp` and copy selectively.)
5. Restore the app data volumes (procedure A) for each of `wg-easy-data`,
   `rust-stats-data`, `wol-data-prod`, `grafana-data`, `powerlog-redis-data`, coreforge.
6. Bring the stack up: `docker compose up -d`. The shared Postgres starts empty →
   restore it (procedure B) once the `postgres` container is healthy.
7. Verify: NPM proxies + certs, WireGuard clients, Grafana, each app.

### D) Recover from a corrupted/deleted restic repo (ZFS snapshot layer)

If the repo itself is damaged (bad prune, accidental delete, ransomware on the Pi), roll
the **dataset** back to a NAS snapshot — done entirely on the NAS, the Pi can't touch it:

```bash
# On the NAS (UI: Datasets → tank/backups/rpi5 → Snapshots → Rollback, or:)
midclt call zfs.snapshot.rollback tank/backups/rpi5@restic-auto-YYYY-MM-DD_00-30
```

Then restore normally (A/B/C) from the rolled‑back repo.

---

## Operating notes

- **Logs:** `docker logs backup` (backup.sh writes to PID‑1 stdout → also shipped to Loki
  by Alloy, `{container="backup"}`).
- **Manual run:** `docker compose exec backup /usr/local/bin/backup.sh`.
- **Integrity check (monthly is plenty):** `docker compose exec backup restic check --read-data-subset=5%`.
- **Retention** is applied every run by `forget --prune`; the NAS snapshot retention is
  separate (role default 2 weeks) — they don't need to match.
- **Timing:** Pi backup 00:00, NAS snapshot 00:30 — the 30‑min offset lets the snapshot
  capture the repo at rest (the backup runs in seconds). restic tolerates a snapshot taken
  mid‑run anyway (it looks like an interrupted backup — the repo stays valid).

## Future (the offsite "1" of 3‑2‑1)

When a second machine / cloud target exists, add a second repo and `restic copy` into it
(dedup means only new blobs transfer). Candidates: another Pi/NAS offsite, or Backblaze B2
(`restic copy --repo2 b2:bucket:path`). No change to the primary flow — just an extra step.
