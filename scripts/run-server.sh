#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p .local
if [ ! -f .local/access-token ]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > .local/access-token
fi
export VOICEDRAFT_SYNC_TOKEN="$(cat .local/access-token)"
export VOICEDRAFT_DB="$PWD/.local/vault.sqlite3"
exec python3 server/server.py
