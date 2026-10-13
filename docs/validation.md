# Validation record

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
