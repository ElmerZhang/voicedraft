# Feature parity and roadmap

The 2026-10-13 user-selected Typeflux additions are tracked in [selected-features.md](selected-features.md), including delivered behavior and real-environment acceptance boundaries. The original first-release comparison below is retained as historical scope, not the current implementation status.

Baseline reviewed against the public [Typeless quickstart](https://www.typeless.com/help/quickstart), [Translate guide](https://www.typeless.com/help/quickstart/translate), and [Ask anything](https://www.typeless.com/ask-anything) on 2026-10-12. This is a public-behavior comparison, not a claim to reproduce proprietary internals or a guarantee that every feature has been discovered.

| Capability | First release | Remaining work |
| --- | --- | --- |
| Global voice input on macOS | Shortcuts, compact recording capsule, and copy card when the focus is clearly not an input (paste unless proven otherwise, with a result card after unconfirmable pastes) | Broad compatibility QA; configurable shortcuts and hold-to-talk |
| ASR | Catalog: Qwen3-ASR HTTP, Qwen Audio 3.0/3.1 HTTP, Qwen Audio 3.1 Message WebSocket | Real-account accuracy/latency evaluation; other Qwen protocol families |
| Cleanup, filler/repetition removal, self-corrections | Qwen writing prompts | Regression corpus for Chinese, mixed language, numbers, names, ambiguity |
| Structured paragraphs and lists | Qwen writing prompts | Per-editor formatting and list compatibility |
| Translation | Configurable target language | Favorite targets and fast switching |
| Voice editing of selected text | Accessibility selection plus Qwen rewrite | Rich text preservation, undo integration, broader editor coverage |
| Ask anything | Text-only answer with optional selected text | Search integrations and explicit action execution |
| Personal vocabulary | One rich vocabulary, automatic correction learning and repeated-dictation discovery, origin filters, opt-outs and deletion suppression | Real-model learning precision, additional editor compatibility, file import/export, additional provider adapters |
| Personal style | User-edited global style prompt | Learning from corrections with explicit controls |
| Per-application tone | App name available as context | Editable application-specific rules and routing |
| Multilingual speech | Delegated to the chosen Qwen ASR model | Measured language coverage and language controls; no promise of Typeless's advertised count |
| History | Local search, copy, delete, opt-out; maximum 500 entries | Export, retention controls, optional encrypted history sync |
| Model configuration | Model-first Qwen ASR/LLM profiles, adapter-specific options, saved-key indicators, schema v1/v2 migration | Other vendors only after individual adapter work |
| Cross-device model and hotword sync | Implemented, end-to-end encrypted including API keys | Field-level conflict resolution, device management, key rotation |
| Sync service | Go binary, self-hosted single vault, SQLite, token, Docker configuration; compatible with existing Python-era vaults | Production hosting, multi-user accounts, organizations, audit and recovery workflows |
| Live partial transcription | Qwen Audio 3.1 Message PCM streaming with revisable live text and spoken correction prompts | Real-device/account acceptance; additional streaming adapters, endpoint detection/VAD, network reconnection |
| Long dictation | Ten-minute takes with automatic finish; HTTP speech uploads chunked at the provider's five-minute limit, Google below 60 s | Long-session recovery, audio interruption handling |
| Long-form drafting | Not yet. Decided 2026-11-10: paragraph-at-a-time dictation into a VoiceDraft draft window (see Direction (2026-11-10)) | Draft window with per-paragraph polish, undo and export; then voice edits over the draft, an iOS draft screen, and a continuous mode with pause segmentation |
| Microphone controls | App input picker, per-take device binding and device name in the HUD tooltip | Real microphone/device-disconnect validation |
| Offline mode | Settings/history work offline | Local ASR/LLM adapters and queue/retry options |
| macOS distribution | Locally signed Apple Silicon app | Developer ID signing, notarization, updater, Intel builds, login item |
| Windows, iOS, Android | iOS client: container app plus voice-only keyboard sharing `VoiceDraftCore` (see [ios.md](ios.md)); no Windows or Android client | Windows and Android capture/input, shared sync protocol implementations |
| Product polish | Eight interface languages, model editor, sync setup, recording state, application icon | Native-language copy review, onboarding, accessibility review |

## Suggested delivery sequence

1. Validate on a real Bailian account and a fixed Chinese/mixed-language corpus; test recording, permissions, cancellation, and insertion in the user's actual editors.
2. Deploy the existing vault behind HTTPS; verify two real Macs including offline edits and conflict recovery.
3. Extend streaming ASR support, shortcut customization, automatic endpoint detection, and application style rules.
4. Add individual adapters for Doubao and OpenAI, followed by other providers. Add a schema migration and protocol fixtures with each adapter.
5. Implement Windows and mobile clients, test the encryption contract across languages, and add account/device management if the service becomes multi-user.

Full feature parity remains a product program beyond this preview. Billing, subscription plans, vendor branding, marketing claims, and proprietary training behavior are not copied (historical note; billing scope is superseded by Direction (2026-10-22) below, vendor branding and proprietary behavior remain out of scope).

## Direction (2026-10-22)

- The whole project is open source under AGPL-3.0, including the planned iOS client.
- The Mac and iOS apps are free.
- The only paid service is an optional hosted zero-knowledge sync. Self-hosting remains free and functionally identical.
- History and audio never sync.
- Billing and subscription work is now in scope for the hosted service only.
- Trademark registration is deferred.
- App Store distribution of the Mac app is not planned. The Mac app ships directly and notarized.
- The iOS keyboard is voice only (hold to talk, insert last result, globe, space, delete, return); typing is left to other keyboards ([ios.md](ios.md#app-store-constraints-that-shape-the-design)).
- iOS keyboard dictation opens the VoiceDraft app to record when it is not on standby, then keeps a keyboard standby window (default 15 minutes) so later takes need no app switch ([ios.md](ios.md#process-model)).

## Direction (2026-11-10)

Long-form writing by voice is a drafting surface, not a longer take. The maintainer chose, for the first version, dictation one paragraph per take into a draft window owned by VoiceDraft: press the dictation shortcut with the draft window focused, speak one paragraph, release; the polished paragraph is appended to the draft. Each paragraph stays inside the ten-minute take and the writing model's output limits, and the draft can be edited by keyboard, undone paragraph by paragraph, copied or inserted into another app. A continuous mode (locked recording with pause-based segmentation) and an iOS draft screen come later. Dictating ten minutes in one take into another app's document is not the goal.
