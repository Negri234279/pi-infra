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
- Want instant deploys instead of polling? Point a GitHub Actions job at the Pi over
  SSH and have it run `./scripts/deploy.sh` — same script, push-based.
