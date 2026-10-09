#!/bin/bash
# Compara a versão local com a do GitHub e atualiza.
#   ./update.sh          -> mostra o que mudou, pergunta e atualiza
#   ./update.sh --check  -> só verifica (exit 0 = atualizado, 10 = há atualização)
#   ./update.sh -y       -> atualiza sem perguntar
set -euo pipefail
cd "$(dirname "$0")"

MODE=update
ASSUME_YES=no
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -y|--yes) ASSUME_YES=yes ;;
        -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Opção desconhecida: $arg" >&2; exit 2 ;;
    esac
done

version() { git describe --tags --always "$1" 2>/dev/null; }

git rev-parse --git-dir >/dev/null 2>&1 || { echo "Este diretório não é um clone git do portal-gun." >&2; exit 1; }
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
    || { echo "A branch atual não acompanha nenhuma branch remota." >&2; exit 1; }

echo "Consultando o GitHub..."
if ! git fetch --quiet --tags origin; then
    echo "Não consegui acessar o GitHub. Verifique a internet e o acesso ao repositório (gh auth status)." >&2
    exit 1
fi

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "$UPSTREAM")
BASE=$(git merge-base HEAD "$UPSTREAM")

echo "Versão instalada: $(version HEAD)"
echo "Versão no GitHub: $(version "$UPSTREAM")"
echo

if [ "$LOCAL" = "$REMOTE" ]; then
    echo "Você já está na versão mais recente."
    exit 0
fi
if [ "$REMOTE" = "$BASE" ]; then
    echo "A versão local está à frente do GitHub (commits locais não enviados). Nada a atualizar."
    exit 0
fi
if [ "$LOCAL" != "$BASE" ]; then
    echo "A versão local e a do GitHub divergiram (há commits locais não enviados)." >&2
    echo "Resolva manualmente com 'git status' e 'git log'." >&2
    exit 1
fi

echo "Novidades disponíveis:"
git log --no-merges --format='  - %s (%h, %ad)' --date=short "HEAD..$UPSTREAM"
echo
echo "Arquivos alterados:"
git diff --stat "HEAD..$UPSTREAM" | sed 's/^/  /'
echo

[ "$MODE" = check ] && { echo "Rode ./update.sh para atualizar."; exit 10; }

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Há alterações locais em arquivos do projeto:" >&2
    git status --short --untracked-files=no | sed 's/^/  /' >&2
    echo "Guarde-as com 'git stash' (ou descarte com 'git checkout -- .') e rode de novo." >&2
    exit 1
fi

if [ "$ASSUME_YES" != yes ]; then
    read -rp "Atualizar agora? Os containers serão reconstruídos e a VPN reconecta (~30s). [s/N] " ans
    [[ "$ans" =~ ^[sSyY]$ ]] || { echo "Cancelado."; exit 0; }
fi

git merge --ff-only --quiet "$UPSTREAM"
echo "Código atualizado para $(version HEAD)."

# Variáveis novas no .env.example que ainda não existem no .env
if [ -f .env ]; then
    missing=$(comm -23 \
        <(grep -oE '^#?[A-Z_]+=' .env.example | tr -d '#=' | sort -u) \
        <(grep -oE '^#?[A-Z_]+=' .env | tr -d '#=' | sort -u))
    if [ -n "$missing" ]; then
        echo
        echo "Opções novas no .env.example (opcionais; usam o padrão se não estiverem no .env):"
        echo "$missing" | sed 's/^/  - /'
    fi
fi

echo
if [ -n "$(docker compose ps -q 2>/dev/null)" ]; then
    echo "Reconstruindo e reiniciando os containers..."
    docker compose up -d --build
else
    echo "Containers parados: só reconstruindo as imagens. Suba com 'docker compose up -d' ou ./start.sh."
    docker compose build
fi

echo
echo "Atualizado para $(version HEAD)."
