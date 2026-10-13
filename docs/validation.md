# Validation record

## Desktop navigation and model entry — 2026-10-13

- Added Home, History, Dictionary, and the settings modal with its eight-language desktop catalog. Models remain accessible through Settings; the sidebar card no longer has a Models button. Interactive/capture preview modes use synthetic in-memory data and avoid persisted settings, Keychain reads, and global shortcuts.
- The combined working tree passed 40 Swift tests, with 2 existing localhost integration tests skipped and no failures. Both localization checks passed (292 shared messages and 59 desktop messages in each of eight languages). Release packaging, icon validation, signature verification, Info.plist validation, and `git diff --check` passed after the button removal.
- The six Python service tests remain blocked during setup by the sandbox's localhost socket restriction. No app restart, joint native UI acceptance, microphone capture, or provider request was performed for this commit.

## Global vocabulary, interface languages, and audio inputs — 2026-10-13

- Replaced model-owned vocabulary with one app-wide source: term, enablement, strength, priority, language, preferred spelling, aliases, and IPA pronunciation. Adapter projections keep the source intact while enforcing the supported Qwen formats and limits. Schema-v1/v2 migrations preserve profile/credential associations, merge legacy terms deterministically, preserve remote vocabulary references, and normalize legacy tab separators without dropping long terms.
- Added Simplified Chinese, Traditional Chinese, English, Japanese, Korean, German, French, and Spanish catalogs, local language selection, localized app errors/menus, and microphone usage descriptions. `scripts/check-localizations.py` passed for 292 messages in all eight languages. Swift tests check actual translated lookup (including SwiftPM's lowercased Chinese resource directories), locale fallback, and verbatim interpolation of user content.
- Added local input-device UID selection and per-take AVCaptureSession routing. Missing explicit devices fail instead of silently falling back. The floating panel receives the actual bound device name. Each take owns its recording file and callbacks; cancellation cannot clean up a later take, and cancelled finalization is checked before inference.
- The isolated feature snapshot, excluding the parallel desktop redesign, passed `swift test --disable-sandbox`: 40 tests passed, 2 existing localhost integration tests skipped, 0 failures. Coverage includes vocabulary projection/migration/encrypted round trip, localization, and device-resolution policy. The release build, icon validation, signature verification, and Info.plist validation passed with localization bundles packaged inside the app.
- `python3 -m unittest discover -s server -v` encountered six setup errors because this execution sandbox denies localhost `socket.bind` with `PermissionError`; no server assertions ran. The service code is unchanged. An earlier automatic approval review rejected sandbox escalation, so it was not retried.
- The shared working tree also contains a separate desktop redesign. At the user's request, its changes are preserved and joint native UI acceptance/restart is deferred until that task is complete. This entry does not claim visual acceptance of the final combined UI.
- No real microphone capture or provider request was made. Real device routing, unplug/interruption behavior, permission prompts, resulting WAV format, and the live HUD device label still require a user recording test. Native-language copy review remains pending.

## Model catalog and protocol adapters — 2026-10-13

- Confirmed the running configuration used `qwen-audio-3.1-asr-flash-message` with a chat-completions HTTP endpoint and showed HTTP 400. The provider's [Message WebSocket guide](https://help.aliyun.com/zh/model-studio/qwen-asr-message-websocket-api) specifies task-based WebSocket inference. The old app did not retain the original provider error code, so no more specific historical error is claimed.
- Added a catalog for four ASR models across three adapters: compatible HTTP Qwen3-ASR-Flash, native HTTP Qwen Audio 3.0/3.1 Flash, and WebSocket Qwen Audio 3.1 Message. Reviewed request and response fixtures against the official [native HTTP reference](https://help.aliyun.com/zh/model-studio/fun-asr-flash-recorded-speech-recognition-http-api), [Message client events](https://help.aliyun.com/zh/model-studio/qwen-asr-message-client-events), and [Message server events](https://help.aliyun.com/zh/model-studio/qwen-asr-message-server-events).
- `swift test --disable-sandbox`: 30 standalone tests passed, 2 existing localhost integration tests skipped. New coverage includes schema-v1 migration with stable UUID/credential association and encrypted round trip; unknown-model repair; HTTP/WS request envelopes; endpoint security; weighted vocabulary merging and limits; model capability restrictions; safe provider diagnostics; final-sentence replacement; and task-start/upload/final-wait cancellation, timeout, provider failures, and disconnects. WebSocket sessions use an injected in-memory fixture, not a real network or account.
- `python3 -m unittest discover -s server -v`: six setup errors because the execution sandbox still denies localhost `socket.bind` with `PermissionError`. No server code changed; these service tests and native network integration remain unverified here.
- Release build, icon validation, signature verification, and Info.plist validation passed. Relaunched the actual app: its saved Message profile loaded with the same workspace host, now using `wss` and `/api-ws/v1/inference`; its writing profile and saved-key masked indicator remained present.
- In an unsaved editor draft, switched between Message, Qwen3-ASR-Flash, and Qwen Audio 3.1 Flash. Confirmed matching endpoint paths and that context-only models hide weight controls. Added a custom hotword, pasted Chinese/English text with CRLF, confirmed a single visible line, undid the paste with Command-Z, and selected weight 50. Cancelled the draft; the active Message profile remained selected.
- No test configuration or credentials were saved, no microphone capture was started, and no real provider request was sent. Live microphone streaming is not included; all adapters process recorded audio after stop. Real-account recognition, latency, and vocabulary influence still need a user recording test.

## Single-line inputs — 2026-10-13

- Audited all nine single-line fields: profile name, endpoint, Model ID, API key, translation language, sync URL, sync token, sync passphrase, and history search. All now use the shared native single-line control; there are no remaining direct SwiftUI `TextField` or `SecureField` inputs.
- In the running packaged app, pasted synthetic values containing LF, CRLF, and Unicode line/paragraph separators across those fields. Accessibility values and visual inspection confirmed a single horizontal line, including masked secure fields. Model ID and translation-language paste could be undone; Option-Return did not insert a line in search. Chinese text paste was checked; interactive IME composition was not separately tested.
- Model tests used an unsaved new profile; all settings tests were cancelled or left without saving. No real keys, recordings, provider requests, or server requests were used for these checks.
- Regression tests verify that both ASR and writing request bodies contain a trimmed model ID, blank IDs fail before a request, and profile cleanup preserves multiline advanced JSON. Nine standalone Swift tests passed; the two HTTP integration tests remain skipped because the execution sandbox cannot bind a local server port.
- The final release bundle passed icon, signature, and Info.plist checks, then launched successfully. The app was left on Models with the user's saved profiles still present and no test profile saved.

## Editing shortcuts — 2026-10-13

- Reproduced the missing Edit menu in the running app: the launch delegate's manually assigned main menu was replaced by SwiftUI's scene menu. Editing commands now belong to the SwiftUI scene and dispatch to the key window's first responder.
- Rebuilt and relaunched `dist/VoiceDraft.app`; confirmed the Edit menu remains present with a model configuration sheet open.
- In an unsaved new profile, pasted synthetic text into Profile name, used Command-Z to restore the original name, and Command-Shift-Z to restore the pasted text.
- In Advanced request parameters, verified Command-A, paste, and Command-Z, observing the JSON return to `{}`. Cancelled the sheet without saving any test configuration. No model request or recording was made.
- Seven standalone Swift tests passed; two HTTP integration tests remained skipped. The release build, icon validation, signature verification, and Info.plist validation passed. The previously recorded sandbox restriction on the service tests is unchanged.

## Migration check — 2026-10-13

Environment: Apple Silicon macOS 26.5, Apple Swift 6.2.3, Xcode toolchain, Python 3.14.6.

- `swift test --disable-sandbox` with repository-local module caches compiled the app and passed seven standalone tests. The two HTTP integration tests were explicitly skipped because no test server was available.
- `python3 scripts/test-all.py` could not complete: all six service tests failed during setup because this execution sandbox denies localhost socket binding (`PermissionError: Operation not permitted`). Sandbox escalation was unavailable. The Python service and HTTP integration checks have not been revalidated on this Mac.
- The original release build compiled but stopped at `iconutil` with `Invalid Iconset`, despite correctly sized PNGs. The icon generator now writes the PNG-backed ICNS elements directly and validates all ten representations using the system ImageIO decoder. No additional dependency is required. The existing iconset-only invocation remains supported.
- `./scripts/build-app.sh` completed, including all ten icon representations, ad-hoc signing, `codesign --verify --deep --strict`, and `plutil -lint`.
- The packaged app launched into the native Studio screen. Real microphone capture, permission changes, Bailian requests, and cross-application insertion remain unverified; recording was not started.

The earlier full-suite results below describe the original development environment, not this migration check.

## Original checks — 2026-10-12

Environment: Apple Silicon macOS, Apple Swift 6.4, Xcode toolchain. Date: 2026-10-12.

## Automated checks

`python3 scripts/test-all.py`:

- Six Python service tests: authentication, health endpoint, body and revision validation, concurrent writes, stale revision rejection, persistence, and file permissions.
- Nine Swift tests: independent ASR/writing request construction, structured edit context, reserved parameter protection, response validation, secure URL rules, credential/profile validation, authenticated encryption round trip, randomized ciphertext, wrong passphrase and tamper rejection.
- The Swift tests include an actual HTTP round trip through the Python service with two separate client instances. One uploads an encrypted snapshot; the other downloads and decrypts the model profiles, test API key, and vocabulary. A stale upload is rejected.
- A local Qwen fixture verifies the audio request, returns a transcript, receives the subsequent writing request, and returns a result. Redirect and rate-limit responses verify failure handling and that no credentials appear in error messages. These are simulated provider responses, not real Bailian inference.

The integration runner creates a temporary database and access token, starts localhost listeners, then removes them. No real API key, selected user text, or microphone recording is used.

## Native application

- Release build packaged as `dist/VoiceDraft.app` with an Info.plist microphone usage description and local ad-hoc signature.
- `codesign --verify --deep --strict` and `plutil -lint` run against the bundle.
- All five native screens rendered through a running AppKit/SwiftUI application in an isolated preview mode without reading local user data or Keychain. Captures are under `dist/previews/`.

Reproduce native captures:

```sh
VOICEDRAFT_CAPTURE_PREVIEWS="$PWD/dist/previews" ./dist/VoiceDraft.app/Contents/MacOS/VoiceDraft
```

## Requires user-account / physical-device validation

These have not been established by the automated tests:

- Real Bailian ASR accuracy, hotword influence, latency, quotas, and regional account access.
- Real microphone permission/capture and recording cancellation, device changes, and interruptions.
- Accessibility selection and insertion in the user's actual apps, including slow clipboard consumers, rich text, and nonstandard editors.
- Keychain behavior across app rebuilds and formal signing. Ad-hoc rebuilds may require granting Accessibility again; distribution signing must be stabilized before release.
- Two physical Macs connected through a production HTTPS host. The protocol is tested with two clients on the same machine.
- Production Docker/Caddy deployment, public notarization, Intel hardware, Windows, and mobile clients.

## Manual acceptance flow

1. Enter real Bailian credentials in both profiles; test the writing connection, then record a short phrase in Studio.
2. Try Chinese/English mixed text, names from Vocabulary, filler words, a spoken correction, a list, and a translation. Compare the original transcript and output.
3. In TextEdit and the user's browser/editor, record with the global shortcut. Verify the original field receives text and the previous clipboard returns. Change focus mid-request and confirm VoiceDraft retains the result instead of inserting elsewhere.
4. Select editable text, trigger Edit selection, and dictate an instruction. Ask a question and verify its answer appears in VoiceDraft without replacing the selection.
5. Deny microphone/accessibility permission and verify useful recovery messages. Cancel during recording and processing; no later output should be inserted.
6. Start a sync server, upload from Mac A, download on Mac B, and verify models, API keys, vocabulary, and style. Try a wrong passphrase. Make offline edits on both Macs and confirm an explicit conflict without lost local changes.

## Saved API key presentation — 2026-10-13

- Four additional credential draft tests passed: saved-key presentation, replacement, clearing a replacement without removing the stored key, explicit removal/cancellation, and read-error propagation. Thirteen standalone Swift tests passed; the two localhost integration tests remained skipped.
- Opening a model editor now uses a Keychain metadata query and a fixed masked placeholder, without loading the secret into the editor.
- Rebuilt, signed, and launched the release bundle. The existing ASR profile visibly showed twelve masked dots and the saved-key label. Cancelled without saving, changing credentials, recording, or sending a model request.
