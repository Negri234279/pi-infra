#!/bin/sh
# vpn-autoswitch — rotate gluetun onto a LESS-CONGESTED AirVPN country when qBittorrent is stuck.
#
# WHY THIS SHAPE: gluetun cannot be told which server to connect to at runtime — its control server
# (:8000) only STOPS/STARTS the tunnel (PUT /v1/vpn/status), and a start re-picks a server RANDOMLY
# from the SERVER_COUNTRIES pool (feature request qdm12/gluetun#2473). It also never reports the
# connected server NAME, and AirVPN's status API lists ENTRY IPs (not the exit IP gluetun reports),
# so we can't map exit->server. BUT gluetun's GET /v1/publicip/ip DOES return the exit `country`, and
# AirVPN's public status API (airvpn.org/api/status) gives per-server `currentload`/`health`. So we
# rotate by COUNTRY: restart the tunnel, read the exit country, and if that country's least-loaded
# healthy server is still above MAX_LOAD_PERCENT we restart again (rejection sampling) until we land
# in a decongested country — or give up after MAX_ATTEMPTS. Requires VPN_SERVER_COUNTRIES to list
# several countries or every restart lands in the same one.
#
# No Docker socket, no container recreation: only HTTP to gluetun (control :8000 + qBittorrent :8080,
# both on the media bridge) and to the AirVPN status API (the sidecar's own egress, NOT the tunnel).
# Opt-in: does nothing unless AUTOSWITCH_ENABLED=true. Logs to stdout → shipped to Loki by media-alloy
# (job="media", container="vpn-autoswitch").

set -u

QBT_URL="${QBT_URL:-http://gluetun:8080}"
GLUETUN_URL="${GLUETUN_URL:-http://gluetun:8000}"
AIRVPN_STATUS_URL="${AIRVPN_STATUS_URL:-https://airvpn.org/api/status/}"
SLOW_MBPS="${SLOW_MBPS:-1}"
SLOW_MINUTES="${SLOW_MINUTES:-10}"
MAX_LOAD_PERCENT="${MAX_LOAD_PERCENT:-70}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-6}"
COOLDOWN_MINUTES="${COOLDOWN_MINUTES:-20}"
POLL_SECONDS="${POLL_SECONDS:-60}"
# Optional: restrict the "decongested" evaluation to these countries (comma-separated, names as in
# the AirVPN API, e.g. "Netherlands,Germany"). Blank = consider every country the API returns. This
# does NOT control where gluetun connects (that's VPN_SERVER_COUNTRIES) — it only filters what counts
# as an acceptable landing.
ALLOWED_COUNTRIES="${ALLOWED_COUNTRIES:-}"

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') vpn-autoswitch: $*"; }

# bytes/s threshold from MB/s (qBittorrent reports dl_info_speed in bytes/s).
SLOW_BYTES=$(awk "BEGIN{printf \"%d\", ${SLOW_MBPS} * 1048576}")

log "starting (enabled=${AUTOSWITCH_ENABLED:-false}) — trigger: DL < ${SLOW_MBPS} MB/s for >= ${SLOW_MINUTES} min with seeded torrents; accept country load <= ${MAX_LOAD_PERCENT}%; max ${MAX_ATTEMPTS} restarts/switch; cooldown ${COOLDOWN_MINUTES} min; poll ${POLL_SECONDS}s"

if [ "${AUTOSWITCH_ENABLED:-false}" != "true" ]; then
  log "AUTOSWITCH_ENABLED is not 'true' — monitoring disabled, idling. Set VPN_AUTOSWITCH_ENABLED=true in media.env to activate."
  while true; do sleep 3600; done
fi

# Exit country reported by gluetun right now (retries: geolocation lags a few seconds after connect).
get_country() {
  _c=""
  _i=0
  while [ "$_i" -lt 15 ]; do
    _c=$(curl -sf --max-time 5 "${GLUETUN_URL}/v1/publicip/ip" 2>/dev/null | jq -r '.country // ""' 2>/dev/null)
    [ -n "$_c" ] && { echo "$_c"; return 0; }
    _i=$((_i + 1)); sleep 2
  done
  echo ""
}

# Stop then start the tunnel; wait until it reports running with a public IP again.
restart_tunnel() {
  curl -sf --max-time 10 -X PUT -H 'Content-Type: application/json' \
    -d '{"status":"stopped"}' "${GLUETUN_URL}/v1/vpn/status" >/dev/null 2>&1
  # Wait until it has actually stopped before asking it to run again (avoid a transition-state reject).
  _i=0
  while [ "$_i" -lt 10 ]; do
    _st=$(curl -sf --max-time 5 "${GLUETUN_URL}/v1/vpn/status" 2>/dev/null | jq -r '.status // ""' 2>/dev/null)
    [ "$_st" = "stopped" ] && break
    _i=$((_i + 1)); sleep 1
  done
  curl -sf --max-time 10 -X PUT -H 'Content-Type: application/json' \
    -d '{"status":"running"}' "${GLUETUN_URL}/v1/vpn/status" >/dev/null 2>&1
  _i=0
  while [ "$_i" -lt 60 ]; do
    _st=$(curl -sf --max-time 5 "${GLUETUN_URL}/v1/vpn/status" 2>/dev/null | jq -r '.status // ""' 2>/dev/null)
    _ip=$(curl -sf --max-time 5 "${GLUETUN_URL}/v1/publicip/ip" 2>/dev/null | jq -r '.public_ip // ""' 2>/dev/null)
    [ "$_st" = "running" ] && [ -n "$_ip" ] && { sleep 3; return 0; }
    _i=$((_i + 1)); sleep 2
  done
  return 1
}

do_switch() {
  _mbps=$(awk "BEGIN{printf \"%.2f\", ${1} / 1048576}")
  log "TRIGGER: DL=${_mbps} MB/s below ${SLOW_MBPS} for >= ${SLOW_MINUTES} min with ${2} seeded torrent(s) — rotating VPN"

  prev_country=$(get_country)
  [ -z "$prev_country" ] && prev_country="unknown"

  # Snapshot AirVPN load once; reuse across attempts (well under the 600 req/10min limit).
  status=$(curl -sf --max-time 20 "${AIRVPN_STATUS_URL}" 2>/dev/null)

  good=""
  if [ -n "$status" ]; then
    # Least-loaded healthy server per country; keep countries at/under MAX_LOAD_PERCENT, ranked asc.
    good=$(printf '%s' "$status" | jq -r --argjson max "${MAX_LOAD_PERCENT}" '
      [.servers[] | select(.health == "ok")]
      | group_by(.country_name)
      | map({country: .[0].country_name, load: (map(.currentload) | min)})
      | map(select(.load <= $max))
      | sort_by(.load)
      | .[].country' 2>/dev/null)
    if [ -n "$ALLOWED_COUNTRIES" ]; then
      # busybox sh has no process substitution — use a temp file for the allow-list.
      _allow=$(mktemp)
      printf '%s' "$ALLOWED_COUNTRIES" | tr ',' '\n' >"$_allow"
      good=$(printf '%s\n' "$good" | grep -Fxf "$_allow" 2>/dev/null)
      rm -f "$_allow"
    fi
    log "current exit country: ${prev_country}; decongested countries (<= ${MAX_LOAD_PERCENT}%): $(printf '%s' "$good" | tr '\n' ',' | sed 's/,$//')"
  else
    log "AirVPN status API unreachable — will accept the first server in a DIFFERENT country"
  fi

  attempt=0
  while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    if ! restart_tunnel; then
      log "attempt ${attempt}/${MAX_ATTEMPTS}: tunnel did not come back up in time — retrying"
      continue
    fi
    newc=$(get_country)
    [ -z "$newc" ] && newc="unknown"

    if [ -z "$status" ]; then
      # No load data: just require a country change.
      if [ "$newc" != "$prev_country" ]; then
        log "attempt ${attempt}/${MAX_ATTEMPTS}: landed in ${newc} (load n/a) — accepted"
        return 0
      fi
      log "attempt ${attempt}/${MAX_ATTEMPTS}: same country ${newc}, retrying"
      continue
    fi

    load=$(printf '%s' "$status" | jq -r --arg c "$newc" '
      [.servers[] | select(.health == "ok" and .country_name == $c) | .currentload] | min // "n/a"' 2>/dev/null)
    if printf '%s\n' "$good" | grep -qxF "$newc"; then
      log "attempt ${attempt}/${MAX_ATTEMPTS}: landed in ${newc} (best-server load ${load}%) — decongested, accepted"
      return 0
    fi
    log "attempt ${attempt}/${MAX_ATTEMPTS}: landed in ${newc} (best-server load ${load}%) — still congested, retrying"
  done

  log "gave up after ${MAX_ATTEMPTS} attempts (no decongested country reached); keeping current server until next cycle"
  return 1
}

slow_since=0
last_switch=0

while true; do
  info=$(curl -sf --max-time 10 "${QBT_URL}/api/v2/transfer/info" 2>/dev/null)
  if [ -z "$info" ]; then
    log "qBittorrent unreachable at ${QBT_URL} — skipping this cycle"
    sleep "$POLL_SECONDS"; continue
  fi
  speed=$(printf '%s' "$info" | jq -r '.dl_info_speed // 0' 2>/dev/null)
  [ -z "$speed" ] && speed=0

  # Count actively-downloading torrents that have at least one seeder in the swarm — a slow torrent
  # with num_complete=0 has nobody to download from, so switching the VPN wouldn't help.
  tor=$(curl -sf --max-time 10 "${QBT_URL}/api/v2/torrents/info?filter=downloading" 2>/dev/null)
  active=$(printf '%s' "$tor" | jq '[.[] | select((.num_complete // 0) >= 1)] | length' 2>/dev/null)
  [ -z "$active" ] && active=0

  now=$(date +%s)
  if [ "$speed" -lt "$SLOW_BYTES" ] && [ "$active" -ge 1 ]; then
    if [ "$slow_since" -eq 0 ]; then
      slow_since=$now
      log "slow start detected (DL below ${SLOW_MBPS} MB/s with ${active} seeded torrent(s)) — timing"
    fi
    elapsed=$((now - slow_since))
    since_switch=$((now - last_switch))
    if [ "$elapsed" -ge $((SLOW_MINUTES * 60)) ]; then
      if [ "$since_switch" -ge $((COOLDOWN_MINUTES * 60)) ]; then
        do_switch "$speed" "$active"
        last_switch=$(date +%s)
        slow_since=0
      else
        # In cooldown: don't hammer, but keep the timer so we act right after cooldown if still slow.
        :
      fi
    fi
  else
    if [ "$slow_since" -ne 0 ]; then
      log "download recovered or no seeded torrents — resetting slow timer"
      slow_since=0
    fi
  fi
  sleep "$POLL_SECONDS"
done
