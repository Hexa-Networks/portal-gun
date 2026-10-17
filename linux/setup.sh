#!/bin/bash
# Instalador do portal-gun para Linux: verifica a máquina, instala o Docker se faltar,
# configura o daemon (IPv6 + rede padrão), baixa o projeto, pede as credenciais e
# deixa tudo subindo no boot.
#
#   curl -fsSL https://raw.githubusercontent.com/Hexa-Networks/portal-gun/main/linux/setup.sh | sudo bash
#   sudo ./linux/setup.sh [opções]
#
# Opções:
#   --check        só analisa a máquina e mostra o que seria feito (não altera nada)
#   -y, --yes      não pergunta (aceita mudar o daemon.json e reiniciar o Docker)
#   --no-start     prepara tudo, mas não pede credenciais nem sobe a VPN
#   --dir DIR      onde instalar o projeto (padrão: /opt/portal-gun)
#   --branch B     branch do GitHub (padrão: main)
#
# Variáveis: PG_DOCKER_BIP (padrão 128.66.66.1/24), PG_DOCKER_V6 (padrão fd66:66:66::/64)
set -euo pipefail

REPO=https://github.com/Hexa-Networks/portal-gun.git
DIR=/opt/portal-gun
BRANCH=main
MODE=install
ASSUME_YES=no
START=yes
BIP=${PG_DOCKER_BIP:-128.66.66.1/24}
V6=${PG_DOCKER_V6:-fd66:66:66::/64}
DAEMON_JSON=/etc/docker/daemon.json

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check ;;
        -y|--yes) ASSUME_YES=yes ;;
        --no-start) START=no ;;
        --dir) DIR=$2; shift ;;
        --branch) BRANCH=$2; shift ;;
        -h|--help) sed -n '2,17p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Opção desconhecida: $1" >&2; exit 2 ;;
    esac
    shift
done

# O setup roda como root, mas o projeto pertence ao usuário: libera o git nesta pasta
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$DIR"

if [ -t 1 ]; then C_STEP='\033[1;36m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_0='\033[0m'
else C_STEP=''; C_OK=''; C_WARN=''; C_ERR=''; C_0=''; fi
step() { echo; echo -e "${C_STEP}==> $*${C_0}"; }
ok()   { echo -e "  ${C_OK}ok${C_0}     $*"; }
warn() { echo -e "  ${C_WARN}aviso${C_0}  $*"; WARNINGS=$((WARNINGS + 1)); }
todo() { echo -e "  ${C_WARN}fazer${C_0}  $*"; }
die()  { echo -e "${C_ERR}ERRO:${C_0} $*" >&2; exit 1; }
WARNINGS=0

# Compose v2: "docker compose" (plugin) ou "docker-compose" 2.x (standalone). O v1 (Python) não serve.
compose_cmd() {
    if docker compose version >/dev/null 2>&1; then echo "docker compose"; return 0; fi
    if command -v docker-compose >/dev/null 2>&1; then
        case "$(docker-compose version --short 2>/dev/null)" in v1.*|1.*) ;; ?*) echo "docker-compose"; return 0 ;; esac
    fi
    return 1
}

# Perguntas leem do terminal: com "curl | sudo bash" o stdin é o próprio script
HAS_TTY=no; { : </dev/tty; } 2>/dev/null && HAS_TTY=yes
confirm() {   # confirm "pergunta" -> 0 = sim
    [ "$ASSUME_YES" = yes ] && return 0
    [ "$HAS_TTY" = yes ] || die "preciso de confirmação para: $1  (rode com --yes ou num terminal)"
    local ans; read -rp "  $1 [s/N] " ans </dev/tty
    [[ "$ans" =~ ^[sSyY]$ ]]
}

[ "$(id -u)" -eq 0 ] || die "rode como root: sudo $0 $*"
PG_USER=${SUDO_USER:-root}

# ---------------------------------------------------------------------------
step "Analisando a máquina"
. /etc/os-release
ok "sistema: ${PRETTY_NAME:-$ID}, kernel $(uname -r), arquitetura $(uname -m)"
[ -d /run/systemd/system ] && ok "systemd presente" || die "o portal-gun precisa de systemd (serviço de boot)"

PKG=""
for p in apt-get dnf yum zypper; do command -v $p >/dev/null && { PKG=$p; break; }; done
[ -n "$PKG" ] && ok "gerenciador de pacotes: $PKG" || warn "gerenciador de pacotes não reconhecido; dependências precisam ser instaladas à mão"

MISSING_DEPS=""
for c in git curl whiptail ip; do command -v $c >/dev/null || MISSING_DEPS="$MISSING_DEPS $c"; done
[ -z "$MISSING_DEPS" ] && ok "dependências: git curl whiptail iproute2" || todo "instalar:$MISSING_DEPS"

# Docker
DOCKER=none
if command -v docker >/dev/null; then
    DVER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
    if [ -z "$DVER" ]; then
        DOCKER=stopped; todo "Docker instalado mas o serviço não responde: será iniciado"
    else
        DOCKER=ok; ok "Docker $DVER"
        [ "${DVER%%.*}" -ge 27 ] 2>/dev/null || warn "Docker $DVER é anterior ao 27: o IPv6 funciona, mas sem ip6tables (NAT IPv6) por padrão"
    fi
    if CC=$(compose_cmd); then
        COMPOSE=ok; ok "Compose v2 via '$CC' ($($CC version --short 2>/dev/null))"
    else
        COMPOSE=none
        if command -v docker-compose >/dev/null; then
            todo "só existe o Compose v1 ($(docker-compose version --short 2>/dev/null), Python, sem suporte): instalar o Compose v2 como plugin (o v1 fica intacto)"
        else
            todo "instalar o Docker Compose v2"
        fi
    fi
else
    COMPOSE=none
    todo "instalar o Docker Engine + Compose (script oficial get.docker.com)"
fi

# daemon.json desejado = atual + bip/ipv6/fixed-cidr-v6
desired_daemon_json() {
    if command -v python3 >/dev/null; then
        python3 - "$DAEMON_JSON" "$BIP" "$V6" <<'PY'
import json, os, sys
path, bip, v6 = sys.argv[1:4]
cur = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    cur = json.load(open(path))
cur.update({"bip": bip, "ipv6": True, "fixed-cidr-v6": v6})
print(json.dumps(cur, indent=2))
PY
    elif command -v jq >/dev/null; then
        if [ -s "$DAEMON_JSON" ]; then jq --arg b "$BIP" --arg v "$V6" '. + {bip:$b, ipv6:true, "fixed-cidr-v6":$v}' "$DAEMON_JSON"
        else jq -n --arg b "$BIP" --arg v "$V6" '{bip:$b, ipv6:true, "fixed-cidr-v6":$v}'; fi
    elif [ ! -s "$DAEMON_JSON" ]; then
        printf '{\n  "bip": "%s",\n  "ipv6": true,\n  "fixed-cidr-v6": "%s"\n}\n' "$BIP" "$V6"
    else
        return 1
    fi
}
normalize_json() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))' 2>/dev/null || cat; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DAEMON_CHANGE=no
if desired_daemon_json > "$TMP/daemon.json"; then
    if [ -s "$DAEMON_JSON" ] && [ "$(normalize_json < "$DAEMON_JSON")" = "$(normalize_json < "$TMP/daemon.json")" ]; then
        ok "daemon.json já tem IPv6 e a rede padrão $BIP"
    else
        DAEMON_CHANGE=yes
        todo "ajustar $DAEMON_JSON (IPv6 + rede padrão $BIP), mantendo o que já existe:"
        diff -u <( [ -s "$DAEMON_JSON" ] && cat "$DAEMON_JSON" || echo "{}" ) "$TMP/daemon.json" | tail -n +3 | sed 's/^/           /' || true
    fi
else
    die "$DAEMON_JSON existe e não tenho python3 nem jq para mesclar com segurança. Instale python3 ou jq."
fi

# A rede padrão escolhida colide com algo da máquina?
BIP_NET=$(echo "$BIP" | sed 's#\.[0-9]*/#.0/#')
CONFLICT=$(ip -4 route show to match "${BIP%/*}" 2>/dev/null | grep -vE '^default|dev docker0' || true)
[ -z "$CONFLICT" ] && ok "rede $BIP_NET livre" || warn "a rede $BIP_NET colide com uma rota existente: $CONFLICT"
TRANSIT=$(ip -4 route show to match 128.128.0.1 2>/dev/null | grep -vE '^default|dev pgun0' || true)
[ -z "$TRANSIT" ] && ok "rede de trânsito 128.128.0.0/24 livre" || warn "a rede de trânsito 128.128.0.0/24 colide com: $TRANSIT"

# Portas do IKE ocupadas por outro processo?
IKE=$(ss -Hlunp 2>/dev/null | grep -E ':(500|4500)\s' | grep -v -E 'charon|docker' || true)
[ -z "$IKE" ] && ok "portas UDP 500/4500 livres" || warn "outro processo usa as portas do IKE: $IKE"

# Módulos de kernel
MISS_MOD=""
for m in ppp_generic l2tp_ppp esp4 xfrm_user; do
    modprobe -n "$m" 2>/dev/null || [ -d "/sys/module/$m" ] || MISS_MOD="$MISS_MOD $m"
done
[ -z "$MISS_MOD" ] && ok "módulos de kernel L2TP/PPP/IPsec disponíveis" || die "faltam módulos de kernel:$MISS_MOD"

# Projeto
if [ -d "$DIR/.git" ]; then ok "projeto já existe em $DIR ($(git -C "$DIR" describe --tags --always 2>/dev/null))"
else todo "baixar o projeto em $DIR"; fi
systemctl is-enabled portal-gun.service >/dev/null 2>&1 && ok "serviço de boot já instalado" || todo "instalar o serviço de boot (systemd)"

if [ "$MODE" = check ]; then
    echo; echo "Modo --check: nada foi alterado. Avisos: $WARNINGS"
    exit 0
fi

# ---------------------------------------------------------------------------
if [ -n "$MISSING_DEPS" ] && [ -n "$PKG" ]; then
    step "Instalando dependências:$MISSING_DEPS"
    case "$PKG" in
        apt-get) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl whiptail iproute2 ;;
        dnf|yum) $PKG install -y -q git curl newt iproute ;;
        zypper)  zypper -q install -y git curl newt iproute2 ;;
    esac
fi

if [ "$DOCKER" = none ]; then
    step "Instalando o Docker Engine (get.docker.com)"
    curl -fsSL https://get.docker.com | sh
    COMPOSE=ok
elif [ "$COMPOSE" = none ]; then
    step "Instalando o Docker Compose v2"
    # 1) pacote do repositório oficial do Docker; 2) pacote do Ubuntu; 3) binário oficial como plugin
    case "$PKG" in
        apt-get) apt-get install -y -qq docker-compose-plugin 2>/dev/null || apt-get install -y -qq docker-compose-v2 2>/dev/null || true ;;
        dnf|yum|zypper) $PKG install -y docker-compose-plugin >/dev/null 2>&1 || true ;;
    esac
    if ! compose_cmd >/dev/null; then
        PLUGDIR=/usr/local/lib/docker/cli-plugins
        mkdir -p "$PLUGDIR"
        curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o "$PLUGDIR/docker-compose"
        chmod 755 "$PLUGDIR/docker-compose"
        ok "Compose v2 instalado como plugin em $PLUGDIR"
    fi
fi
systemctl enable --now docker >/dev/null 2>&1 || true
CC=$(compose_cmd) || die "o Docker Compose v2 não ficou disponível"
ok "usando '$CC' ($($CC version --short))"

if [ "$DAEMON_CHANGE" = yes ]; then
    step "Configurando o Docker: IPv6 + rede padrão $BIP"
    # Recalcula (o get.docker.com pode ter criado o arquivo)
    desired_daemon_json > "$TMP/daemon.json"
    RUNNING=$(docker ps -q 2>/dev/null | wc -l)
    if [ "$DOCKER" = none ] || confirm "Aplicar no $DAEMON_JSON e reiniciar o Docker? ($RUNNING container(s) rodando serão reiniciados)"; then
        mkdir -p /etc/docker
        [ -f "$DAEMON_JSON" ] && cp -p "$DAEMON_JSON" "$DAEMON_JSON.bak-portal-gun-$(date +%Y%m%d%H%M%S)"
        if dockerd --help 2>/dev/null | grep -q -- '--validate'; then
            dockerd --validate --config-file "$TMP/daemon.json" >/dev/null || die "configuração do daemon inválida; nada foi alterado"
        fi
        install -m 644 "$TMP/daemon.json" "$DAEMON_JSON"
        systemctl restart docker
        for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
        docker info >/dev/null 2>&1 || die "o Docker não voltou após a mudança. Backup em $DAEMON_JSON.bak-portal-gun-*"
        ok "$(docker network inspect bridge --format 'bridge: {{range .IPAM.Config}}{{.Subnet}} {{end}}IPv6={{.EnableIPv6}}')"
    else
        warn "daemon.json não alterado (IPv6/rede padrão continuam como estavam)"
    fi
fi

if [ "$PG_USER" != root ] && getent group docker >/dev/null; then
    id -nG "$PG_USER" | grep -qw docker || { usermod -aG docker "$PG_USER"; ok "$PG_USER adicionado ao grupo docker (vale a partir do próximo login)"; }
fi

step "Baixando o portal-gun em $DIR"
if [ -d "$DIR/.git" ]; then
    git -C "$DIR" pull --ff-only -q || warn "não consegui atualizar $DIR (alterações locais?); seguindo com a versão atual"
else
    git clone -q -b "$BRANCH" "$REPO" "$DIR"
fi
chown -R "$PG_USER": "$DIR"
ok "versão $(git -C "$DIR" describe --tags --always)"

if [ "$START" = yes ]; then
    step "Credenciais e containers"
    if [ "$HAS_TTY" = yes ]; then
        (cd "$DIR" && ./start.sh </dev/tty)
    elif grep -qE "^L2TP_PASS='?[^t']" "$DIR/.env" 2>/dev/null; then
        (cd "$DIR" && $CC up -d --build)
    else
        die "sem terminal para pedir as credenciais. Rode num terminal, ou preencha $DIR/.env e rode de novo."
    fi
    [ -f "$DIR/.env" ] && chown "$PG_USER": "$DIR/.env" && chmod 600 "$DIR/.env"
fi

step "Serviço de boot"
(cd "$DIR" && echo n | ./install.sh >/dev/null)
ok "portal-gun.service habilitado (sobe no boot)"

if [ "$START" = yes ]; then
    step "Aguardando a sessão BGP (até 2 min)"
    for _ in $(seq 1 40); do
        n=$(ip route | grep -c 'via 128.128.0.2' || true)
        [ "$n" -gt 0 ] && break
        sleep 3
    done
    if [ "$n" -gt 0 ]; then ok "$n rotas aprendidas instaladas no host"
    else warn "nenhuma rota ainda. Veja: cd $DIR && $CC logs vpn"; fi
fi

cat <<EOF

Pronto (avisos: $WARNINGS). Comandos úteis:
  cd $DIR
  $CC ps                                            # containers
  docker exec -it portal-gun-frr vtysh -c 'show bgp summary'   # sessão BGP
  ./update.sh                                                  # atualizar
EOF
[ "$START" = no ] && echo "  ./start.sh                                                   # informar credenciais e subir"
exit 0
