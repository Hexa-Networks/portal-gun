#!/bin/bash
# Sobe IPsec (strongSwan, IKEv1 transport) + L2TP (xl2tpd/pppd) até o LNS
# e faz o container rotear o tráfego da rede de trânsito para dentro do túnel.
set -euo pipefail

: "${LNS_IP:?defina LNS_IP}" "${IPSEC_PSK:?defina IPSEC_PSK}"
: "${L2TP_USER:?defina L2TP_USER}" "${L2TP_PASS:?defina L2TP_PASS}"

IPSEC_IKE=${IPSEC_IKE:-aes256-sha1-modp2048,aes128-sha1-modp2048,aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024}
IPSEC_ESP=${IPSEC_ESP:-aes256-sha1,aes128-sha1,3des-sha1}
PPP_MTU=${PPP_MTU:-1400}
TRANSIT_HOST_IP=${TRANSIT_HOST_IP:-128.128.0.1}
BGP_NETWORKS=${BGP_NETWORKS:-}
STATE_DIR=/run/portal-gun
CONTROL=/var/run/xl2tpd/l2tp-control

log() { echo "[vpn] $*"; }

# --- Kernel: módulos e /dev/ppp (o container usa o kernel do host) ---
for m in ppp_generic pppox l2tp_core l2tp_netlink l2tp_ppp af_key esp4 xfrm_user xfrm4_tunnel; do
    modprobe "$m" 2>/dev/null || log "aviso: não consegui carregar o módulo $m"
done
[ -c /dev/ppp ] || mknod /dev/ppp c 108 0

mkdir -p "$STATE_DIR" /var/run/xl2tpd
rm -f "$STATE_DIR/ppp.env"

# Variáveis para os scripts ip-up/ip-down (o pppd não repassa o ambiente)
cat > /etc/portal-gun.conf <<EOF
TRANSIT_HOST_IP='$TRANSIT_HOST_IP'
BGP_NETWORKS='$BGP_NETWORKS'
STATE_DIR='$STATE_DIR'
EOF

# --- strongSwan ---
cat > /etc/strongswan.d/portal-gun-logging.conf <<EOF
charon {
    # O starter desconecta o stdout do charon; escreve direto no stdout do PID 1 (docker logs).
    filelog {
        dockerlog {
            path = /proc/1/fd/1
            flush_line = yes
            default = 1
            ike_name = yes
        }
    }
}
EOF

cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids = no

conn hexa
    keyexchange = ikev1
    authby = secret
    type = transport
    left = %defaultroute
    leftprotoport = 17/1701
    right = $LNS_IP
    rightprotoport = 17/1701
    ike = $IPSEC_IKE!
    esp = $IPSEC_ESP!
    ikelifetime = 8h
    keylife = 1h
    dpddelay = 30s
    dpdtimeout = 120s
    dpdaction = restart
    closeaction = restart
    keyingtries = %forever
    auto = start
EOF

printf '%%any %s : PSK "%s"\n' "$LNS_IP" "$IPSEC_PSK" > /etc/ipsec.secrets
chmod 600 /etc/ipsec.secrets

# --- xl2tpd / pppd ---
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
access control = no

[lac hexa]
lns = $LNS_IP
pppoptfile = /etc/ppp/options.l2tpd.client
length bit = yes
autodial = yes
redial = no
EOF

{
    echo "name $L2TP_USER"
    echo "unit 0"
    echo "ipcp-accept-local"
    echo "ipcp-accept-remote"
    echo "noipdefault"
    echo "nodefaultroute"
    echo "noauth"
    echo "refuse-eap"
    echo "noccp"
    echo "mtu $PPP_MTU"
    echo "mru $PPP_MTU"
    echo "lcp-echo-interval 20"
    echo "lcp-echo-failure 4"
    if [ -n "${PPP_EXTRA_OPTS:-}" ]; then
        tr ';' '\n' <<<"$PPP_EXTRA_OPTS"
    fi
} > /etc/ppp/options.l2tpd.client

printf '"%s" * "%s" *\n' "$L2TP_USER" "$L2TP_PASS" > /etc/ppp/chap-secrets
cp /etc/ppp/chap-secrets /etc/ppp/pap-secrets
chmod 600 /etc/ppp/chap-secrets /etc/ppp/pap-secrets

# --- Roteamento e NAT ---
# O LNS sempre sai pela rede de trânsito (host -> internet), mesmo quando a default for o ppp0.
ip route replace "$LNS_IP/32" via "$TRANSIT_HOST_IP"

iptables -t nat -N PG-NAT 2>/dev/null || iptables -t nat -F PG-NAT
for net in $BGP_NETWORKS; do
    iptables -t nat -A PG-NAT -s "$net" -j RETURN   # redes anunciadas passam sem NAT
done
iptables -t nat -A PG-NAT -j MASQUERADE
iptables -t nat -C POSTROUTING -o ppp+ -j PG-NAT 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o ppp+ -j PG-NAT
# Sessão BGP iniciada pelo LNS -> FRR no host
iptables -t nat -C PREROUTING -i ppp+ -p tcp --dport 179 -j DNAT --to-destination "$TRANSIT_HOST_IP" 2>/dev/null \
    || iptables -t nat -A PREROUTING -i ppp+ -p tcp --dport 179 -j DNAT --to-destination "$TRANSIT_HOST_IP"
iptables -t mangle -C FORWARD -o ppp+ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || iptables -t mangle -A FORWARD -o ppp+ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Conexões que entram pela rede de trânsito devem ter as respostas devolvidas por ela,
# mesmo quando a origem não é 128.128.0.1 (ex.: Mac via VM do Colima, LAN roteando pelo host).
# Sem isso, a resposta seguiria a default (ppp0) e voltaria para dentro do túnel.
TRANSIT_IF=$(ip -o -4 route get "$TRANSIT_HOST_IP" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
iptables -t mangle -C PREROUTING -i "$TRANSIT_IF" -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x1 2>/dev/null \
    || iptables -t mangle -A PREROUTING -i "$TRANSIT_IF" -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x1
iptables -t mangle -C PREROUTING -i ppp+ -j CONNMARK --restore-mark 2>/dev/null \
    || iptables -t mangle -A PREROUTING -i ppp+ -j CONNMARK --restore-mark
ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
ip rule add fwmark 0x1 lookup 100
ip route replace default via "$TRANSIT_HOST_IP" dev "$TRANSIT_IF" table 100

# --- Processos ---
shutdown() {
    log "encerrando"
    [ -p "$CONTROL" ] && echo "d hexa" > "$CONTROL" || true
    kill "${XL2TPD_PID:-}" 2>/dev/null || true
    ipsec stop 2>/dev/null || true
    rm -f "$STATE_DIR/ppp.env"
    exit 0
}
trap shutdown TERM INT

log "subindo IPsec para $LNS_IP"
ipsec start --nofork &
IPSEC_PID=$!

for _ in $(seq 1 30); do
    ipsec status hexa 2>/dev/null | grep -q ESTABLISHED && break
    sleep 1
done

log "subindo xl2tpd"
xl2tpd -D -c /etc/xl2tpd/xl2tpd.conf -C "$CONTROL" &
XL2TPD_PID=$!

# Watchdog: reconecta se o ppp0 ficar fora por muito tempo; sai se algum daemon morrer.
down_since=$(date +%s)
while true; do
    sleep 10 & wait $! || true
    kill -0 "$IPSEC_PID" 2>/dev/null || { log "strongSwan morreu"; exit 1; }
    kill -0 "$XL2TPD_PID" 2>/dev/null || { log "xl2tpd morreu"; exit 1; }

    if ip link show ppp0 >/dev/null 2>&1; then
        down_since=$(date +%s)
        continue
    fi
    if (( $(date +%s) - down_since >= 45 )); then
        log "ppp0 fora há mais de 45s, reconectando"
        ipsec status hexa 2>/dev/null | grep -q ESTABLISHED || ipsec up hexa || true
        [ -p "$CONTROL" ] && echo "c hexa" > "$CONTROL" || true
        down_since=$(date +%s)
    fi
done
