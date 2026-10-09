#!/bin/bash
# Sincroniza as rotas BGP aprendidas na VM do Colima para a tabela de rotas do macOS.
# Roda como root via launchd (instalado pelo macos/setup.sh). Compatível com o bash 3.2 do macOS.
#
# A cada INTERVAL segundos:
#   - lê as rotas "proto bgp" da VM (pelo container portal-gun-frr);
#   - adiciona no macOS as novas, com gateway = IP da VM;
#   - remove as que sumiram;
#   - se a VM ou o FRR estiverem fora, remove todas (evita buraco negro).
set -u

CONF=${PG_CONF:-/usr/local/etc/portal-gun/route-sync.conf}
# shellcheck disable=SC1090
. "$CONF"   # PG_USER, PG_HOME, COLIMA_PROFILE, DOCKER_BIN, COLIMA_BIN

INTERVAL=${INTERVAL:-10}
STATE=${PG_STATE:-/var/run/portal-gun-routes}      # linhas "prefixo gateway" instaladas por este script
TMP=$(mktemp -d /tmp/portal-gun-rs.XXXXXX)
export DOCKER_HOST="unix://$PG_HOME/.colima/$COLIMA_PROFILE/docker.sock"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

vm_ip() {
    local ip
    ip=$(sudo -H -u "$PG_USER" "$COLIMA_BIN" ls -p "$COLIMA_PROFILE" -j 2>/dev/null \
        | sed -n 's/.*"address":"\([0-9.]*\)".*/\1/p' | head -1)
    echo "$ip"
}

route_cmd() {   # route_cmd add|delete <prefixo> <gateway>
    local op=$1 p=$2 gw=$3
    case "$p" in
        */32) route -n "$op" -host "${p%/32}" "$gw" ;;
        *)    route -n "$op" -net "$p" "$gw" ;;
    esac
}

flush_all() {
    [ -s "$STATE" ] || return 0
    local n=0 p gw
    while read -r p gw; do
        route_cmd delete "$p" "$gw" >/dev/null 2>&1 && n=$((n + 1))
    done < "$STATE"
    : > "$STATE"
    log "removidas $n rotas"
}

cleanup() { flush_all; rm -rf "$TMP"; exit 0; }
trap cleanup TERM INT

touch "$STATE"
flush_all   # rotas de uma execução anterior (ex.: crash) são refeitas do zero
log "iniciado (perfil colima: $COLIMA_PROFILE, intervalo: ${INTERVAL}s)"

while true; do
    VMIP=$(vm_ip)
    if [ -z "$VMIP" ] || ! "$DOCKER_BIN" exec portal-gun-frr ip -4 route show proto bgp > "$TMP/raw" 2>/dev/null; then
        if [ -s "$STATE" ]; then
            log "VM ou FRR indisponível"
            flush_all
        fi
        sleep "$INTERVAL"
        continue
    fi

    awk '{p=$1; if (p !~ /\//) p=p"/32"; print p}' "$TMP/raw" | sort -u > "$TMP/want"

    # Se o IP da VM mudou, refaz tudo com o gateway novo
    if [ -s "$STATE" ] && [ "$(awk 'NR==1{print $2}' "$STATE")" != "$VMIP" ]; then
        log "IP da VM mudou para $VMIP"
        flush_all
    fi

    awk '{print $1}' "$STATE" | sort -u > "$TMP/have"
    comm -13 "$TMP/have" "$TMP/want" > "$TMP/add"
    comm -23 "$TMP/have" "$TMP/want" > "$TMP/del"

    added=0; removed=0; failed=0
    while read -r p; do
        route_cmd delete "$p" "$VMIP" >/dev/null 2>&1 && removed=$((removed + 1))
    done < "$TMP/del"
    cp "$STATE" "$TMP/state"

    while read -r p; do
        # Só registra o que foi realmente adicionado: assim nunca apaga uma rota que não é nossa
        if route_cmd add "$p" "$VMIP" >/dev/null 2>&1; then
            echo "$p $VMIP" >> "$TMP/state"
            added=$((added + 1))
        else
            failed=$((failed + 1))
        fi
    done < "$TMP/add"

    # Novo estado: o que já estava + o que foi adicionado, filtrado pelos prefixos desejados
    awk 'NR==FNR{w[$1]=1; next} ($1 in w)' "$TMP/want" "$TMP/state" > "$STATE"

    # Falhas (ex.: a rota já existe na LAN do Mac) são tentadas de novo, mas só logadas quando mudam
    if [ $added -gt 0 ] || [ $removed -gt 0 ] || [ $failed -ne "${prev_failed:-0}" ]; then
        log "via $VMIP: +$added -$removed (falhas: $failed, total: $(wc -l < "$STATE" | tr -d ' '))"
    fi
    prev_failed=$failed
    sleep "$INTERVAL"
done
