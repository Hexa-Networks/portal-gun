# Resolve o comando do Docker Compose v2. Use com: . lib/compose.sh; compose up -d
#   - "docker compose"  -> plugin (get.docker.com, repositório oficial, Ubuntu docker-compose-v2)
#   - "docker-compose"  -> binário standalone v2 (ex.: Debian 13)
# O Compose v1 (Python, "docker-compose" 1.x, ex.: apt do Debian 12) NÃO é suportado:
# ele não entende o formato atual do docker-compose.yml. O linux/setup.sh instala o v2.

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"; return 0
    fi
    if command -v docker-compose >/dev/null 2>&1; then
        case "$(docker-compose version --short 2>/dev/null)" in
            v1.*|1.*) ;;
            ?*) echo "docker-compose"; return 0 ;;
        esac
    fi
    return 1
}

compose() {
    local cmd
    if ! cmd=$(compose_cmd); then
        echo "ERRO: Docker Compose v2 não encontrado (nem 'docker compose' nem 'docker-compose' 2.x)." >&2
        command -v docker-compose >/dev/null 2>&1 && \
            echo "      Só existe o Compose v1 ($(docker-compose version --short 2>/dev/null)), que não é suportado." >&2
        echo "      Rode: sudo ./linux/setup.sh   (instala o Compose v2)" >&2
        return 127
    fi
    $cmd "$@"
}
