# VoiceDraft

Read `~/.agents/company-knowledge/10-team/agents/shared-agent-rules.md`.

This is a standalone macOS app with a self-hosted encrypted synchronization service.
Read `docs/architecture.md` before changing boundaries and `docs/roadmap.md` for scope.
The first release supports Alibaba Cloud Model Studio Qwen models only.

Run `swift test --disable-sandbox` and `python3 -m unittest discover -s server -v`.
Package with `./scripts/build-app.sh`. No third-party Swift or Python dependencies.
Do not send real audio, selections, or credentials in automated tests.
