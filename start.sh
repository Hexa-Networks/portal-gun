#!/bin/bash
# Pergunta as credenciais da VPN/BGP (dialog), grava o .env e sobe os containers.
#   ./start.sh            -> pergunta só o que faltar no .env e sobe
#   ./start.sh --reconfig -> pergunta tudo de novo
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=.env
RECONFIG=no
[ "${1:-}" = "--reconfig" ] && RECONFIG=yes

[ -f "$ENV_FILE" ] || cp .env.example "$ENV_FILE"
chmod 600 "$ENV_FILE"

get() {
    local v
    v=$(grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
    v=${v#\'}; v=${v%\'}
    printf '%s' "$v"
}

set_var() {
    local key=$1 val=$2 tmp
    tmp=$(mktemp)
    grep -vE "^$key=" "$ENV_FILE" > "$tmp" || true
    # Aspas simples: o compose não interpreta $ nem # dentro do valor.
    printf "%s='%s'\n" "$key" "$val" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
}

UI=tty
command -v whiptail >/dev/null && [ -t 0 ] && UI=whiptail

# ask <VAR> <texto> <secret:yes|no>
ask() {
    local key=$1 text=$2 secret=$3 cur val
    cur=$(get "$key")
    if [ "$RECONFIG" = no ] && [ -n "$cur" ] && [ "$cur" != "troque-me" ]; then
        return
    fi
    [ "$cur" = "troque-me" ] && cur=""
    while true; do
        if [ "$UI" = whiptail ]; then
            if [ "$secret" = yes ]; then
                val=$(whiptail --title "Portal Gun" --passwordbox "$text" 10 70 3>&1 1>&2 2>&3) || { echo "Cancelado."; exit 1; }
            else
                val=$(whiptail --title "Portal Gun" --inputbox "$text" 10 70 "$cur" 3>&1 1>&2 2>&3) || { echo "Cancelado."; exit 1; }
            fi
        else
            if [ "$secret" = yes ]; then
                read -rsp "$text: " val; echo
            else
                read -rp "$text [${cur}]: " val
                val=${val:-$cur}
            fi
        fi
        if [[ "$val" == *"'"* || "$val" == *'"'* ]]; then
            [ "$UI" = whiptail ] && whiptail --title "Portal Gun" --msgbox "Aspas (' ou \") não são suportadas." 8 50 || echo "Aspas (' ou \") não são suportadas."
            continue
        fi
        [ -n "$val" ] && break
        [ "$UI" = whiptail ] && whiptail --title "Portal Gun" --msgbox "Valor obrigatório." 8 40 || echo "Valor obrigatório."
    done
    set_var "$key" "$val"
}

ask LNS_IP        "IP do LNS (VPN-SERVER)"            no
ask L2TP_USER     "Usuário L2TP/PPP"                  no
ask L2TP_PASS     "Senha L2TP/PPP"                    yes
ask IPSEC_PSK     "Chave pré-compartilhada (PSK) do IPsec" yes
ask BGP_LOCAL_AS  "ASN local"                         no
ask BGP_REMOTE_AS "ASN do LNS"                        no

# Avisa se há versão nova no GitHub (não bloqueia se estiver offline)
TIMEOUT=""; command -v timeout >/dev/null && TIMEOUT="timeout 15"
if $TIMEOUT ./update.sh --check >/dev/null 2>&1; then :; else
    [ $? -eq 10 ] && echo ">>> Há uma versão nova do portal-gun no GitHub. Rode ./update.sh para ver e atualizar." && echo
fi

docker compose up -d --build
echo
echo "Containers no ar. Acompanhe com:"
echo "  docker compose logs -f"
echo "  docker exec -it portal-gun-frr vtysh -c 'show bgp summary'"

if [ "$(uname)" = Linux ] && ! systemctl is-enabled portal-gun.service >/dev/null 2>&1; then
    echo
    echo "Para subir automaticamente no boot, rode como root: ./install.sh"
fi
