#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
export GOCACHE="${GOCACHE:-$root/.build/go-cache}"
python3 scripts/check-localizations.py
python3 scripts/check-desktop-localizations.py
cd server
go vet ./...
go build ./...
go test -race ./...
go run ./cmd/integration-test -root "$root"
