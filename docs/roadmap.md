# Feature parity and roadmap

Baseline reviewed against the public [Typeless quickstart](https://www.typeless.com/help/quickstart), [Translate guide](https://www.typeless.com/help/quickstart/translate), and [Ask anything](https://www.typeless.com/ask-anything) on 2026-10-12. This is a public-behavior comparison, not a claim to reproduce proprietary internals or a guarantee that every feature has been discovered.

| Capability | First release | Remaining work |
| --- | --- | --- |
| Global voice input on macOS | Implemented with shortcuts and floating recorder | Broad compatibility QA; configurable shortcuts and hold-to-talk |
| ASR | Catalog: Qwen3-ASR HTTP, Qwen Audio 3.0/3.1 HTTP, Qwen Audio 3.1 Message WebSocket | Real-account accuracy/latency evaluation; other Qwen protocol families |
| Cleanup, filler/repetition removal, self-corrections | Qwen writing prompts | Regression corpus for Chinese, mixed language, numbers, names, ambiguity |
| Structured paragraphs and lists | Qwen writing prompts | Per-editor formatting and list compatibility |
| Translation | Configurable target language | Favorite targets and fast switching |
| Voice editing of selected text | Accessibility selection plus Qwen rewrite | Rich text preservation, undo integration, broader editor coverage |
| Ask anything | Text-only answer with optional selected text | Search integrations and explicit action execution |
| Personal dictionary | One rich app vocabulary with adapter projections and migration | Automatic term suggestions, file import/export, additional provider adapters |
| Personal style | User-edited global style prompt | Learning from corrections with explicit controls |
| Per-application tone | App name available as context | Editable application-specific rules and routing |
| Multilingual speech | Delegated to the chosen Qwen ASR model | Measured language coverage and language controls; no promise of Typeless's advertised count |
| History | Local search, copy, delete, opt-out; maximum 500 entries | Export, retention controls, optional encrypted history sync |
| Model configuration | Model-first Qwen ASR/LLM profiles, adapter-specific options, saved-key indicators, schema v1/v2 migration | Other vendors only after individual adapter work |
| Cross-device model and hotword sync | Implemented, end-to-end encrypted including API keys | Field-level conflict resolution, device management, key rotation |
| Sync service | Self-hosted single vault, SQLite, token, Docker configuration | Production hosting, multi-user accounts, organizations, audit and recovery workflows |
| Live partial transcription | Not included; recognize after stop | Streaming ASR, endpoint detection/VAD, network reconnection |
| Long dictation | Four-minute takes | Chunking, long-session recovery, audio interruption handling |
| Microphone controls | App input picker, per-take device binding and HUD device name | Real microphone/device-disconnect validation |
| Offline mode | Settings/history work offline | Local ASR/LLM adapters and queue/retry options |
| macOS distribution | Locally signed Apple Silicon app | Developer ID signing, notarization, updater, Intel builds, login item |
| Windows, iOS, Android | No clients yet | Platform-specific capture/input, shared sync protocol implementations |
| Product polish | Eight interface languages, model editor, sync setup, recording state, application icon | Native-language copy review, onboarding, accessibility review |

## Suggested delivery sequence

1. Validate on a real Bailian account and a fixed Chinese/mixed-language corpus; test recording, permissions, cancellation, and insertion in the user's actual editors.
2. Deploy the existing vault behind HTTPS; verify two real Macs including offline edits and conflict recovery.
3. Add live microphone streaming Qwen ASR, shortcut customization, automatic endpoint detection, and application style rules.
4. Add individual adapters for Doubao and OpenAI, followed by other providers. Add a schema migration and protocol fixtures with each adapter.
5. Implement Windows and mobile clients, test the encryption contract across languages, and add account/device management if the service becomes multi-user.

Full feature parity remains a product program beyond this preview. Billing, subscription plans, vendor branding, marketing claims, and proprietary training behavior are not copied.
