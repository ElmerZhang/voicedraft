#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p .local
export GOCACHE="${GOCACHE:-$PWD/.build/go-cache}"
go -C server build -trimpath -o "$PWD/.local/voicedraft-sync" ./cmd/voicedraft-sync
if [ ! -f .local/access-token ]; then
  .local/voicedraft-sync --generate-token > .local/access-token
fi
export VOICEDRAFT_SYNC_TOKEN="$(cat .local/access-token)"
export VOICEDRAFT_DB="$PWD/.local/vault.sqlite3"
exec .local/voicedraft-sync
