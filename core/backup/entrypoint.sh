#!/usr/bin/env bash
# Container entrypoint: prepare the restic repo, install the schedule, hand off to
# crond. Designed to be idempotent — restarting the container never re-initialises
# an existing repo and never loses the schedule.
set -euo pipefail

log() { echo "[backup-entrypoint $(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD must be set (store it OFFLINE too — see docs/backups.md)}"
: "${BACKUP_CRON:=0 3 * * *}"

# ── Wait for the NFS-backed repo mount to be ready ──────────────────────────────
# The repo lives on the NAS dataset mounted as an NFS docker volume at /backup.
# If the NAS is briefly unreachable at boot the mount dir is empty; back off a bit
# rather than init a repo on the local overlay (which would silently never reach
# the NAS). We only require the mountpoint to exist and be writable.
repo_root="$(dirname "$RESTIC_REPOSITORY")"
for i in $(seq 1 30); do
  if [ -d "$repo_root" ] && touch "$repo_root/.rw-probe" 2>/dev/null; then
    rm -f "$repo_root/.rw-probe"
    break
  fi
  log "waiting for repo mount $repo_root to be writable ($i/30)…"
  sleep 10
done

# ── Initialise the repo once ────────────────────────────────────────────────────
if restic cat config >/dev/null 2>&1; then
  log "restic repo already initialised at $RESTIC_REPOSITORY"
else
  log "initialising restic repo at $RESTIC_REPOSITORY"
  restic init
fi

# ── Install the crontab and start the scheduler ─────────────────────────────────
# Pass the runtime env through to cron jobs: crond runs with a minimal environment,
# so persist the container env into a file the job sources.
export -p | grep -E ' (RESTIC_|BACKUP_|KEEP_|TZ=|HC_|HEALTHCHECK)' > /etc/backup.env || true
printf '%s /usr/local/bin/backup.sh >> /proc/1/fd/1 2>&1\n' "$BACKUP_CRON" > /etc/crontabs/root
log "scheduled: '$BACKUP_CRON' (TZ=${TZ:-UTC})"

# Optional: run one backup immediately on start (handy for the very first deploy /
# for testing). Off by default so a container restart doesn't trigger a run.
if [ "${BACKUP_ON_START:-false}" = "true" ]; then
  log "BACKUP_ON_START=true → running an initial backup now"
  /usr/local/bin/backup.sh || log "initial backup failed (see above); scheduler still starting"
fi

log "starting crond in the foreground"
exec crond -f -d 8
