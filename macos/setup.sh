#!/bin/bash
# Instala o portal-gun no macOS: Colima (VM Linux) + containers + sincronização de rotas.
#   ./macos/setup.sh
# Requisitos: macOS 13+, Homebrew, usuário administrador (sudo).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)

PROFILE=portal-gun
CONTEXT="colima-$PROFILE"
LABEL=br.com.hexanetworks.portal-gun
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DAEMON="/Library/LaunchDaemons/$LABEL.route-sync.plist"
LIBEXEC=/usr/local/libexec/portal-gun
ETC=/usr/local/etc/portal-gun

step() { echo; echo "==> $*"; }
die() { echo "ERRO: $*" >&2; exit 1; }

[ "$(uname)" = Darwin ] || die "este script é só para macOS. No Linux use ./start.sh e ./install.sh"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || die "precisa do macOS 13 (Ventura) ou mais novo (Virtualization.framework)"
command -v brew >/dev/null || die "instale o Homebrew antes: https://brew.sh"
BREW=$(brew --prefix)
export PATH="$BREW/bin:$PATH"

step "Instalando dependências (colima, docker, docker-compose)"
for pkg in colima docker docker-compose docker-buildx; do
    brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done
mkdir -p "$HOME/.docker/cli-plugins"
ln -sfn "$BREW/opt/docker-compose/bin/docker-compose" "$HOME/.docker/cli-plugins/docker-compose"
ln -sfn "$BREW/opt/docker-buildx/bin/docker-buildx" "$HOME/.docker/cli-plugins/docker-buildx"
docker compose version >/dev/null || die "docker compose não ficou disponível"

# Sobra do Docker Desktop: "credsStore": "desktop" quebra o docker CLI sem o Docker Desktop instalado
CFG="$HOME/.docker/config.json"
if [ -f "$CFG" ] && grep -q '"credsStore"[[:space:]]*:[[:space:]]*"desktop"' "$CFG" \
   && ! command -v docker-credential-desktop >/dev/null; then
    cp "$CFG" "$CFG.bak-portal-gun"
    /usr/bin/python3 - "$CFG" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c.pop("credsStore", None)
json.dump(c, open(p, "w"), indent=2)
PY
    echo "Removido \"credsStore\": \"desktop\" de $CFG (backup em $CFG.bak-portal-gun)"
fi

step "Subindo a VM do Colima ($PROFILE)"
if colima status -p "$PROFILE" >/dev/null 2>&1; then
    echo "VM já está rodando"
else
    colima start "$PROFILE" --vm-type vz --network-address --cpu 2 --memory 2 --disk 20
fi
VMIP=$(colima ls -p "$PROFILE" -j | sed -n 's/.*"address":"\([0-9.]*\)".*/\1/p' | head -1)
[ -n "$VMIP" ] || die "a VM não recebeu um IP alcançável pelo Mac (--network-address)"
echo "IP da VM: $VMIP"

step "Garantindo os módulos de kernel L2TP/PPP na VM"
colima ssh -p "$PROFILE" -- sudo sh -c '
    if modprobe l2tp_ppp 2>/dev/null; then echo "módulos OK";
    else
        echo "instalando linux-modules-extra-$(uname -r)";
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "linux-modules-extra-$(uname -r)" && modprobe l2tp_ppp && echo "módulos OK";
    fi'

step "Configurando o .env"
[ -f .env ] || cp .env.example .env
chmod 600 .env
if grep -q '^ALLOW_FORWARD=' .env; then
    sed -i '' "s/^ALLOW_FORWARD=.*/ALLOW_FORWARD='yes'/" .env
else
    echo "ALLOW_FORWARD='yes'" >> .env
fi

step "Credenciais e containers (start.sh)"
DOCKER_CONTEXT="$CONTEXT" ./start.sh

step "Instalando a sincronização de rotas (pede a senha do sudo)"
sudo mkdir -p "$LIBEXEC" "$ETC"
sudo install -m 755 -o root -g wheel macos/route-sync.sh "$LIBEXEC/route-sync.sh"
sudo tee "$ETC/route-sync.conf" >/dev/null <<EOF
PG_USER='$USER'
PG_HOME='$HOME'
COLIMA_PROFILE='$PROFILE'
DOCKER_BIN='$BREW/bin/docker'
COLIMA_BIN='$BREW/bin/colima'
EOF
sudo tee "$DAEMON" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL.route-sync</string>
    <key>ProgramArguments</key><array><string>$LIBEXEC/route-sync.sh</string></array>
    <key>EnvironmentVariables</key><dict><key>PATH</key><string>$BREW/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/portal-gun-route-sync.log</string>
    <key>StandardErrorPath</key><string>/var/log/portal-gun-route-sync.log</string>
</dict>
</plist>
EOF
sudo launchctl bootout system "$DAEMON" 2>/dev/null || true
sudo launchctl bootstrap system "$DAEMON"

step "Subindo automaticamente no login (LaunchAgent)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$ROOT/macos/up.sh</string></array>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/portal-gun.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/portal-gun.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

step "Aguardando as rotas chegarem no macOS (até 3 min)"
for _ in $(seq 1 36); do
    n=$(netstat -rn -f inet | awk -v gw="$VMIP" '$2==gw' | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] && break
    sleep 5
done
echo "Rotas no macOS via $VMIP: $n"

cat <<EOF

Pronto. Comandos úteis:
  docker compose ps                                           # containers (contexto $CONTEXT)
  docker exec -it portal-gun-frr vtysh -c 'show bgp summary'  # sessão BGP
  netstat -rn -f inet | grep $VMIP | wc -l                    # rotas no macOS
  tail -f /var/log/portal-gun-route-sync.log                  # sincronização de rotas
  ./macos/uninstall.sh                                        # remover
EOF
