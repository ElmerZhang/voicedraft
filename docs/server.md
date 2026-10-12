# Sync server deployment

The server is a single-user/single-vault service with a bearer token. It stores encrypted model configuration and vocabulary. It has no provider keys, decryption passphrase, audio pipeline, web dashboard, registration, or account recovery.

## Local development

Run `./scripts/run-server.sh` from the repository. It creates `.local/access-token` with a random token and `.local/vault.sqlite3`, both excluded from Git. The token persists across restarts. The process listens on loopback only and exits with Control-C.

Use `http://127.0.0.1:8765` in the Mac app. Copy the token from the local file into the **Server access token** field. Choose a separate **Sync passphrase** and save it somewhere recoverable. Save the connection before using sync buttons.

## HTTPS deployment for multiple devices

1. Copy `server/` to your server. Docker Compose builds the Python service without pip dependencies.
2. Create a private `.env` next to `compose.yaml` containing `VOICEDRAFT_SYNC_TOKEN=<a random token of at least 32 characters>`. Generate a token with `python3 -c 'import secrets; print(secrets.token_urlsafe(32))'`; set the file's permissions to 0600.
3. Run `docker compose up -d --build`. The named volume preserves the SQLite vault.
4. Put Caddy or your existing HTTPS reverse proxy in front of `127.0.0.1:8765`. `Caddyfile.example` is a starting point; replace the domain and configure DNS. Install Caddy separately using its official instructions. Apply request size, connection, and rate limits appropriate to your host.
5. On each Mac, use the shared HTTPS URL, server access token, and client-only passphrase. A new device downloads the server copy explicitly.

Do not expose Python's HTTP server directly to the public internet. The supplied Compose mapping binds to loopback and is intended for an on-host reverse proxy. For a proxy in another container, attach the service to a private Docker network and proxy to `sync:8765` instead.

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

## HTTP contract

`GET /v1/sync` returns revision 0/null payload for an empty vault, or the latest encrypted record. `PUT /v1/sync` accepts `application/json` with exactly `revision` and `payload`. The client sends its last fetched revision. The transaction either returns the new record or HTTP 409. Retrying a rejected write without fetching is not valid.

Responses: 400 invalid envelope, 401 unauthorized, 404 wrong path, 409 conflict, 413 oversized body, 415 wrong content type, 503 storage unavailable. Maximum request size is 1,400,000 bytes; decoded ciphertext is at most 1,000,000 bytes. Schema, version, KDF parameters, base64, and lengths are checked before persistence. The client performs authentication-tag verification and plaintext validation.
