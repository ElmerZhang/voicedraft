# VoiceDraft

VoiceDraft is a personal experimental project, independent of company projects and knowledge bases.

A native macOS voice writing app with independently configurable Qwen speech and writing models, plus a self-hosted encrypted configuration vault. This is a runnable first release, not full Typeless feature parity.

## Run the Mac app

Open `dist/VoiceDraft.app` after building:

```sh
./scripts/build-app.sh
open dist/VoiceDraft.app
```

Requirements: macOS 13 or newer, Xcode/Swift for source builds. The included build is for the build machine's architecture (Apple Silicon). The preview is locally ad-hoc signed; public distribution and notarization are not included.

The build script packages the icon directly, checks all ten image representations with macOS ImageIO, and verifies the app signature and Info.plist before reporting success. It does not require `iconutil` conversion.

1. Open **Settings → Models**, edit the speech and writing profiles, and enter a Bailian API key in each. They may share a key or use separate keys.
2. Select a model first, then configure its endpoint and model parameters. Defaults remain `qwen3-asr-flash` for speech and `qwen-plus` for writing. The catalog supports Qwen3-ASR-Flash (HTTP context), Qwen-Audio-3.0/3.1-ASR-Flash (HTTP weighted hotwords), and Qwen-Audio-3.1-ASR-Flash-Message (WebSocket weighted hotwords). Other ASR IDs require an adapter before use.
3. Use your region/workspace domain and the selected model’s endpoint. **Use model endpoint** fixes the scheme and path while keeping your host. Message uses `wss://WORKSPACE_ID.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference`; it cannot use `/chat/completions`. Already-saved API keys appear as masked dots. Leaving the replacement blank keeps the stored key.
4. Use **Test connection** on the writing profile. This sends a small real request using your key. Test ASR by recording in the **Home → Try it here** workspace.
5. Allow Microphone when recording. Allow Accessibility from Home to insert into other applications.
6. Click a text field in another app and press **Control + Option + Space**, speak, then press the shortcut again.

| Shortcut | Behavior |
| --- | --- |
| Control + Option + Space | Start polished dictation / finish recording |
| Control + Option + T | Translate into your configured language |
| Control + Option + E | Speak an editing instruction for selected editable text |
| Control + Option + A | Ask a question, optionally using selected text; show result in the app |

The Home testing workspace also supports plain transcription and manually entered text, useful for testing writing prompts independently of audio. Recordings are limited to four minutes per take. `qwen-audio-3.1-asr-flash-message` streams audio while you speak and shows a live transcript above the compact recording controls. You can say a correction (for example, “把刚才的周二改成周四”) before finishing; Polish and Translate pass the complete transcript to the writing model with explicit self-correction instructions. Verbatim keeps the recognized words, including correction instructions. HTTP speech models still recognize after you finish recording. Choose **Input device** in Home or Settings: follow the system default or select a microphone. The recording capsule has Cancel, an input-level waveform, and Finish; hover for the actual microphone and elapsed time. Nothing is inserted until you finish. If there is no editable input focus, insertion is disabled, or the original focus changes, a persistent result card lets you copy the text without opening the main window. Device selection is local and does not change macOS Sound settings.

The floating recording panel does not take keyboard focus. If the original field or selection changes while the model is working, the result remains in VoiceDraft for manual copying. Accessibility support varies between applications; password fields are blocked. No automatic Enter/send keystroke is generated.

## Pages

- **Home**: enabled shortcuts as key caps, local usage counts, and the full recording/text-testing workspace. Transcribe, polish, translate, edit selection, and ask modes are preserved.
- **History**: records grouped by day, search, dictation/question filters, original transcript details, copy, deletion, and the local-history toggle.
- **Vocabulary**: searchable word grid, enabled/disabled filters, add/edit, bulk add, and per-word controls in the context menu. Changes save immediately. Model projection details remain available below the grid.
- **Settings** (sidebar or **Command-comma**): an overlay with shortcuts, recording, audio, language, general and update preferences, plus Personalization, Models, Sync, About, and Help tabs. Models and Sync are settings tabs, not pages. Save writing style and translation target in Personalization.

The interface follows the system light or dark appearance; the recording HUD is always dark. The shared visual language is defined in [docs/design.md](docs/design.md).

## Start configuration sync locally

```sh
./scripts/run-server.sh
```

The service listens on `http://127.0.0.1:8765`. Its randomly generated access token is saved at `.local/access-token`; copy it into the app's **Sync** page. Choose a separate, strong sync passphrase of at least 12 characters. Do not use your Bailian API key as the sync access token or passphrase.

- First Mac: save the connection, then **Sync now**.
- New device: use the same server URL, access token, and sync passphrase; save the connection, then **Download server copy**.
- Enable automatic sync to synchronize after saves and every 30 seconds while Studio or History is open. Editing model/vocabulary pages pauses background polling to protect unsaved form edits.
- Conflicting changes stop with an explicit message. Downloading a server copy requires confirmation and replaces local model settings and vocabulary. Reapply any local edits you want to keep afterward.

Localhost is only reachable from the same machine. For multiple physical devices, deploy the service on a shared HTTPS host using [the server guide](docs/server.md). Cross-platform clients are planned; the initial client is macOS.

## Included

- Multiple saved Qwen model profiles; speech and writing are selected independently.
- Model catalog, protocol-specific endpoints, separate API keys, read-only vocabulary adaptation previews, and advanced JSON parameters.
- Dictation cleanup, spoken self-corrections, structured formatting, translation, selected-text editing, and text-only question answering through Qwen.
- One app-wide vocabulary with enabled terms, strength, priority, language, aliases, preferred spelling, and IPA pronunciation. Adapters derive context or weighted hotwords and show omitted/downgraded data while retaining the full source. Manage it in **Vocabulary**, not individual profiles. Writing also receives spelling and alias guidance. Recognition is not guaranteed to use every supplied term.
- Encrypted sync of profiles, API keys, active selections, vocabulary, writing preferences, and translation target.
- Eight interface languages (简体中文、繁體中文, English, 日本語, 한국어, Deutsch, Français, Español), selected in **Settings → Language** or following the system. This choice is local and separate from the translation target.
- A menu bar entry, recording HUD with the bound input device, cancellation, clipboard preservation, searchable local history, and history deletion/opt-out.
- A Go sync server with SQLite persistence and a standalone binary; model calls go directly from Mac to the configured endpoint. No external Swift packages.

## Verification

```sh
./scripts/test-all.sh
```

Requires Go 1.25+, the Swift toolchain, and Python 3 for the localization checks only. This runs Go vet/build/race tests, then starts an isolated Go localhost service and tests encryption, two-device synchronization, stale revisions, concurrent updates, authentication, malformed input, request construction, response parsing, redirect rejection, streaming writing, and a simulated Qwen audio-to-writing pipeline. It does not access a microphone or a real model account. Server tests can run without network sockets using `cd server && go test -race ./...`; full Swift integration requires loopback listening permission.

To inspect the interface without credentials, microphone or provider calls, run the packaged binary with `VOICEDRAFT_CAPTURE_PREVIEWS=<dir>` (pages and settings tabs), `VOICEDRAFT_CAPTURE_ONBOARDING=<dir>` or `VOICEDRAFT_CAPTURE_HUD_PREVIEWS=<dir>`; add `VOICEDRAFT_PREVIEW_APPEARANCE=dark` for dark mode, or the arguments `-interfaceLanguage zh-Hans` (any supported code) for another interface language. Each mode writes PNGs and exits. Keep the capture process frontmost: when another app is active, native controls are captured in their inactive gray state.

See [architecture](docs/architecture.md), [deployment](docs/server.md), [feature parity and roadmap](docs/roadmap.md), and [validation](docs/validation.md).

Settings now use schema v3. v1/v2 profiles and vocabulary migrate in memory while keeping profile IDs and keys; the next save persists v3. Global lines and all profile terms are merged, with active-profile overrides winning conflicts. Remote vocabulary IDs are preserved as recovery references until their contents are imported. Upgrade other syncing clients before sharing the new settings.

## Adding a language

Add its case and matching rules in `AppLanguage`/`L10n`, provide complete `Localizable.strings`, `Desktop.strings`, and `InfoPlist.strings` catalogs, and include the locale in the packaging and localization checks. UI labels and app errors use `L` / `LocalizedMessage`; never localize protocol values or saved user content. Run the catalog checker, Swift tests, and inspect the packaged UI before shipping.

## Official API references

- [Qwen vocabulary formats and limits](https://help.aliyun.com/zh/model-studio/improve-asr-accuracy)
- [Qwen Audio HTTP API](https://help.aliyun.com/zh/model-studio/fun-asr-flash-recorded-speech-recognition-http-api)
- [Qwen ASR Message WebSocket API](https://help.aliyun.com/zh/model-studio/qwen-asr-message-websocket-api)
- [Qwen ASR Message client events](https://help.aliyun.com/zh/model-studio/qwen-asr-message-client-events)
- [Qwen ASR Message server events](https://help.aliyun.com/zh/model-studio/qwen-asr-message-server-events)
- [Qwen ASR HTTP API](https://www.alibabacloud.com/help/en/model-studio/qwen-asr-api-reference)
- [Bailian OpenAI-compatible text generation](https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope)
- [Typeless quickstart and current feature categories](https://www.typeless.com/help/quickstart)
- [Typeless Ask anything behavior](https://www.typeless.com/ask-anything)

Other model providers are intentionally out of scope for this release.

## Selected feature expansion (0.2)

VoiceDraft now includes hold/tap recording shortcuts, configurable keys, 10-minute capture, recording sounds/mute, Doubao/Whisper-compatible/Google speech, three writing protocols with streaming/model discovery, reusable per-app writing styles, local context, vocabulary files, automatic Codex/Claude context and project-name discovery with writing-model filtering, usage counts, retained audio and history retry/expiry, login launch and onboarding with optional domain vocabulary packs.

See [the selected feature checklist and provider setup](docs/selected-features.md) and [self-hosted signed update publishing](docs/updates.md). The new controls have English and Chinese copy; other interface languages currently fall back to English for these additions. This is a local implementation, not a deployed update service or a claim of real-account provider acceptance.
