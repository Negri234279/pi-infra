# rpi3 agent stack

Metrics-only agent for the **rpi3 (192.168.1.6)**, deployed from this repo but
run **only on the rpi3**. The rpi5 hub scrapes/probes it over the LAN.

- **Runs here:** `node-exporter` (:9100, ~20 MB).
- **Runs on the rpi5 (already in `core/`):** the `node-rpi3` Prometheus scrape
  job, the `host-rpi3` alert group, and (Phase 5) a Blackbox TCP:22 probe.
- **Deliberately no logs.** The rpi3 has ~0.89 GB RAM free with its apps; a log
  shipper (Alloy ≈150 MB) would be too heavy. See *Optional: logs* below.

## Deploy (on the rpi3)

```bash
git clone <this-repo> ~/pi-infra          # first time
cd ~/pi-infra
git checkout <branch>                      # same branch the hub tracks
./scripts/deploy-host.sh rpi3
```

`deploy-host.sh` is idempotent (git-pull aware) and scopes compose to
`hosts/rpi3/` under project `rpi3`. Automate it with a systemd timer mirroring
`scripts/systemd/` (point the service at `deploy-host.sh rpi3`).

Verify from the rpi5:
```bash
docker compose exec -T prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=up%7Bjob=%22node-rpi3%22%7D'   # -> "1"
```

## Optional: logs (only if RAM allows)

Not enabled by default. If you later want the rpi3's journal in the central Loki,
prefer the **lightweight, container-free** path over Alloy:

- **Native syslog forward (recommended for this box):** forward journald to the
  rpi5's existing Alloy syslog listener on `:514` (rsyslog/`systemd-journal`
  → `192.168.1.7:514`). A few MB of RAM, no container. You'd add a listener/relabel
  on the rpi5 Alloy to tag it `host=rpi3` instead of the router's labels.
- **Alloy (heavier, ~150 MB):** add an `alloy` service here reading journald and
  pushing to Loki. This needs Loki reachable from the rpi3 — publish the rpi5
  Loki on the LAN (`:3100`) or expose it via NPM with auth. Only do this if the
  rpi3's free RAM comfortably absorbs it.
