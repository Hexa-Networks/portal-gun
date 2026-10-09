FROM debian:bookworm-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      strongswan-starter strongswan-charon libstrongswan-standard-plugins \
      xl2tpd ppp iptables iproute2 kmod procps \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY ip-up /etc/ppp/ip-up.d/portal-gun
COPY ip-down /etc/ppp/ip-down.d/portal-gun
RUN chmod 755 /usr/local/bin/entrypoint.sh /etc/ppp/ip-up.d/portal-gun /etc/ppp/ip-down.d/portal-gun

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
