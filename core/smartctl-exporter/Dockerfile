# smartctl_exporter has no arm64 image on Docker Hub or quay (amd64-only since
# v0.7.0), and the Pi 5 is aarch64. The project does publish per-arch release
# binaries, so we build a tiny image from the official binary + smartmontools.
# TARGETARCH is provided automatically by BuildKit (arm64 on the Pi), so this
# same Dockerfile builds correctly on amd64 too.
FROM debian:12-slim

ARG SMARTCTL_EXPORTER_VERSION=0.13.0
ARG TARGETARCH=arm64

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends smartmontools ca-certificates wget; \
    wget -qO /tmp/se.tar.gz \
      "https://github.com/prometheus-community/smartctl_exporter/releases/download/v${SMARTCTL_EXPORTER_VERSION}/smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${TARGETARCH}.tar.gz"; \
    tar -xzf /tmp/se.tar.gz -C /tmp; \
    mv "/tmp/smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${TARGETARCH}/smartctl_exporter" /usr/local/bin/smartctl_exporter; \
    apt-get purge -y wget; apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/* /tmp/se.tar.gz "/tmp/smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${TARGETARCH}"

EXPOSE 9633
ENTRYPOINT ["/usr/local/bin/smartctl_exporter"]
