# Backup runner for the whole Pi stack: restic + the client tools the pre-backup
# consistency steps need. There is no official multi-arch restic image that also
# bundles docker-cli + sqlite, and we want the versions pinned, so — same pattern
# as core/smartctl-exporter — build a tiny image from the official restic release
# binary on top of Alpine.
#
#  - restic       : the backup engine (pinned release binary; the repo lives on the
#                   NFS-mounted NAS dataset).
#  - docker-cli   : run `docker exec` against the app containers for consistent DB
#                   dumps (pg_dumpall, redis SAVE) without embedding any DB password.
#  - sqlite       : online `.backup` of coreforge's SQLite DB (WAL-safe).
#  - busybox crond: in-container scheduler (Alpine's built-in cron) — no extra binary,
#                   keeps the service self-contained (the recommended packaging).
#  - curl         : ping healthchecks.io from the script.
FROM alpine:3.20

# restic release to pin. Bump deliberately (a newer restic can read older repos).
ARG RESTIC_VERSION=0.18.0
# BuildKit sets TARGETARCH (arm64 on the Pi 5, amd64 elsewhere) — restic ships both.
ARG TARGETARCH=arm64

RUN set -eux; \
    apk add --no-cache docker-cli sqlite curl bash tzdata ca-certificates; \
    apk add --no-cache --virtual .build bzip2 wget; \
    wget -qO /tmp/restic.bz2 \
      "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${TARGETARCH}.bz2"; \
    bunzip2 -c /tmp/restic.bz2 > /usr/local/bin/restic; \
    chmod +x /usr/local/bin/restic; \
    apk del .build; \
    rm -rf /tmp/restic.bz2; \
    restic version

COPY backup.sh /usr/local/bin/backup.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

# entrypoint initialises the repo (once) + installs the crontab, then execs crond
# in the foreground so the container stays up and fires backup.sh on schedule.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
