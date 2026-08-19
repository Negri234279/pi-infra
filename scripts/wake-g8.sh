#!/bin/sh
# Wake the G8 cold-storage box from the rpi5 (the always-on scheduler). Runs on a
# daily systemd timer (scripts/systemd/wake-g8.timer). The G8 does the rest itself:
# on boot it runs its own backup and powers back off (see hosts/g8/backup.sh).
#
# Two power-on paths, iLO first (reliable even after a power cut), WOL as fallback:
#   1. iLO / IPMI  -> ipmitool chassis power on   (primary)
#   2. Wake-on-LAN -> magic packet to the NIC MAC  (backup, if iLO doesn't answer)
# Then it polls SSH so the run is logged as "up" only once the OS is actually
# reachable (POST + iLO + boot on a G8 is ~1-2 min).
#
# Config: host-local /etc/pi-backup/wake.env on the rpi5 (NOT in git — holds the
# iLO password). Copy the WAKE_* block from hosts/g8/.env.example.
set -eu

CONF="${WAKE_ENV:-/etc/pi-backup/wake.env}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

: "${ILO_HOST:=}"           # iLO address, e.g. 192.168.1.20   (empty = skip iLO)
: "${ILO_USER:=}"
: "${ILO_PASSWORD:=}"
: "${G8_MAC:=}"             # NIC MAC for WOL, e.g. aa:bb:cc:dd:ee:ff (empty = skip WOL)
: "${G8_HOST:=}"           # G8 LAN IP, polled for SSH readiness
: "${WAIT_SECONDS:=240}"    # how long to wait for SSH before giving up

log() { echo "[wake-g8 $(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }

already_up() { [ -n "$G8_HOST" ] && nc -z -w3 "$G8_HOST" 22 2>/dev/null; }

if already_up; then
  log "$G8_HOST:22 already reachable — nothing to do"
  exit 0
fi

# 1. iLO / IPMI power on (primary).
if [ -n "$ILO_HOST" ] && command -v ipmitool >/dev/null 2>&1; then
  log "iLO power on via $ILO_HOST"
  ipmitool -I lanplus -H "$ILO_HOST" -U "$ILO_USER" -P "$ILO_PASSWORD" \
    chassis power on || log "iLO power-on command failed (will try WOL)"
fi

# 2. Wake-on-LAN fallback.
if [ -n "$G8_MAC" ]; then
  if command -v wakeonlan >/dev/null 2>&1; then
    log "WOL magic packet -> $G8_MAC"; wakeonlan "$G8_MAC" || true
  elif command -v etherwake >/dev/null 2>&1; then
    log "WOL magic packet -> $G8_MAC"; etherwake "$G8_MAC" || true
  fi
fi

# 3. Wait for the OS to answer SSH.
[ -z "$G8_HOST" ] && { log "G8_HOST unset — cannot confirm boot; exiting"; exit 0; }
log "waiting up to ${WAIT_SECONDS}s for $G8_HOST:22"
waited=0
while [ "$waited" -lt "$WAIT_SECONDS" ]; do
  if nc -z -w3 "$G8_HOST" 22 2>/dev/null; then
    log "$G8_HOST is up after ${waited}s"; exit 0
  fi
  sleep 10; waited=$((waited + 10))
done
log "G8 did NOT come up within ${WAIT_SECONDS}s — check iLO/WOL/PSU" >&2
exit 1
