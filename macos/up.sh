#!/bin/bash
# Sobe a VM do Colima e os containers. Chamado no login pelo LaunchAgent (e pelo setup.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${COLIMA_PROFILE:-portal-gun}
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! colima status -p "$PROFILE" >/dev/null 2>&1; then
    echo "[portal-gun] subindo a VM do Colima ($PROFILE)"
    colima start "$PROFILE"
fi

echo "[portal-gun] subindo os containers"
docker --context "colima-$PROFILE" compose up -d
