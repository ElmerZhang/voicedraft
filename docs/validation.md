# Validation record

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
