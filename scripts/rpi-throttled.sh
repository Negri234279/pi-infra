#!/bin/sh
# Export the Raspberry Pi's throttled/undervoltage state as node-exporter textfile
# metrics. `vcgencmd` is host-only (talks to the VideoCore), so this runs on the
# HOST via a systemd timer (see scripts/systemd/) and writes .prom files into the
# textfile collector directory that node-exporter reads (mounted read-only at
# /host/var/lib/node_exporter/textfile inside the container).
#
# node-exporter does NOT expose vcgencmd's throttle bitmask — this fills that gap,
# added after the 2026-08-06 freeze so undervoltage/throttling is recorded, not
# just readable live.
set -eu

DIR=/var/lib/node_exporter/textfile
OUT="$DIR/rpi_throttled.prom"
mkdir -p "$DIR"

# e.g. "throttled=0x50005" -> 0x50005 -> decimal
raw=$(vcgencmd get_throttled 2>/dev/null | sed 's/^throttled=//')
dec=$(printf '%d' "$raw" 2>/dev/null || echo 0)

bit() { if [ $((dec & $1)) -ne 0 ]; then echo 1; else echo 0; fi; }
uv_now=$(bit 1)       # bit 0  : under-voltage detected NOW
thr_now=$(bit 4)      # bit 2  : currently throttled
uv_occ=$(bit 65536)   # bit 16 : under-voltage has occurred since boot
thr_occ=$(bit 262144) # bit 18 : throttling has occurred since boot

tmp=$(mktemp "$OUT.XXXXXX")
{
  echo "# HELP node_rpi_throttled Raspberry Pi throttled bitmask (vcgencmd get_throttled), decimal."
  echo "# TYPE node_rpi_throttled gauge"
  echo "node_rpi_throttled $dec"
  echo "# HELP node_rpi_under_voltage_now 1 if under-voltage is detected right now."
  echo "# TYPE node_rpi_under_voltage_now gauge"
  echo "node_rpi_under_voltage_now $uv_now"
  echo "# HELP node_rpi_throttled_now 1 if the CPU is being throttled right now."
  echo "# TYPE node_rpi_throttled_now gauge"
  echo "node_rpi_throttled_now $thr_now"
  echo "# HELP node_rpi_under_voltage_occurred 1 if under-voltage has occurred since boot."
  echo "# TYPE node_rpi_under_voltage_occurred gauge"
  echo "node_rpi_under_voltage_occurred $uv_occ"
  echo "# HELP node_rpi_throttled_occurred 1 if throttling has occurred since boot."
  echo "# TYPE node_rpi_throttled_occurred gauge"
  echo "node_rpi_throttled_occurred $thr_occ"
} > "$tmp"
mv "$tmp" "$OUT"
