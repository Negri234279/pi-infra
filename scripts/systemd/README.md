# Auto-deploy on the Pi (systemd)

Polls this repo and applies changes with [`../deploy.sh`](../deploy.sh) on a timer —
no inbound ports, no deploy secrets. Pull-based, "eventually consistent".

## Prerequisites

- The repo is cloned on the Pi with an `origin` remote and an upstream branch
  (`git clone <url>` gives you both).
- `scripts/deploy.sh` is executable: `chmod +x scripts/deploy.sh`.
- The user running it can talk to Docker (in the `docker` group) and pull from the
  remote unattended (HTTPS public repo, a deploy key, or a cached credential).

## Install

The unit files assume user `pi` and clone path `/home/negri/pi-infra`. **Edit
`User=`, `WorkingDirectory=`, and the `ExecStart=` path in `pi-infra-deploy.service`
to match your setup** before installing.

```bash
sudo cp scripts/systemd/pi-infra-deploy.service /etc/systemd/system/
sudo cp scripts/systemd/pi-infra-deploy.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pi-infra-deploy.timer
```

## Operate

```bash
systemctl list-timers pi-infra-deploy.timer   # next/last run
systemctl start pi-infra-deploy.service       # deploy now (don't wait for the timer)
journalctl -u pi-infra-deploy.service -f      # live logs
```

Change the cadence by editing `OnUnitActiveSec=` in the timer, then
`sudo systemctl daemon-reload && sudo systemctl restart pi-infra-deploy.timer`.

## Notes

- `deploy.sh` exits immediately when there's nothing new, so a 5-minute poll is cheap.
- It only recreates services whose definition changed and hot-reloads/restarts the
  ones whose mounted config changed — it never bounces the whole stack for a one-line
  edit.
- Want instant deploys instead of polling? [`.github/workflows/deploy.yml`](../../.github/workflows/deploy.yml)
  does exactly that: on every push to `main` it connects through the wg-easy VPN and
  runs this same `./scripts/deploy.sh` over SSH — push-based. You can run both (the
  script is idempotent) or disable this timer once the Action is working.

## Also here: Pi throttle/undervoltage exporter

`rpi-throttled.timer` runs [`../rpi-throttled.sh`](../rpi-throttled.sh) every minute
to publish `vcgencmd get_throttled` as node-exporter textfile metrics
(`node_rpi_under_voltage_now`, `node_rpi_throttled_now`, plus the since-boot
"occurred" flags) — node-exporter doesn't expose these itself. It writes to
`/var/lib/node_exporter/textfile/`, which node-exporter reads via its
`--collector.textfile.directory` mount.

```bash
# adjust the ExecStart path in rpi-throttled.service to your clone, then:
sudo cp scripts/systemd/rpi-throttled.service /etc/systemd/system/
sudo cp scripts/systemd/rpi-throttled.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now rpi-throttled.timer
```

Alerts `HostUnderVoltage` / `HostThrottled` fire on the live bits. Runs as root
(needs `vcgencmd` and write access under `/var/lib/node_exporter`).
