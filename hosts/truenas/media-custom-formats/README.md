# Sonarr / Radarr custom formats — Direct-Play friendly

The NAS has **no GPU/QuickSync**, so any Jellyfin transcode runs on the CPU (slow, 4K unviable). The
fix is to **avoid transcoding** by grabbing releases that clients can **Direct Play**. These custom
formats bias Sonarr/Radarr toward the most compatible video/audio so the client's own hardware does
the decoding instead of the server.

These JSON files are **imported manually** (they live in the app database, not a bind-mounted file,
so Ansible can't seed them). The same JSON works in both Sonarr v4 and Radarr v4/v5.

| File | Custom format | Suggested score |
|------|---------------|-----------------|
| `01-h264-preferred.json` | H.264 / x264 — Direct Plays on virtually everything | **+100** |
| `04-compatible-audio.json` | AAC / AC3 / E-AC3 (DD/DD+) — passthrough-friendly | **+50** |
| `02-hevc-x265.json` | HEVC / x265 — Direct Plays only on modern clients | **0** (or **-50** if you have weak/old clients or use the web player) |
| `03-hd-audio-avoid.json` | DTS / TrueHD / Atmos — many clients transcode these | **-50** |

## Import (per app: do it in BOTH Sonarr and Radarr)

1. Settings → **Custom Formats** → **+** → **Import** (top of the dialog) → paste one file's JSON → save.
   Repeat for each of the 4 files.
2. Settings → **Profiles** → open your quality profile → scroll to **Custom Formats** → set the
   **scores** from the table above → save.
3. (Optional) set a **Minimum Custom Format Score** if you want to hard-require a compatible release.

Result: given two otherwise-equal releases, Sonarr/Radarr pick the H.264 + AAC/AC3 one, so Jellyfin
serves it by Direct Play and the NAS CPU stays idle. HEVC/DTS releases are only grabbed when nothing
more compatible exists (or never, if you score them low enough).

> Tune to your clients: if everything you watch on is a modern box (Shield, Fire TV 4K, Jellyfin
> Media Player/Kodi with mpv), HEVC Direct Plays fine — leave `02` at 0 and keep the smaller files.
> Only penalise HEVC if you watch through the **web player** or old/cheap devices.
