#!/bin/bash
# FRR em network_mode: host. Espera a sessão PPP do container vpn subir,
# gera a configuração BGP e mantém ela em sincronia se o IP do peer mudar.
set -euo pipefail

: "${LNS_IP:?defina LNS_IP}"
STATE=/run/portal-gun/ppp.env
FRRINIT=/usr/lib/frr/frrinit.sh

log() { echo "[frr] $*"; }

# Garante que o tráfego IPsec até o LNS nunca entre em loop pelo túnel,
# mesmo se o BGP aprender um prefixo que cubra o IP do LNS.
read -r GW DEV ONLINK < <(ip -4 route show default | awk '{print $3, $5, ($0 ~ /onlink/ ? "onlink" : "")}' | head -1)
if [ -n "${GW:-}" ]; then
    ip route replace "$LNS_IP/32" via "$GW" dev "$DEV" ${ONLINK:-}
    log "rota fixa para o LNS $LNS_IP via $GW ($DEV)"
fi

# Libera o encaminhamento de tráfego roteado (não originado no host) para a rede de trânsito.
# O Docker bloqueia por padrão conexões novas vindas de fora para uma bridge. Necessário no
# macOS (o Mac roteia pela VM do Colima) ou para outras máquinas da LAN usarem este host.
if [ "${ALLOW_FORWARD:-no}" = yes ]; then
    BRIDGE=${TRANSIT_BRIDGE:-pgun0}
    CHAIN=DOCKER-USER
    iptables -nL "$CHAIN" >/dev/null 2>&1 || CHAIN=FORWARD
    for dir in -i -o; do
        iptables -C "$CHAIN" "$dir" "$BRIDGE" -j ACCEPT 2>/dev/null \
            || iptables -I "$CHAIN" "$dir" "$BRIDGE" -j ACCEPT
    done
    log "encaminhamento liberado para a bridge $BRIDGE ($CHAIN)"
fi

for d in bgpd staticd; do
    grep -q "^$d=" /etc/frr/daemons \
        && sed -i "s/^$d=.*/$d=yes/" /etc/frr/daemons \
        || echo "$d=yes" >> /etc/frr/daemons
done

resolve() {
    # shellcheck disable=SC1090
    . "$STATE"
    NEIGHBOR=${BGP_NEIGHBOR:-auto}; [ "$NEIGHBOR" = auto ] && NEIGHBOR=$PPP_REMOTE
    ROUTER_ID=${BGP_ROUTER_ID:-auto}; [ "$ROUTER_ID" = auto ] && ROUTER_ID=$PPP_LOCAL
    echo "$NEIGHBOR $ROUTER_ID"
}

log "aguardando sessão PPP do container vpn"
until [ -s "$STATE" ]; do sleep 2; done

CURRENT=$(resolve)
render-frr $CURRENT
log "BGP: neighbor/router-id = $CURRENT"

shutdown() {
    log "encerrando"
    $FRRINIT stop || true
    [ -n "${GW:-}" ] && ip route del "$LNS_IP/32" via "$GW" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

$FRRINIT start

while true; do
    sleep 10 & wait $! || true
    pgrep -x watchfrr >/dev/null || { log "watchfrr morreu"; exit 1; }
    [ -s "$STATE" ] || continue
    NEW=$(resolve)
    if [ "$NEW" != "$CURRENT" ]; then
        log "sessão PPP mudou ($CURRENT -> $NEW), recarregando FRR"
        render-frr $NEW
        /usr/lib/frr/frr-reload.py --reload /etc/frr/frr.conf || $FRRINIT restart
        CURRENT=$NEW
    fi
done
