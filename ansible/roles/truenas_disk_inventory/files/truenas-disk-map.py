#!/usr/bin/env python3
"""Emit the TrueNAS disk↔slot↔vdev inventory as JSON, for the pi-infra chassis map.

Joins three local sources on the NAS:
  * lsblk           -> device name, serial (VPD), model, size
  * sas3ircu N disp -> HBA enclosure slot per drive (matched by serial)
  * zpool status -L -> pool + vdev membership per device

Physical bay is derived from the HBA slot assuming SFF-8643 cables of `--cols` lanes
stacked top→bottom: row = slot // cols, col = slot % cols  ->  bay "C{col+1}R{row+1}".
That reproduces the HSW6424 4x6 layout (verified against the live cabling).

Prints ONLY a JSON array to stdout (one object per mapped disk), so Ansible can parse it.
"""
import argparse
import json
import re
import subprocess
import sys


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.stdout


def lsblk_disks():
    data = json.loads(run(["lsblk", "-J", "-b", "-o", "NAME,SERIAL,MODEL,SIZE,TRAN,TYPE"]))
    out = {}
    for d in data.get("blockdevices", []):
        if d.get("type") != "disk":
            continue
        out[d["name"]] = {
            "device": d["name"],
            "serial": (d.get("serial") or "").strip(),
            "model": (d.get("model") or "").strip(),
            "size": int(d.get("size") or 0),
            "tran": d.get("tran"),
        }
    return out


def sas_slots(controller):
    """serial (VPD and short) -> slot, from `sas3ircu <n> display`."""
    text = run(["sas3ircu", str(controller), "display"])
    blocks, cur = [], {}
    for line in text.splitlines():
        if "Slot #" in line:
            if cur:
                blocks.append(cur)
            cur = {"slot": int(line.split(":")[1].strip())}
        elif "Unit Serial No(VPD)" in line:
            cur["vpd"] = line.split(":", 1)[1].strip()
        elif "Serial No" in line:
            cur["short"] = line.split(":", 1)[1].strip()
    if cur:
        blocks.append(cur)
    by_serial = {}
    for b in blocks:
        if "slot" not in b:
            continue
        for key in ("vpd", "short"):
            if b.get(key):
                by_serial[b[key]] = b["slot"]
    return blocks, by_serial


def zpool_map():
    """base device name -> {pool, vdev}, from `zpool status -L`."""
    text = run(["zpool", "status", "-L"])
    pool = vdev = None
    devmap = {}
    vdev_re = re.compile(r"^(mirror|raidz1|raidz2|raidz3|draid\S*|spare|log|cache|special|dedup)-?\d*$")
    dev_re = re.compile(r"^(sd[a-z]+|nvme\d+n\d+|vd[a-z]+|da\d+)(?:p?\d+)?$")
    for raw in text.splitlines():
        m = re.match(r"\s*pool:\s*(\S+)", raw)
        if m:
            pool, vdev = m.group(1), None
            continue
        s = raw.strip().split()
        if not s:
            continue
        head = s[0]
        if vdev_re.match(head):
            vdev = head
            continue
        m2 = dev_re.match(head)
        if m2 and pool:
            devmap[m2.group(1)] = {"pool": pool, "vdev": vdev}
    return devmap


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--controller", default="0")
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--boot-pool", default="boot-pool")
    args = ap.parse_args()

    disks = lsblk_disks()
    _, slot_by_serial = sas_slots(args.controller)
    devmap = zpool_map()

    entries = []
    for name, d in disks.items():
        slot = slot_by_serial.get(d["serial"])
        if slot is None:
            continue  # not on this HBA / no enclosure slot -> not placeable on the chassis
        row, col = divmod(slot, args.cols)
        bay = f"C{col + 1}R{row + 1}"
        zinfo = devmap.get(name, {})
        pool = zinfo.get("pool")
        vdev = zinfo.get("vdev")
        group = "boot-pool" if pool == args.boot_pool else "data"
        # netdata may emit either the VPD serial (lsblk) or the HBA short serial.
        short = None
        for s, sl in slot_by_serial.items():
            if sl == slot and s != d["serial"]:
                short = s
                break
        forms = [d["serial"]] + ([short] if short else [])
        body = "|".join(dict.fromkeys(f for f in forms if f))
        entries.append({
            "device": name,
            "slot": slot,
            "bay": bay,
            "serial_vpd": d["serial"],
            "serial_short": short,
            "serial_body": body,
            "serial_regex": f"({body})",
            "model": d["model"],
            "size_gb": round(d["size"] / 1e9, 1) if d["size"] else None,
            "pool": pool,
            "vdev": vdev,
            "group": group,
        })

    entries.sort(key=lambda e: e["slot"])
    json.dump(entries, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
