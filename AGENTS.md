# VoiceDraft

This is a personal experimental project, not a company project.
Follow this repository's instructions and documentation. Company-specific workflows do not apply.
Do not register this project or write its code, configuration, documentation, or lessons to a company knowledge base.

This is a standalone macOS app with a self-hosted encrypted synchronization service.
Read `docs/architecture.md` before changing boundaries and `docs/roadmap.md` for scope.
The initial release supported Qwen only. The user-authorized expansion in `docs/selected-features.md` adds Doubao, Whisper-compatible and Google Speech plus generic writing protocols. Do not add unselected providers or cloud inference proxies.

Run `swift test --disable-sandbox` and `python3 -m unittest discover -s server -v`.
Package with `./scripts/build-app.sh`. No third-party Swift or Python dependencies.
Do not send real audio, selections, or credentials in automated tests.
