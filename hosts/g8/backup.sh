#!/usr/bin/env bash
# Cold-storage pull backup — runs ON the G8 (HP ProLiant DL380p Gen8) at boot.
#
# Model: the G8 is powered off ~23 h/day. The rpi5 wakes it once a day (iLO/WOL,
# see scripts/wake-g8.sh); on boot a systemd oneshot (systemd/pi-backup.service)
# runs THIS script, which:
#   1. pings healthchecks.io /start,
#   2. for each source host: SSHes in to produce a CONSISTENT staging dir
#      (pg_dump / sqlite .backup / brief docker stop — see scripts/prepare-backup.sh),
#      then rsync-pulls that staging dir into a local landing zone,
#   3. runs one restic snapshot of the landing zone into the local repo, prunes to
#      the retention policy, and verifies,
#   4. pings healthchecks.io on success/failure,
#   5. powers the box off (systemctl poweroff) unless KEEP_ON=1.
#
# The G8 is the ONLY party that holds the restic repo and its password. The Pis
# never get credentials to the backup store — a compromised or wiped Pi cannot
# touch history. This is the whole point of "pull, don't push".
#
# A guard timer (systemd/pi-backup-guard.timer) force-powers-off the box later in
# the morning so a hung backup never leaves it burning ~120 W all day.
#
# Config: /etc/pi-backup/backup.env on the G8 (copy from hosts/g8/.env.example).
# This file is host-local and NOT in git (it holds the restic password + HC URL).
set -euo pipefail

CONF="${BACKUP_ENV:-/etc/pi-backup/backup.env}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

: "${SOURCES:?SOURCES unset — set e.g. \"rpi5=192.168.1.7 rpi3=192.168.1.6\" in $CONF}"
: "${SSH_USER:=backup}"
: "${LANDING_DIR:=/srv/backup/landing}"
: "${RESTIC_REPOSITORY:=/srv/backup/repo}"
: "${RESTIC_PASSWORD_FILE:=/etc/pi-backup/restic-password}"
: "${STAGING_DIR:=/var/backups/staging}"   # path ON each source host
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"
: "${HC_URL:=}"
: "${KEEP_ON:=0}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

log()  { echo "[g8-backup $(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }
hc()   { [ -n "$HC_URL" ] && curl -fsS -m10 "$HC_URL$1" >/dev/null 2>&1 || true; }

# Always try to power off, whatever happens — a failed backup must not keep the
# box on all day. The guard timer is the backstop if this script dies outright.
poweroff_now() {
  if [ "$KEEP_ON" = "1" ]; then
    log "KEEP_ON=1 — leaving the box powered on"
  else
    log "powering off"
    systemctl poweroff
  fi
}

fail() { log "FAILED: $*"; hc "/fail"; poweroff_now; exit 1; }

log "starting cold-storage backup"
hc "/start"

# Initialise the repo on first ever run (idempotent: no-op if it exists).
if ! restic cat config >/dev/null 2>&1; then
  log "restic repo not found — initialising $RESTIC_REPOSITORY"
  restic init || fail "restic init"
fi

# 1+2. Per host: produce consistent staging remotely, then pull it locally.
for entry in $SOURCES; do
  name="${entry%%=*}"; host="${entry#*=}"
  land="$LANDING_DIR/$name"
  mkdir -p "$land"
  log "[$name] preparing consistent staging on $host"
  # prepare-backup.sh lives in the repo checkout on each Pi; it reads its own
  # host-local /etc/pi-backup/prepare.env to know what to dump. Fail loud.
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_USER@$host" \
    'sudo /home/'"$SSH_USER"'/pi-infra/scripts/prepare-backup.sh' \
    || fail "[$name] remote prepare"
  log "[$name] pulling $STAGING_DIR -> $land"
  rsync -a --delete --numeric-ids -e 'ssh -o BatchMode=yes -o ConnectTimeout=15' \
    "$SSH_USER@$host:$STAGING_DIR/" "$land/" \
    || fail "[$name] rsync pull"
done

# 3. One snapshot of everything, tagged, then prune + verify.
log "restic backup $LANDING_DIR"
restic backup --tag pi-cold "$LANDING_DIR" || fail "restic backup"

log "restic forget --prune (d=$KEEP_DAILY w=$KEEP_WEEKLY m=$KEEP_MONTHLY)"
restic forget --prune \
  --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" \
  || fail "restic forget"

# Cheap structural check every run; a full --read-data is expensive, do it on a
# schedule (e.g. once a month) via RESTIC_CHECK_READ_DATA=1.
if [ "${RESTIC_CHECK_READ_DATA:-0}" = "1" ]; then
  log "restic check --read-data (full)"; restic check --read-data || fail "restic check --read-data"
else
  log "restic check (structural)"; restic check || fail "restic check"
fi

# 4b. OPTIONAL offsite copy to Cloudflare R2 — disabled for now (local-only).
# Uncomment and set R2_* in $CONF to close the 3-2-1. R2 is an S3 backend:
#   export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$R2_SECRET_KEY"
#   restic -r "s3:$R2_ENDPOINT/$R2_BUCKET" --password-file "$RESTIC_PASSWORD_FILE" \
#     copy --from-repo "$RESTIC_REPOSITORY" || fail "restic copy -> R2"

log "backup OK"
hc ""
poweroff_now
