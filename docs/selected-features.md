# Typeflux comparison: selected VoiceDraft additions

User scope confirmed 2026-10-13. B5 includes **Google Speech only**. F3 uses a **self-hosted HTTPS feed**; the user has no feed URL yet and requested configuration and publishing instructions. No cloud service deployment is included. Model requests go directly to user-configured providers; automated tests use synthetic fixtures.

The checklist below describes implementation coverage, not proof of microphone, Accessibility or vendor-account acceptance. See the validation section for that boundary.

| Selected | Delivered behavior | Main implementation |
| --- | --- | --- |
| A1 | Hold a recording shortcut; release after 600 ms to finish | `RecordingGesture`, `Shortcuts.swift`, `AppState.shortcutEvent` |
| A2 | Release within 600 ms to lock; press again to finish; release during startup is retained | Same gesture state machine |
| A3 | Record custom modifier/key combinations or Fn; enable/disable and restore defaults; reject conflicts | Settings → Shortcuts |
| A4 | Up to 10 minutes; Qwen HTTP split below 5 minutes, Google below 60 seconds | `SpeechClient`, `WaveAudio.chunks`, capture timers |
| A5 | Optional start/end sounds; end sound after capture closes | `RecordingEffects` |
| A6 | Optional output-device mute; restore that device's original state on completion/cancel/error/quit | `RecordingEffects` |
| B3 | Doubao binary WebSocket, API key or legacy App ID/access token, configurable resource ID, hotwords | `DoubaoSpeech`, `DoubaoWire` |
| B4 | Whisper-compatible multipart requests, custom URL/model, including OpenAI/Groq gateways | `WhisperRequests` |
| B5 | Google Speech v2 inline audio with local segmentation; OAuth token or service-account JSON in Keychain | `GoogleSpeech`, `GoogleCredential` |
| B6 | Chat Completions, Anthropic Messages and Responses writing protocols | `WritingClient` |
| B8 | Discover models from supported HTTP endpoints, preserve gateway prefix, paginate Anthropic | Profile editor → Fetch model list |
| B9 | Stream text into the editor/HUD; never insert unfinished/truncated output | `SSEFramer`, `WritingStream` |
| C1 | Named style library, custom prompts, three editable presets, default selection | Personalization → Writing styles |
| C2 | Bundle-ID application bindings; snapshot the style when capture starts | `SharedSettings.resolved` |
| C3 | Select text externally, invoke style shortcut, choose style in a nonactivating menu, replace through existing focus checks | `AppDelegate.showStyleMenu`, `applyStyleToSelection` |
| C4 | Opt-in last three outputs per app, 30-minute window, 2,000 characters each, memory only, clear button | `RecentInputContext` |
| C5 | UTF-8 text / VoiceDraft JSON import preview; JSON export preserves rich metadata; merge without overwriting existing terms | `VocabularyFile`, Vocabulary controls |
| C6 | One-click discovery of local Codex / Claude memories, recent user messages, referenced project instructions and directory/manifest project names; writing-model filtering and source-labelled candidate review before import | `AgentContextScanner`, `ProjectVocabulary`, `ContextVocabulary`, `ContextVocabularyFilter` |
| C7 | Per-take term usage counts, frequency ordering in Vocabulary and provider projections | `AppVocabulary.recordUsage` |
| D1 | Opt-in private local WAV files; playback/stop in history; no configuration sync | `LocalStore`, `LiveAudioFeed` |
| D2 | Rerun retained audio or rewrite the original transcript with current models/style; create a new history item without auto-pasting | `AppState.reprocess` |
| D4 | Forever, 1/7/30/90 days; expiry removes text and associated audio; confirmation before enabling deletion | Recording preferences / `pruneHistory` |
| F1 | macOS login item via SMAppService; explicit toggle | Settings → Launch at login |
| F2 | Reopenable field/starter-vocabulary/model/permission/shortcut guide; six optional domains with per-term review and deduplication; explicit permission buttons | `OnboardingView`, `DomainVocabularySelection` |
| F3 | Optional daily HTTPS checks, Ed25519 manifest verification, SHA-256 package checks, bounded ZIP validation, explicit install/restart with rollback | `UpdateController`, [updates.md](updates.md) |

## 2026-10-15 · On-screen context (屏幕上下文)

User-authorized expansion. All decisions follow the reviewed implementation spec: Message ASR screen terms use the leftover of `input.context`, global vocabulary disablement also disables screen recognition hints, the HUD counts offered terms, the OCR threshold is 120 content characters, built-in exclusions are not removable and there is no per-domain exclusion, extraction works with the master switch off, Ask receives no screen context, the Polish language-policy wording changes only when context is present, and only verified password-manager bundle IDs ship.

| Selected | Delivered behavior | Main implementation |
| --- | --- | --- |
| G1 | Opt-in on-screen context from the front window's Accessibility text; focus-first, bounded walk; no new permission | `ScreenTextWalker`, `ScreenContextAXReader` |
| G2 | Optional window-only on-device OCR when an app exposes too little text; Screen Recording required; never saved | `WindowTextRecognizer` |
| G3 | Lowest-priority temporary ASR terms (≤ 300 / 6,000 B) for every adapter; never stored, counted or learned | `VocabularyProjection.make(screenTerms:)`, `ScreenContextPolicy` |
| G4 | Bounded excerpt (≤ 1,500 characters) and ≤ 40 terms for Polish/Translate (terms only for Edit) as untrusted reference data | `QwenRequests.writing(screenContext:)` |
| G5 | Extract words from the current screen into the Vocabulary review sheet (menu bar or Vocabulary) | `ScreenTermExtractor`, `ContextVocabularyFilter` |
| G6 | Per-app exclusions with built-in password managers; HUD indicator; Screen Recording permission rows | Settings → On-screen context, `ScreenContextCoordinator` |

**Defaults.** The master switch "Use on-screen text as context" is off. Under it, Recognition hints and Writing reference are on, and OCR is off. User exclusions start empty; 1Password 8 and 7, Bitwarden, Keychain Access, Passwords and VoiceDraft itself are always skipped. All settings live in the device file and never sync.

**Privacy.** Screen text, excerpts, terms and OCR images live in memory only. Per-take data is dropped when the take ends. OCR snapshots are cached for at most 60 seconds and four windows, and the cache clears on sleep, lock, quit, app exit, and when the master switch, OCR or exclusions change. History stores only the output, and nothing enters shared settings or sync. Secure fields are never read or descended. Excluded apps are checked before any AX or capture call. Credential and URL lines are dropped, long digit runs and secret-like tokens are masked, and bidi and zero-width controls are stripped. The writing model receives the excerpt as a JSON field named `on_screen_context_reference_only` with an untrusted-data rule; model compliance is not guaranteed. Speech models receive only term-shaped tokens. A dictation only preflights Screen Recording and never triggers a permission prompt. Visible text can include other people's messages; the settings footnote says so and per-app exclusion is available. Extraction sends only candidate words to the writing model, never the screen text. No log, status or error contains screen text.

## Data and compatibility

Shared settings migrate v1–v4 to v5 without changing existing profile IDs, credentials, vocabulary or general style. New style and application rules join the existing encrypted vault. Device-only settings, audio and context stay local. Older VoiceDraft versions cannot read v5; update other clients before downloading this vault.

Audio retention, recent context, system mute, login items and automatic update checks start disabled. Existing history is retained indefinitely until a retention period is selected. Recording sounds default on. The existing Control-Option shortcuts remain the default; Fn is an explicit alternative requiring Accessibility. Historical entries without audio remain readable and support text reprocessing.

New UI copy supports English, Simplified Chinese and Traditional Chinese; the other existing interface languages use English for the new controls. Existing translated screens retain their localization coverage.

C6 automatically discovers context when the user clicks Extract; it does not open a file picker or run continuously. It reads known local Codex/Claude context paths with bounded file/byte budgets, filters conversation records to user messages, and includes project names from referenced directories and allowlisted package declarations. It passes at most 200 new candidate words to the selected writing model for classification. The review shows at most 40 useful terms with source labels, marking project names explicitly. Existing terms, aliases and preferred spellings are excluded. Only candidate IDs, words and term/project labels are sent to the model; raw conversations, manifest contents and local paths stay local. Only checked terms are merged after confirmation. Failed filtering offers retry or explicit unfiltered review. Candidate extraction favors product/code names, acronyms, underscore identifiers and quoted terminology; ordinary vocabulary file import/export remains available.

## Provider setup

- **Doubao:** `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`, model `bigmodel`. New-console API key in credential field. Legacy access token there plus `app_id` in advanced JSON. Optional `resource_id` defaults to `volc.bigasr.sauc.duration`; choose the resource actually enabled for your account.
- **Whisper:** complete transcription URL, e.g. `https://api.openai.com/v1/audio/transcriptions` or `https://api.groq.com/openai/v1/audio/transcriptions`; enter the model your provider supports. Advanced options: `language`, `temperature`, `prompt`.
- **Google:** replace `PROJECT` and choose the correct location in `https://speech.googleapis.com/v2/projects/PROJECT/locations/global/recognizers/_:recognize`. Enable Speech-to-Text v2 and grant the service account the necessary project role. Import its JSON key or enter a valid OAuth access token. Configure `languageCodes` and model/location together; default model is `chirp_3`, default language is `cmn-Hans-CN`. Raw access tokens must be refreshed manually; service-account keys obtain an access token per take. The token endpoint is fixed to Google's endpoint, never read from imported JSON.
- **Writing:** choose the wire protocol before entering the full endpoint. Discover models when the service exposes `/models`, or type a model ID. Advanced parameters remain provider-specific. Responses sets `store=false`; the app does not request tools or execute model actions.
- Inference and discovery reject HTTP redirects to prevent forwarding credentials to another origin. All production endpoints require HTTPS/WSS; loopback HTTP/WS remains available for development. Model discovery is unavailable for Doubao/Google Speech protocols, which do not expose the compatible model-list API.

## Protocol references checked

Implementation follows provider protocols independently; no Typeflux code was copied.

- [OpenAI speech-to-text](https://developers.openai.com/api/docs/guides/speech-to-text)
- [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses)
- [Anthropic streaming Messages](https://platform.claude.com/docs/en/build-with-claude/streaming)
- [Doubao streaming recognition](https://docs.volcengine.com/docs/6561/1354869?lang=zh)
- [Google synchronous recognition and limits](https://docs.cloud.google.com/speech-to-text/docs/sync-recognize)
- [Google service-account OAuth](https://developers.google.com/identity/protocols/oauth2/service-account)
- [Qwen non-realtime limits](https://help.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide)

## Acceptance still requiring real environments

Use a real Mac to check held/tapped Fn and custom shortcuts, microphone permission/start latency, 10-minute capture, output mute/restoration on built-in and external devices, app-specific routing, selected-text replacement/focus races, playback and login launch. None of the automated tests sends real audio, selected text, credentials or agent histories.

Vendor-account acceptance remains necessary for Doubao partial/final events, Google key/IAM/location/language combinations, Whisper gateways and each writing service's model-specific options. A generated signed release can be tested locally; production HTTPS download and app replacement require an actual hosting URL and a packaged installation. No production release is published by this change.
