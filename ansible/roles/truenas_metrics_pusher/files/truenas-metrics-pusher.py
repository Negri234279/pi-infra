#!/usr/bin/env python3
"""Push the metrics TrueNAS's built-in netdata does NOT export (per-disk SMART temperature,
ZFS pool state, pool capacity) into the local graphite_exporter, using the exact Graphite paths
the truenas-graphite-to-prometheus mapping expects. Runs ON the NAS (needs midclt = root); a
TrueNAS cron job calls it every minute (see role truenas_metrics_pusher).

Emitted paths ( {base} defaults to "truenas.truenas" = prefix.namespace, matching what netdata
already sends, so these join the existing series ):
  {base}.smart.log.smart.disktemp.<serial>.temp      -> disk_temperature{serial}   (°C)
  {base}.zfspool.state_<pool>.<state>                 -> zfs_pool{pool,state}       (1/0)
  {base}.disk_space.<mountpoint>.used|avail           -> disk_bytes_used|avail{mountpoint} (GiB)

The chassis relabel in prometheus.yml tags disk_temperature by serial -> bay/vdev, so these
light up the truenas-chassis dashboard and the pool/capacity alerts. Exits 0 even on partial
failure so cron does not spam.
"""
import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

GIB = 1024 ** 3
# States netdata's zfspool collector exposes; we emit all so `zfs_pool{state="online"}` always
# exists for the alert, with 1 on the pool's current state and 0 on the rest.
ZFS_STATES = ["online", "degraded", "faulted", "offline", "unavail", "removed", "suspended"]

# cron's PATH is minimal; smartctl lives in /usr/sbin. Resolve it once (None if unavailable).
SMARTCTL = shutil.which("smartctl") or next(
    (p for p in ("/usr/sbin/smartctl", "/usr/local/sbin/smartctl") if os.path.exists(p)), None)


def midclt(*args):
    try:
        out = subprocess.check_output(["midclt", "call", *args], text=True, timeout=60)
        return json.loads(out)
    except Exception as e:  # noqa: BLE001 - never fatal; skip the section
        print(f"warn: midclt call {' '.join(args)} failed: {e}", file=sys.stderr)
        return None


def smartctl_temp(dev):
    """Read a disk's current temperature straight from smartctl, as a fallback for when TrueNAS's
    disk.temperatures returns null (seen after a hot-swap: ZFS re-admits the disk but the middleware
    hasn't re-polled its SMART temp yet, while `smartctl -a` reports it fine). Handles SAS, SATA and
    NVMe output. Returns float °C or None."""
    if not SMARTCTL or not dev:
        return None
    try:
        out = subprocess.run([SMARTCTL, "-a", f"/dev/{dev}"], capture_output=True, text=True,
                             timeout=30).stdout
    except Exception:  # noqa: BLE001
        return None
    m = re.search(r"Current Drive Temperature:\s*(\d+)", out)          # SAS
    if m:
        return float(m.group(1))
    m = re.search(r"^Temperature:\s*(\d+)\s*Celsius", out, re.MULTILINE)  # NVMe
    if m:
        return float(m.group(1))
    for line in out.splitlines():                                       # SATA attr 194/190
        if "Temperature_Celsius" in line or "Airflow_Temperature" in line:
            nums = re.findall(r"\d+", line)
            if nums:
                return float(nums[-1])
    return None


def disk_temp_lines(base, ts):
    lines = []
    disks = midclt("disk.query") or []
    temps = midclt("disk.temperatures", "[]")
    temps = temps if isinstance(temps, dict) else {}
    # Iterate over the disk CATALOG (not the temps dict) so a disk that dropped out of
    # disk.temperatures entirely still gets a smartctl read.
    for d in disks:
        name = d.get("name")
        serial = (d.get("serial") or "").strip()
        if not name or not serial:
            continue
        temp = temps.get(name)
        if temp is None:                       # midclt has no temp → fall back to smartctl
            temp = smartctl_temp(name)
        if temp is None:                       # genuinely unreadable → skip (tile shows AUSENTE)
            print(f"warn: no temperature for {name} ({serial})", file=sys.stderr)
            continue
        lines.append((f"{base}.smart.log.smart.disktemp.{serial}.temp", float(temp), ts))
    return lines


def pool_lines(base, ts):
    lines = []
    pools = midclt("pool.query") or []
    for p in pools:
        name = p.get("name")
        if not name:
            continue
        status = (p.get("status") or "").lower()
        for st in ZFS_STATES:
            lines.append((f"{base}.zfspool.state_{name}.{st}", 1 if st == status else 0, ts))
        # capacity via the pool's root dataset (used/available in bytes)
        ds = midclt("pool.dataset.get_instance", name)
        if not isinstance(ds, dict):
            continue
        mount = ds.get("mountpoint")
        if not mount or not mount.startswith("/mnt"):
            continue
        used = (ds.get("used") or {}).get("parsed")
        avail = (ds.get("available") or {}).get("parsed")
        if isinstance(used, (int, float)):
            lines.append((f"{base}.disk_space.{mount}.used", round(used / GIB, 3), ts))
        if isinstance(avail, (int, float)):
            lines.append((f"{base}.disk_space.{mount}.avail", round(avail / GIB, 3), ts))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9109)
    ap.add_argument("--base", default="truenas.truenas",
                    help="Graphite path prefix = <reporting prefix>.<namespace>")
    args = ap.parse_args()

    ts = int(time.time())
    lines = disk_temp_lines(args.base, ts) + pool_lines(args.base, ts)
    if not lines:
        print("warn: nothing to push (all midclt calls failed?)", file=sys.stderr)
        return 0

    payload = "".join(f"{path} {value} {t}\n" for path, value, t in lines)
    try:
        with socket.create_connection((args.host, args.port), timeout=10) as s:
            s.sendall(payload.encode())
    except OSError as e:
        print(f"error: could not push to {args.host}:{args.port}: {e}", file=sys.stderr)
        return 0
    print(f"pushed {len(lines)} metrics to {args.host}:{args.port}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
