#!/bin/bash
# Gera /etc/frr/frr.conf a partir do .env e do estado da sessão PPP.
# Uso: render-frr <neighbor> <router-id>
set -euo pipefail

NEIGHBOR=$1
ROUTER_ID=$2
LOCAL_AS=${BGP_LOCAL_AS:-65000}
REMOTE_AS=${BGP_REMOTE_AS:-65000}
TRANSIT_SUBNET=${TRANSIT_SUBNET:-128.128.0.0/24}
TRANSIT_VPN_IP=${TRANSIT_VPN_IP:-128.128.0.2}

{
    echo "frr defaults traditional"
    echo "hostname portal-gun"
    echo "log stdout informational"
    echo "service integrated-vtysh-config"
    echo "!"
    # O peer BGP (LNS) é alcançado através do container vpn.
    echo "ip route $NEIGHBOR/32 $TRANSIT_VPN_IP"
    echo "!"
    if [ "${BGP_ACCEPT_DEFAULT:-no}" != "yes" ]; then
        echo "ip prefix-list PG-IN seq 5 deny 0.0.0.0/0"
    fi
    echo "ip prefix-list PG-IN seq 10 deny $TRANSIT_SUBNET le 32"
    echo "ip prefix-list PG-IN seq 15 deny $LNS_IP/32"
    echo "ip prefix-list PG-IN seq 1000 permit 0.0.0.0/0 le 32"
    echo "!"
    seq=5
    for net in ${BGP_NETWORKS:-}; do
        echo "ip prefix-list PG-OUT seq $seq permit $net"
        seq=$((seq + 5))
    done
    echo "ip prefix-list PG-OUT seq 1000 deny 0.0.0.0/0 le 32"
    echo "!"
    # Toda rota aprendida é instalada no host com next-hop = container vpn (128.128.0.2).
    echo "route-map PG-IN permit 10"
    echo " match ip address prefix-list PG-IN"
    echo " set ip next-hop $TRANSIT_VPN_IP"
    echo "!"
    echo "route-map PG-OUT permit 10"
    echo " match ip address prefix-list PG-OUT"
    echo "!"
    echo "router bgp $LOCAL_AS"
    echo " bgp router-id $ROUTER_ID"
    echo " no bgp ebgp-requires-policy"
    echo " no bgp network import-check"
    echo " neighbor $NEIGHBOR remote-as $REMOTE_AS"
    if [ "$LOCAL_AS" != "$REMOTE_AS" ]; then
        echo " neighbor $NEIGHBOR ebgp-multihop 3"
    fi
    echo " !"
    echo " address-family ipv4 unicast"
    for net in ${BGP_NETWORKS:-}; do
        echo "  network $net"
    done
    echo "  neighbor $NEIGHBOR route-map PG-IN in"
    echo "  neighbor $NEIGHBOR route-map PG-OUT out"
    echo " exit-address-family"
    echo "!"
} > /etc/frr/frr.conf
