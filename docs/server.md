# Sync server deployment

The Go server is a single-user/single-vault service with a bearer token. It stores encrypted model configuration and vocabulary. It has no plaintext provider keys, decryption passphrase, audio pipeline, web dashboard, registration, or account recovery. It builds into a standalone binary; Python is not required to build or run the service.

## Local development

Install Go 1.25 or newer, then run `./scripts/run-server.sh` from the repository. The first build needs access to the Go module proxy (or a populated module cache). The script builds `.local/voicedraft-sync`, creates `.local/access-token` with a random token and `.local/vault.sqlite3`, all excluded from Git. The token persists across restarts. The process listens on loopback by default and exits gracefully with Control-C or SIGTERM. No C compiler or system SQLite installation is required for a normal build.

Use `http://127.0.0.1:8765` in the Mac app. Copy the token from the local file into the **Server access token** field. Choose a separate **Sync passphrase** and save it somewhere recoverable. Save the connection before using sync buttons.

To build and run the binary directly, from the repository root:

```sh
mkdir -p .local
(cd server && CGO_ENABLED=0 go build -trimpath -o ../.local/voicedraft-sync ./cmd/voicedraft-sync)
# Generate a token once and store it securely:
.local/voicedraft-sync --generate-token
# Supply VOICEDRAFT_SYNC_TOKEN through your shell or service environment.
VOICEDRAFT_DB="$PWD/.local/vault.sqlite3" .local/voicedraft-sync
```

For Linux, add `GOOS=linux GOARCH=amd64` (or `arm64`) to the build command. The runtime binary needs only a writable database directory; HTTPS remains the reverse proxy's responsibility.

## Upgrading an existing Python deployment

1. Stop the existing service. Back up the database (including any remaining `-wal`/`-shm` companions) and access token.
2. Replace the server code/image and start the Go binary with the same `VOICEDRAFT_DB` and `VOICEDRAFT_SYNC_TOKEN`. For Compose, retain the same project name, `vault` volume and `.env`, then run `docker compose up -d --build`. Do not remove the volume with `down -v`.
3. Verify `/healthz`, then fetch the existing configuration from a Mac. The Go service reads the same `vault(id, revision, payload)` table; no export/import or client upgrade is required. Existing revisions and ciphertext are retained.

The local `run-server.sh` also reuses the existing `.local/access-token` and `.local/vault.sqlite3`. For rollback, stop the Go service before starting the old service against the same database; the on-disk schema remains compatible.

## HTTPS deployment for multiple devices

1. Copy `server/` to your server. Docker Compose uses a Go build stage and a minimal runtime image containing the static binary. It runs as UID/GID 10001, matching the previous service's database ownership.
2. Create a private `.env` next to `compose.yaml` containing `VOICEDRAFT_SYNC_TOKEN=<a random token of at least 32 characters>`. Generate a token with `openssl rand -hex 32` or the built binary's `--generate-token` command; set the file's permissions to 0600.
3. Run `docker compose up -d --build`. The named volume preserves the SQLite vault.
4. Put Caddy or your existing HTTPS reverse proxy in front of `127.0.0.1:8765`. `Caddyfile.example` is a starting point; replace the domain and configure DNS. Install Caddy separately using its official instructions. Apply request size, connection, and rate limits appropriate to your host.
5. On each Mac, use the shared HTTPS URL, server access token, and client-only passphrase. A new device downloads the server copy explicitly.

The supplied Compose mapping binds to loopback and is intended for an on-host HTTPS reverse proxy. For a proxy in another container, attach the service to a private Docker network and proxy to `sync:8765` instead.

Public deployment is not performed automatically by this repository. A domain, host, and certificate are required for use across physical devices. LAN plaintext URLs are deliberately rejected by the app; use HTTPS, including on a private VPN.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `VOICEDRAFT_SYNC_TOKEN` | required | At least 32 characters, no whitespace; do not reuse a provider API key |
| `VOICEDRAFT_HOST` | `127.0.0.1` | Listening interface (`0.0.0.0` inside the container) |
| `VOICEDRAFT_PORT` | `8765` | HTTP listening port |
| `VOICEDRAFT_DB` | `./data/vault.sqlite3` | Persistent database path |

## Operations

- Health: `GET /healthz` is unauthenticated and returns protocol version 1. Other endpoints require the bearer token.
- Backups: use SQLite's backup API or stop the service before copying the database; copying just the live main database while WAL is active is not sufficient. Back up the token separately. Never place the client passphrase on the server.
- Restore: restore the database and restart. Devices detect an older revision; inspect the restored state and explicitly download when appropriate.
- Token rotation: change the server environment and restart, then update all devices. The database is independent of the token. The app treats the new connection as uninitialized; download the existing vault explicitly.
- Passphrase rotation: no in-place workflow yet. Preserve a working client and backup; migrate to a new empty vault with the new passphrase, then reconnect all devices.
- Server logs omit request bodies, authentication headers, URL paths, and ciphertext. Configure proxy logs to avoid logging credentials or request bodies as well.
- SIGINT/SIGTERM stops accepting requests and allows up to ten seconds for active requests before closing the database. HTTP header/body/write/idle deadlines and a 16 KiB header budget bound connections; apply per-client rate limits at the reverse proxy.

## HTTP contract

`GET /v1/sync` returns revision 0/null payload for an empty vault, or the latest encrypted record. `PUT /v1/sync` accepts `application/json` with exactly `revision` and `payload`. The client sends its last fetched revision. The transaction either returns the new record or HTTP 409. Retrying a rejected write without fetching is not valid.

Responses: 400 invalid envelope, 401 unauthorized, 404 wrong path, 405 unsupported method, 409 conflict, 413 invalid body size, 415 wrong content type, 503 storage unavailable. PUT requires a positive `Content-Length`; chunked uploads are rejected. Maximum request size is 1,400,000 bytes; decoded ciphertext is at most 1,000,000 bytes. Schema, version, KDF parameters, base64, and lengths are checked before persistence. The client performs authentication-tag verification and plaintext validation.

## Verification

From `server/`, run `go vet ./...`, `go build ./...`, and `go test -race ./...`. Tests include authentication, framing/size bounds, encrypted envelopes, concurrent independent connections, revision conflicts, storage errors, persistence, private file permissions, and a synthetic database created by the original Python service. The driver version and checksums are pinned in `go.mod`/`go.sum`.

From the repository root, `./scripts/test-all.sh` additionally checks localization and runs Swift tests against an isolated Go sync/provider fixture server. This full integration path requires loopback listening permission. Python 3 remains a developer-only dependency for the existing localization checkers; neither Go service tests nor the production server use it.
