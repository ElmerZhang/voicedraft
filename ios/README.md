# VoiceDraft iOS (skeleton)

Hand-authored Xcode project for a future VoiceDraft iOS client. No third-party dependencies.

- `VoiceDraft/`: SwiftUI app (`com.voicedraft.ios`), iOS 17.0+, iPhone only.
- `VoiceDraftKeyboard/`: custom keyboard extension (`com.voicedraft.ios.keyboard`), embedded in the app.
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
Recording is a placeholder: the record button only reflects press state.
