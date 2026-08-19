# g8 — cold-storage backup

An old **HP ProLiant DL380p Gen8** used as a **cold** backup target: powered off
~23 h/day, woken once daily by the rpi5 to pull a consistent copy of the Pi
Docker **prod** state, then it powers itself back off.

Design principle: **pull, don't push.** The G8 is the only party that holds the
restic repo and its password. The Pis never get credentials to the backup store,
so a compromised or wiped Pi (or an accidental `rm -rf`) cannot reach backup
history. This is the core defence and it's why the flow is inverted (the target
reaches into the sources, not the other way round).

```
  03:00  systemd timer on rpi5 ─► wake-g8.sh ─► iLO power-on (WOL fallback)
                                                     │
                              G8 boots ─► pi-backup.service (oneshot) ─► backup.sh
                                                     │
   for each Pi:  ssh prepare-backup.sh (pg_dump / sqlite .backup / brief stop)
                 rsync pull  /var/backups/staging ─► /srv/backup/landing/<host>
                                                     │
                 restic backup landing ─► forget --prune ─► check
                                                     │
                 healthchecks.io ping ─► systemctl poweroff
   05:00  pi-backup-guard.timer ─► force poweroff if the backup hung
```

## Why these choices

| Concern | Choice | Why |
| --- | --- | --- |
| Power on | iLO/IPMI primary, WOL fallback | iLO is reliable even after a power cut; WOL as backup |
| Scheduler | systemd timer on the always-on rpi5 | no extra always-on hardware |
| Auto power off | `poweroff` at end of `backup.sh` + a 05:00 guard timer | a hung backup never burns ~120 W all day |
| DB consistency | `pg_dumpall` + `sqlite3 .backup` + brief `docker stop` | copying a live DB volume in-flight = corrupt backup |
| Backup engine | **restic** (encrypted, incremental, dedup, retention) | one snapshot/day, prune to policy, `restic check` verifies |
| Storage | **ZFS** on the P440 in **HBA mode** | scrubs + checksums catch bit-rot on disks parked 23 h/day |
| Alerting | healthchecks.io → Discord (reuse existing account) | alarms if the box never wakes or a backup fails/omits |
| Offsite | `restic copy` → Cloudflare R2 (**disabled for now**) | closes 3-2-1 later; block is ready in `backup.sh` |

## Files

```
hosts/g8/
  backup.sh                    # runs ON the G8 at boot: pull + restic + poweroff
  systemd/pi-backup.service    #   oneshot that runs backup.sh at boot (G8)
  systemd/pi-backup-guard.*    #   05:00 force-poweroff backstop (G8)
  .env.example                 # config templates for all three roles
scripts/
  wake-g8.sh                   # runs on the RPI5: iLO/WOL power-on + wait-for-SSH
  systemd/wake-g8.{service,timer}  #   daily 03:00 wake (rpi5)
  prepare-backup.sh            # runs on EACH Pi (via ssh): consistent staging
```

Config is host-local under `/etc/pi-backup/` and never committed (restic password,
iLO creds). Copy the relevant block from [`.env.example`](.env.example).

## Storage: ZFS on the Smart Array P440

ZFS needs **raw** disks. The P440 supports **HBA mode** (whole-controller
passthrough) — verify the card first, because a stock DL380p Gen8 shipped with a
**P420i**, which has no real HBA mode:

```bash
ssacli ctrl all show detail | grep -Ei 'model|firmware|hba'
```

- **P440** → `ssacli ctrl slot=<n> modify hbamode=on`, reboot, disks appear raw.
- **P420i** → no true HBA; either single-disk RAID0 per drive (hides SMART, ZFS
  dislikes it) or drop in an **LSI 9207/9211 flashed to IT mode** (~€25) — the
  gold standard for ZFS. Recommended for a bit-rot-sensitive cold store.

Then create the pool (example — adapt vdev layout to your disk count):

```bash
zpool create -o ashift=12 backup mirror /dev/sda /dev/sdb   # or raidz2 for 4+ disks
zfs set compression=lz4 backup
zfs create backup/repo backup/landing                       # -> /backup/repo, /backup/landing
```

Point `RESTIC_REPOSITORY` and `LANDING_DIR` (in `backup.env`) at those datasets.
Schedule a monthly `zpool scrub backup` (systemd timer) — that's what makes cold
storage trustworthy.

## Install

**On the G8** (Debian/Ubuntu; install `restic rsync openssh-client zfsutils-linux`):

```bash
git clone <this-repo> /home/backup/pi-infra
sudo install -d -m700 /etc/pi-backup
sudo cp /home/backup/pi-infra/hosts/g8/.env.example /etc/pi-backup/backup.env   # edit: keep only [G8] block
openssl rand -base64 48 | sudo tee /etc/pi-backup/restic-password >/dev/null    # KEEP A COPY OFFLINE
sudo chmod 600 /etc/pi-backup/*
# passwordless SSH G8 -> each Pi as the backup user (key auth, BatchMode)
sudo ln -s /home/backup/pi-infra/hosts/g8/systemd/pi-backup.service       /etc/systemd/system/
sudo ln -s /home/backup/pi-infra/hosts/g8/systemd/pi-backup-guard.service /etc/systemd/system/
sudo ln -s /home/backup/pi-infra/hosts/g8/systemd/pi-backup-guard.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable pi-backup.service pi-backup-guard.timer
```

> ⚠️ The restic password is the ONLY key to the repo. Store a copy somewhere off
> the G8 (password manager). Lose it and every snapshot is unrecoverable.

**On each Pi** (source host):

```bash
sudo install -d -m700 /etc/pi-backup
sudo cp ~/pi-infra/hosts/g8/.env.example /etc/pi-backup/prepare.env   # keep only this host's block
# allow the backup user to run prepare-backup.sh via sudo (NOPASSWD, that one command)
echo 'backup ALL=(root) NOPASSWD: /home/negri/pi-infra/scripts/prepare-backup.sh' \
  | sudo tee /etc/sudoers.d/pi-backup
```

Find real volume mount paths with `docker volume inspect <vol>` (the `Mountpoint`)
and fill them into `prepare.env`.

**On the rpi5** (scheduler; install `ipmitool wakeonlan netcat-openbsd`):

```bash
sudo cp ~/pi-infra/hosts/g8/.env.example /etc/pi-backup/wake.env       # keep only [rpi5] wake block, edit
sudo chmod 600 /etc/pi-backup/wake.env
sudo ln -s ~/pi-infra/scripts/systemd/wake-g8.service /etc/systemd/system/
sudo ln -s ~/pi-infra/scripts/systemd/wake-g8.timer   /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now wake-g8.timer
```

## Verify

```bash
# On the G8, one manual dry run without powering off:
sudo KEEP_ON=1 /home/backup/pi-infra/hosts/g8/backup.sh
sudo restic -r /srv/backup/repo snapshots        # a new snapshot per run
# Restore drill — do this at least once, and monthly thereafter:
sudo restic -r /srv/backup/repo restore latest --target /tmp/restore-test
gunzip -c /tmp/restore-test/landing/rpi5/postgres-all.sql.gz | head   # sane dump?
# From the rpi5, prove the wake path:
sudo /home/negri/pi-infra/scripts/wake-g8.sh
```

A backup you have never restored is not a backup. The restore drill is the point.

## Not done yet / next steps

- **Offsite (3-2-1)**: enable the R2 `restic copy` block in `backup.sh` once you're
  happy with local. Origin (Pi) + G8 + R2 = three copies, two media, one offsite.
- **Observability**: the G8 is off most of the day so node-exporter is pointless,
  but you could scrape restic stats / last-snapshot age into Prometheus via a
  textfile the backup writes, and alert on "no snapshot in >36 h" alongside the
  healthchecks path.
