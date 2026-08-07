#!/bin/sh
# Independent external watcher: FROM the rpi3, check the rpi5 is alive and ping a
# healthchecks.io check accordingly. This is a second, independent observer of the
# rpi5 that does NOT depend on the rpi5's own stack:
#   - rpi5 reachable  -> ping HC_URL           (healthchecks stays green)
#   - rpi5 unreachable -> ping HC_URL/fail      (healthchecks alarms immediately)
#   - rpi3/watcher dead -> pings stop entirely  (healthchecks alarms on the grace)
#
# The liveness signal is TCP:22 (SSH) — userspace liveness, the thing ICMP failed
# to show during the 2026-08-06 freeze. Configure HC_URL via RPI5_WATCH_HC_URL.
set -u
: "${HC_URL:=}"
: "${TARGET_HOST:=192.168.1.7}"
: "${INTERVAL:=60}"

if [ -z "$HC_URL" ]; then
  echo "rpi5-watcher: HC_URL unset (set RPI5_WATCH_HC_URL in hosts/rpi3/.env) — idling"
fi

while true; do
  if [ -n "$HC_URL" ]; then
    if nc -z -w3 "$TARGET_HOST" 22 2>/dev/null; then
      curl -fsS -m10 "$HC_URL" >/dev/null 2>&1 || true
    else
      echo "rpi5-watcher: $TARGET_HOST:22 unreachable -> signalling failure"
      curl -fsS -m10 "$HC_URL/fail" >/dev/null 2>&1 || true
    fi
  fi
  sleep "$INTERVAL"
done
