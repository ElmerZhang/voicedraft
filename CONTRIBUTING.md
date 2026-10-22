# Contributing to VoiceDraft

Thank you for helping. VoiceDraft is licensed under AGPL-3.0-only. Please read this page before opening a pull request.

## Contributor license agreement

A signed [CLA](CLA.md) is required before a pull request can be merged. Sign by adding this line to your pull request:

```
I have read the CLA Document and I hereby sign the CLA
```

## Build and test

Run both test suites before submitting:

```sh
swift test --disable-sandbox
cd server && go test -race ./...
```

For Go changes also run these in `server/`:

```sh
go fmt ./...
go vet ./...
go build ./...
```

`./scripts/test-all.sh` includes the Go checks and Swift integration against an isolated Go fixture server. Package the app with `./scripts/build-app.sh`.

## Rules

- No third-party Swift packages. The Go server uses the pinned pure-Go `modernc.org/sqlite` driver.
- Keep the sync protocol and the SQLite schema compatible with existing deployments.
- Do not add providers that are not already selected in [docs/selected-features.md](docs/selected-features.md), and do not add cloud inference proxies. Model calls go directly from the Mac to the provider the user configured.
- Do not add telemetry. The sync server must never see plaintext, keys, audio or history.
- Update the documentation in the same change as the code. Read [docs/architecture.md](docs/architecture.md) before changing boundaries and [docs/roadmap.md](docs/roadmap.md) for scope.
- Do not send real audio, selections or credentials in automated tests. Use synthetic fixtures.
- Use a single clear summary line for each commit message.

## Reporting vulnerabilities

Do not open a public issue for security problems. See [SECURITY.md](SECURITY.md).
