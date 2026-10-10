#!/bin/bash
# Diagnóstico do portal-gun no macOS: Mac -> VM -> container vpn -> túnel.
#   ./macos/diag.sh            -> testa com o primeiro destino /32 aprendido via BGP
#   ./macos/diag.sh 10.1.2.3   -> testa com um destino específico
cd "$(dirname "$0")/.."
PROFILE=portal-gun
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export DOCKER_CONTEXT="colima-$PROFILE"

h() { echo; echo "===== $* ====="; }

h "Mac"
echo "contexto docker padrão do shell: $(DOCKER_CONTEXT= docker context show 2>&1)"
VMIP=$(colima ls -p "$PROFILE" -j 2>/dev/null | sed -n 's/.*"address":"\([0-9.]*\)".*/\1/p')
echo "VM: ${VMIP:-<sem IP>}  status: $(colima status -p "$PROFILE" 2>&1 | tail -1)"
docker compose ps
if ! docker inspect portal-gun-frr >/dev/null 2>&1 || ! docker inspect portal-gun-vpn >/dev/null 2>&1; then
    echo
    echo ">>> Os containers não estão rodando. Suba com: ./macos/up.sh  (e rode este diagnóstico de novo)"
    exit 1
fi

# Só aceita um IPv4 como argumento (o zsh passa adiante "#" de comentários colados)
D=""
[[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && D=$1
[ -n "$D" ] || D=$(docker exec portal-gun-frr ip -4 route show proto bgp | awk '$1 !~ /\//{print $1; exit}')
echo "destino de teste: $D"
echo "rotas no Mac via VM: $(netstat -rn -f inet | awk -v g="$VMIP" '$2==g' | wc -l | tr -d ' ')"
route -n get "$D" 2>&1 | grep -E 'gateway|interface'
h "route-sync"
tail -5 /var/log/portal-gun-route-sync.log

h "BGP / logs"
docker exec portal-gun-frr vtysh -c 'show bgp summary' | grep -A2 Neighbor
docker logs portal-gun-frr 2>&1 | grep '\[frr\]'
docker logs portal-gun-vpn 2>&1 | grep -E '\[vpn\]|CHAP auth|local  IP|remote IP' | tail -6

h "VM (host)"
colima ssh -p "$PROFILE" -- sudo sh -s "$D" <<'EOF'
D=$1
docker version --format 'docker {{.Server.Version}}'
iptables -V
for k in net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.col0.rp_filter net.ipv4.conf.pgun0.rp_filter; do echo "$k = $(sysctl -n $k 2>&1)"; done
ip -br a | grep -v veth
ip route | grep -v 'proto bgp'
echo "-- rota para $D:"; ip route get "$D"
echo "-- DOCKER-USER"; iptables -L DOCKER-USER -v -n 2>&1
echo "-- FORWARD"; iptables -S FORWARD
echo "-- raw PREROUTING"; iptables -t raw -S PREROUTING
EOF

h "container vpn"
docker exec portal-gun-vpn sh -c '
ip -br a; echo "-- main"; ip route; echo "-- rules"; ip rule; echo "-- table 100"; ip route show table 100; echo "-- table 220 (strongSwan)"; ip route show table 220
for k in all eth0 ppp0; do echo "rp_filter $k = $(cat /proc/sys/net/ipv4/conf/$k/rp_filter 2>&1)"; done
echo "-- nat"; iptables -t nat -L POSTROUTING -v -n; iptables -t nat -L PG-NAT -v -n
echo "-- mangle"; iptables -t mangle -L PREROUTING -v -n'

h "captura durante o ping para $D"
docker run --rm --net host --cap-add NET_ADMIN --cap-add NET_RAW nicolaka/netshoot:v0.13 \
    timeout 12 tcpdump -lni any -c 20 "icmp and host $D" 2>&1 | sed 's/^/[VM ] /' &
docker run --rm --net container:portal-gun-vpn --cap-add NET_ADMIN --cap-add NET_RAW nicolaka/netshoot:v0.13 \
    timeout 12 tcpdump -lni any -c 20 "icmp and host $D" 2>&1 | sed 's/^/[vpn] /' &
sleep 5
echo "--- ping a partir da VM (origem 128.128.0.1, igual ao Linux)"
docker run --rm --net host nicolaka/netshoot:v0.13 ping -c2 -W2 "$D"
echo "--- ping a partir do Mac (origem 192.168.64.1)"
ping -c3 "$D"
wait
