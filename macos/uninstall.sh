#!/bin/bash
# Remove o portal-gun do macOS: para a sincronização (removendo as rotas), os containers e,
# se confirmado, apaga a VM do Colima. Não apaga o projeto nem o .env.
set -uo pipefail
cd "$(dirname "$0")/.."

PROFILE=portal-gun
LABEL=br.com.hexanetworks.portal-gun
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DAEMON="/Library/LaunchDaemons/$LABEL.route-sync.plist"
export PATH="$(brew --prefix 2>/dev/null || echo /opt/homebrew)/bin:$PATH"

echo "==> Parando a sincronização de rotas (as rotas são removidas)"
sudo launchctl bootout system "$DAEMON" 2>/dev/null || true
sudo rm -f "$DAEMON" /usr/local/libexec/portal-gun/route-sync.sh /usr/local/etc/portal-gun/route-sync.conf
sudo rmdir /usr/local/libexec/portal-gun /usr/local/etc/portal-gun 2>/dev/null || true

echo "==> Removendo o LaunchAgent"
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
rm -f "$AGENT"

echo "==> Derrubando os containers"
docker --context "colima-$PROFILE" compose down 2>/dev/null || true

read -rp "Apagar também a VM do Colima ($PROFILE)? [s/N] " ans
if [[ "$ans" =~ ^[sSyY]$ ]]; then
    colima delete -f "$PROFILE"
else
    colima stop "$PROFILE" 2>/dev/null || true
fi
echo "Removido."
