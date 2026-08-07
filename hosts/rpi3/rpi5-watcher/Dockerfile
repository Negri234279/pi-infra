# Tiny image for the rpi5 watcher: needs curl (HTTPS to healthchecks.io) and nc
# (TCP:22 liveness check). Alpine keeps it ~10 MB. Multi-arch, so it builds on the
# rpi3 (arm) and amd64 alike.
FROM alpine:3.20
RUN apk add --no-cache curl netcat-openbsd
COPY watch.sh /usr/local/bin/watch.sh
RUN chmod +x /usr/local/bin/watch.sh
ENTRYPOINT ["/usr/local/bin/watch.sh"]
