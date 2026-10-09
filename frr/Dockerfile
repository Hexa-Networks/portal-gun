FROM debian:bookworm-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      frr frr-pythontools iproute2 procps \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY render.sh /usr/local/bin/render-frr
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/render-frr

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
