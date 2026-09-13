# NAS IPMI / BMC observability

Metrics and alerts for the **NAS** — a Supermicro **X10SRL-F** board — read from its
**BMC** (baseboard management controller) over IPMI, surfaced in the shared Grafana /
Alertmanager (→ Discord) like every other host.

| Address | What | Notes |
|---------|------|-------|
| `192.168.1.17` | BMC / IPMI (ASPEED AST2400) · `nas-remote.negri.es` | web UI :443 (NPM, self-signed upstream); RMCP+ IPMI 2.0 polled by ipmi-exporter |
| `ipmi-exporter:9290` | ipmi_exporter (on the rpi5 hub) | multi-target `/ipmi`, polls the BMC over the LAN → Prometheus job `ipmi` |

## How it works

`prometheus-community/ipmi_exporter` runs on the **rpi5 hub** (a plain container in the
core stack) in **remote mode**: it talks IPMI-over-LAN (RMCP+) to the BMC at
`192.168.1.17`. Remote mode needs **no `/dev/ipmi` device and no privileges** — those are
only for reading the *local* host's own BMC. The image is `alpine:3` + `freeipmi`,
multi-arch, so it runs natively on arm64.

Prometheus scrapes it with the same **multi-target** pattern as the SNMP/blackbox jobs:
the BMC IP is passed as `?target=192.168.1.17`, then relabeled to `ipmi-exporter:9290`;
`?module=default` selects the credential + collector block in `ipmi.yml`. A scrape runs
several FreeIPMI calls (bmc/ipmi/chassis/dcmi/sel), so the job polls at **60s** with a
**30s** `scrape_timeout`.

### What it collects (module `default`)

| Collector | Metrics | Covers |
|-----------|---------|--------|
| `bmc` | `ipmi_up`, `ipmi_bmc_info` | BMC firmware/mfr, per-collector health |
| `ipmi` | `ipmi_temperature_celsius`, `ipmi_fan_speed_rpm`, `ipmi_voltage_volts`, `ipmi_sensor_state` | all sensors + the BMC's own nominal/warning/critical verdict |
| `chassis` | `ipmi_chassis_power_state`, drive/cooling fault flags | power on/off |
| `dcmi` | `ipmi_dcmi_power_consumption_watts` | whole-node power draw |
| `sel` | `ipmi_sel_entries_count`, `ipmi_sel_free_space_bytes` | System Event Log (new HW events) |

## Setup

### 1. Create a read-only IPMI user on the BMC

In the Supermicro web UI (`nas-remote.negri.es` → **Configuration → Users**), add a
**dedicated** account for monitoring instead of reusing `ADMIN`. Privilege **User** is
enough for the sensor/chassis/SEL/DCMI reads above. (Bump it to **Operator** only if the
`dcmi` power reading or the `sel` log comes back empty — some firmwares gate those.)

### 2. Write the exporter config (holds the BMC credentials — gitignored)

```bash
cd ~/pi-infra
cp core/ipmi-exporter/ipmi.yml.example core/ipmi-exporter/ipmi.yml
# edit core/ipmi-exporter/ipmi.yml → set user + pass of the account from step 1
```

`ipmi.yml` is gitignored (like `mktxp.conf`); only `ipmi.yml.example` is committed. The
bind-mount is a **file**, so `ipmi.yml` must exist before `up` (otherwise Docker creates a
directory in its place).

### 3. Deploy

```bash
cd ~/pi-infra
./scripts/deploy.sh          # brings up ipmi-exporter + reloads Prometheus (new job + rules)
```

### 4. Publish the BMC web UI via NPM (already noted as done)

`nas-remote.negri.es` → `https://192.168.1.17:443`. The BMC serves a **self-signed** cert,
so in NPM enable the proxy host with SSL and **don't** verify the upstream cert. (Websockets
on is also handy for the iKVM/console.) The homepage *NAS IPMI* card links here + pings
`192.168.1.17`.

## Verify

```bash
# exporter reachable + BMC answering from the hub (expect ipmi_* metrics, not an error)
docker compose exec -T prometheus wget -qO- \
  'http://ipmi-exporter:9290/ipmi?target=192.168.1.17&module=default' | head -n 20

# the job is up in Prometheus
docker compose exec -T prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=up%7Bjob=%22ipmi%22%7D'

# per-collector health (each should be 1)
docker compose exec -T prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=ipmi_up%7Bjob=%22ipmi%22%7D'
```

If the scrape fails, check (1) the container can reach `192.168.1.17` on the LAN, (2) the
`user`/`pass` in `ipmi.yml` are correct and the account is enabled, (3) IPMI-over-LAN is
enabled on the BMC (**Configuration → IPMI/Network**), and (4) if only `dcmi`/`sel` read
empty, raise the account privilege to **operator** in step 1 (and `privilege:` in `ipmi.yml`).

## Dashboards & alerts

- **Dashboard**: Grafana folder **nas** → *NAS · IPMI / BMC* (`core/grafana/dashboards/nas/nas-ipmi.json`):
  chassis power, DCMI watts, temperatures, fans, voltages, and a per-sensor state table
  (the BMC's own nominal/warning/critical verdict).
- **Alerts**: `core/prometheus/rules/ipmi-alerts.yml` (group `ipmi`) — scrape/target down,
  a collector persistently failing, any sensor in warning/critical (BMC thresholds), and
  new SEL entries. Same severity labels → same Discord routing as every other alert.

## Notes

- **Sensor thresholds come from the BMC**, not from Prometheus: `ipmi_sensor_state` is
  `0`=nominal / `1`=warning / `2`=critical (NaN = no reading). We alert on that verdict
  rather than hard-coding per-sensor °C/RPM limits, so the board's own factory limits apply.
- **Chassis power-off is not alerted** — a deliberate NAS shutdown is legitimate (same
  philosophy as not alerting on a stopped VM). Sensor/SEL/scrape failures are.
- **Credentials never touch git**: they live only in the gitignored `ipmi.yml` on the hub.
