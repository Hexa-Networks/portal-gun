#!/bin/bash
# Instala o portal-gun como serviço systemd, para subir automaticamente no boot.
#   sudo ./install.sh             -> instala e habilita
#   sudo ./install.sh --uninstall -> remove o serviço (não apaga o projeto nem o .env)
set -euo pipefail
cd "$(dirname "$0")"
. lib/compose.sh

UNIT=/etc/systemd/system/portal-gun.service
DIR=$(pwd -P)

[ "$(id -u)" -eq 0 ] || { echo "Rode como root: sudo $0 $*" >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
    systemctl disable --now portal-gun.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload
    echo "Serviço portal-gun removido."
    exit 0
fi

command -v docker >/dev/null || { echo "Docker não encontrado." >&2; exit 1; }
# Caminho absoluto do Compose v2 para o systemd ("docker compose" ou "docker-compose" 2.x)
case "$(compose_cmd)" in
    "docker compose") COMPOSE="$(command -v docker) compose" ;;
    docker-compose)   COMPOSE="$(command -v docker-compose)" ;;
    *) compose version; exit 1 ;;   # mostra o erro explicativo do helper
esac
[ -f .env ] || echo "Aviso: .env ainda não existe. Rode ./start.sh antes (como usuário) para informar as credenciais."

# Módulos de kernel carregados já no boot (o container também tenta, mas assim fica garantido)
cat > /etc/modules-load.d/portal-gun.conf <<'EOF'
ppp_generic
pppox
l2tp_core
l2tp_netlink
l2tp_ppp
af_key
esp4
xfrm_user
xfrm4_tunnel
EOF

cat > "$UNIT" <<EOF
[Unit]
Description=portal-gun (L2TP/IPsec + BGP)
Documentation=https://github.com/Hexa-Networks/portal-gun
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$DIR
ExecStart=$COMPOSE up -d --remove-orphans
ExecStop=$COMPOSE down
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable docker.service >/dev/null
systemctl enable portal-gun.service

echo "Serviço instalado: $UNIT"
echo "  - sobe no boot automaticamente"
echo "  - systemctl start|stop|status portal-gun"
if [ -f .env ]; then
    read -rp "Subir agora? [S/n] " ans
    [[ "$ans" =~ ^[nN]$ ]] || systemctl start portal-gun.service
fi
