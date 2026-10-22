# VoiceDraft iOS

Hand-authored Xcode project for the VoiceDraft iOS client. No third-party dependencies.

- `VoiceDraft/`: SwiftUI app (`com.voicedraft.ios`), iOS 17.0+, iPhone only.
- `VoiceDraftKeyboard/`: custom keyboard extension (`com.voicedraft.ios.keyboard`), embedded in the app.
- `VoiceDraftiOSTests/`: XCTest unit tests hosted by the app.
- `Shared/`: code compiled into both targets. `SharedResultStore` passes the latest result through
  `latest-result.json` in the `group.com.voicedraft` app-group container.

## Keyboard

The keyboard extension types basic Latin text without Full Access. Voice and "Insert last" need Full Access,
because only that unlocks the app-group container. The design lives in [`docs/ios.md`](../docs/ios.md).

| File | Role |
| --- | --- |
| `Shared/AppGroup.swift` | `SharedResult` (`id`, `text`, `mode`, `createdAt`) in `latest-result.json`. Files without `id` or `mode` still decode. |
| `Shared/KeyboardBridge.swift` | Darwin notification names (`com.voicedraft.ios.take.start`, `.take.stop`, `.result.updated`, `.status.updated`), post and observe helpers, and `AppStatusStore` for `app-status.json`. |
| `VoiceDraftKeyboard/KeyboardViewController.swift` | Top bar with status, "Insert last" and the mic button; the voice take state machine. |
| `VoiceDraftKeyboard/KeyboardKeysView.swift` | QWERTY and digits/punctuation pages, shift with caps lock, delete with repeat, globe, space, return. |

The app writes `app-status.json` as `{ state: idle|listening|recording|processing, expiresAt, updatedAt }` and
refreshes `expiresAt` while alive. The keyboard treats the app as available only when `state` is not `idle` and
`expiresAt` is in the future. Otherwise the mic shows an "Open VoiceDraft" hint and posts nothing.

A take: the mic posts `take.start`, a second tap posts `take.stop`. The keyboard inserts the result when
`result.updated` fires or when its 0.5 s poll finds a new `latest-result.json`, because Darwin notifications can be
coalesced. It gives up after 60 s without progress.

**No networking in the extension.** The keyboard target must not link `VoiceDraftCore` or use `URLSession`,
`Network` or any other request API. Check with:

```sh
grep -rnE "URLSession|import Network|VoiceDraftCore" ios/VoiceDraftKeyboard ios/Shared
```

Build from the repository root:

```sh
xcodebuild -project ios/VoiceDraft.xcodeproj -scheme VoiceDraft \
  -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
```

No `DEVELOPMENT_TEAM` is set. Pick a team in Xcode to run on a device; the app group must be registered for that team.

The app target links the `VoiceDraftCore` library product from the Swift package at the repository root, through a
local package reference (`..`). Its resources ship as `VoiceDraft_VoiceDraftCore.bundle` in the app bundle. The
keyboard target does not link it.

## Container app

SwiftUI, iOS 17. It mirrors the Mac `AppState` orchestration on top of `VoiceDraftCore`. The design and trust
boundaries live in [`docs/ios.md`](../docs/ios.md).

| Folder | Files | Role |
| --- | --- | --- |
| `VoiceDraft/` | `VoiceDraftApp.swift` | Entry point. Points `L10n.defaults` at the app-group suite so the app and keyboard share the language. Hosted tests get an in-memory `AppModel.preview()`. |
| `Model/` | `AppModel.swift`, `AppModel+Sync.swift` | `@MainActor` state: settings, history, takes, listening session, keyboard bridge, sync. |
| | `TakeMachine.swift` | Pure take state machine (`idle`, `recording`, `processing`) and `AppStatusPolicy` for `app-status.json`. |
| | `IOSDeviceSettings.swift` | Device-local options: sync URL and revision, mode, history switch, listening timeout, onboarding. |
| | `AppText.swift` | String lookup: app tables, then Core `L10n`, then the English key. `{0}` placeholders. |
| `Storage/` | `IOSLocalStore.swift` | JSON in `Application Support/VoiceDraft`, complete file protection: `settings.json`, `device.json`, `history.json` (newest 500), `settings-before-sync.json`. |
| | `IOSKeychainStore.swift` | Service `com.voicedraft.ios.credentials`, `WhenUnlockedThisDeviceOnly`. Accounts: profile UUID, `sync-token`, `sync-passphrase`. |
| | `IOSUsageLog.swift` | `ModelUsageRecord` lines in `Usage/usage-YYYY-MM.jsonl`, like the Mac. |
| `Audio/` | `IOSAudioCapture.swift` | `AVAudioEngine` tap, `.record` session with Bluetooth, `AVAudioConverter` to 16 kHz mono PCM16. |
| | `PCMRouter.swift` | Discards audio outside a take; during a take buffers PCM for HTTP adapters and feeds `LiveAudioFeed` for WebSocket adapters. 10-minute cap, like the Mac. |
| `Pipeline/` | `TakeCoordinator.swift` | Validates the profiles and keys, runs `SpeechClient` and `WritingClient` with `QwenRequests.writing`, applies the selected style, records usage. |
| `Views/` | `RootView`, `HomeView`, `HistoryView`, `SettingsView`, `OnboardingView` | Tabs Dictate, History, Settings; first-launch onboarding. |

`SharedSettings` is stored and synced unchanged, vocabulary included. Sync uses `SyncClient` and `SyncCrypto` with the
Mac's revision rules. Download replaces settings and keys. Upload refuses when the server moved on with different
content and asks the user to download first. The server's 409 shows Core's conflict message.

### Takes

Hold the record button to record and release to stop. A short tap locks recording and a second tap stops it, using
Core's `RecordingGesture`. Modes are Polish, Translate and Ask. Each finished take is added to history and written to
`latest-result.json`, followed by a `result.updated` post. Every take or listening change rewrites `app-status.json`
and posts `status.updated`.

### Listening session

The Listening switch on the Dictate tab keeps the audio session and engine running under the `audio` background mode.
It stops after an idle timeout, 10 minutes by default and adjustable in Settings, or when the user turns it off. The
microphone indicator stays on while listening. Audio outside a take is discarded. While listening, `app-status.json`
carries a 15-minute lease that the app refreshes every minute. Without a listening session the status is already
expired, so the keyboard shows "Open VoiceDraft".

The app ignores keyboard `take.start` unless a listening session is active. A keyboard take always ends with a result
file. On failure, including a missing key or no speech, the text is empty and the keyboard inserts nothing.

## Tests

```sh
xcodebuild -project ios/VoiceDraft.xcodeproj -scheme VoiceDraft \
  -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
```

The tests cover status availability, the shared result file, the take state machine, `AppModel` takes driven with
silent audio and in-memory credentials, and `IOSLocalStore` round trips. No test opens the microphone, the Keychain
or the network.
