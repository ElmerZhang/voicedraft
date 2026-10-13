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

1. Open **Models**, edit the speech and writing profiles, and enter a Bailian API key in each. They may share a key or use separate keys.
2. Select a model first, then configure its endpoint and vocabulary options. Defaults remain `qwen3-asr-flash` for speech and `qwen-plus` for writing. The catalog supports Qwen3-ASR-Flash (HTTP context), Qwen-Audio-3.0/3.1-ASR-Flash (HTTP weighted hotwords), and Qwen-Audio-3.1-ASR-Flash-Message (WebSocket weighted hotwords). Other ASR IDs require an adapter before use.
3. Use your region/workspace domain and the selected model’s endpoint. **Use model endpoint** fixes the scheme and path while keeping your host. Message uses `wss://WORKSPACE_ID.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference`; it cannot use `/chat/completions`. Already-saved API keys appear as masked dots. Leaving the replacement blank keeps the stored key.
4. Use **Test connection** on the writing profile. This sends a small real request using your key. Test ASR by recording in Studio.
5. Allow Microphone when recording. Allow Accessibility from Studio to insert into other applications.
6. Click a text field in another app and press **Control + Option + Space**, speak, then press the shortcut again.

| Shortcut | Behavior |
| --- | --- |
| Control + Option + Space | Start polished dictation / finish recording |
| Control + Option + T | Translate into your configured language |
| Control + Option + E | Speak an editing instruction for selected editable text |
| Control + Option + A | Ask a question, optionally using selected text; show result in the app |

Studio also supports plain transcription and manually entered text, useful for testing writing prompts independently of audio. Recordings are limited to four minutes per take. This version transcribes after recording stops. Select the input microphone in macOS Sound settings.

The floating recording panel does not take keyboard focus. If the original field or selection changes while the model is working, the result remains in VoiceDraft for manual copying. Accessibility support varies between applications; password fields are blocked. No automatic Enter/send keystroke is generated.

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
- Model catalog, protocol-specific endpoints, separate API keys, capability-aware vocabulary controls, and advanced JSON parameters.
- Dictation cleanup, spoken self-corrections, structured formatting, translation, selected-text editing, and text-only question answering through Qwen.
- Personal vocabulary as recognition context or weighted hotwords, depending on the model, plus writing style guidance. Recognition is not guaranteed to use every supplied term.
- Encrypted sync of profiles, API keys, active selections, vocabulary, writing preferences, and translation target.
- A menu bar entry, recording HUD, cancellation, clipboard preservation, searchable local history, and history deletion/opt-out.
- No external Swift packages or Python packages; model calls go directly from Mac to the configured endpoint.

## Verification

```sh
python3 scripts/test-all.py
```

This starts an isolated localhost service and tests encryption, two-device synchronization, stale revisions, concurrent updates, authentication, malformed input, request construction, response parsing, redirect rejection, and a simulated Qwen audio-to-writing pipeline. It does not access a microphone or a real model account.

See [architecture](docs/architecture.md), [deployment](docs/server.md), [feature parity and roadmap](docs/roadmap.md), and [validation](docs/validation.md).

Settings now use schema v2. Existing profiles migrate in memory while keeping their IDs and keys; the next save persists v2. Upgrade other syncing clients before sharing the new settings.

## Official API references

- [Qwen Audio HTTP API](https://help.aliyun.com/zh/model-studio/fun-asr-flash-recorded-speech-recognition-http-api)
- [Qwen ASR Message WebSocket API](https://help.aliyun.com/zh/model-studio/qwen-asr-message-websocket-api)
- [Qwen ASR Message client events](https://help.aliyun.com/zh/model-studio/qwen-asr-message-client-events)
- [Qwen ASR Message server events](https://help.aliyun.com/zh/model-studio/qwen-asr-message-server-events)
- [Qwen ASR HTTP API](https://www.alibabacloud.com/help/en/model-studio/qwen-asr-api-reference)
- [Bailian OpenAI-compatible text generation](https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope)
- [Typeless quickstart and current feature categories](https://www.typeless.com/help/quickstart)
- [Typeless Ask anything behavior](https://www.typeless.com/ask-anything)

Other model providers are intentionally out of scope for this release.
