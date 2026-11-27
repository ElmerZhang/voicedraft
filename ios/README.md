# VoiceDraft iOS

Hand-authored Xcode project for the VoiceDraft iOS client. No third-party dependencies.

- `VoiceDraft/`: SwiftUI app (`com.voicedraft.ios`), iOS 17.0+, iPhone only.
- `VoiceDraftKeyboard/`: custom keyboard extension (`com.voicedraft.ios.keyboard`), embedded in the app.
- `VoiceDraftiOSTests/`: XCTest unit tests hosted by the app.
- `Shared/`: code compiled into both targets. `SharedResultStore` passes the latest result through
  `latest-result.json` in the `group.com.voicedraft` app-group container. `KeyboardPresenceStore` holds
  `keyboard-presence.json`, the keyboard's "I am enabled" marker.

The app icon reuses the Mac's green waveform artwork. `VoiceDraft/Assets.xcassets/AppIcon.appiconset`
contains an opaque 1024 × 1024 square; Xcode generates device sizes and iOS applies the corner mask.
Both Debug and Release select `AppIcon`. To regenerate it from the shared drawing code, run from the repo root:

```sh
swift scripts/make-icon.swift --ios ios/VoiceDraft/Assets.xcassets/AppIcon.appiconset
```

## Keyboard

The keyboard extension is voice only. A labeled delete key sits in the upper-right corner, beside a small VoiceDraft
wordmark. A wide blue recording surface combines the microphone and instructions; the whole surface accepts talk
gestures. The bottom row contains insert-last-result, space and a tinted return/search/send key. Delete is always
above the recording surface and return below it, with 160 pt between their edges in portrait and 108 pt in compact
mode. Recording turns the surface red with a microphone/stop icon and a live PCM amplitude waveform; processing shows a progress indicator. There is no
language or input-mode segment. Portrait content is 276 points high when iOS supplies the globe below the extension,
or 320 with a custom globe; compact landscape content is 216 points. It has no character keys; users type with any
other keyboard and switch with the system or custom globe.
The controller declares `hasDictationKey = true` so iOS hides its redundant bottom-right microphone, while the
system globe remains. Live volume is read from `recording-meter.json` at 10 Hz only while recording; samples carry a
take ID and PCM timestamp, expire after 400 ms, and are removed on stop/cancel/failure. The waveform is driven by
measured audio: one tapered white curve rises and falls as a whole, with smooth 100 ms transitions. Silence is flat;
missing input resets immediately, and Reduce Motion disables phase movement and transitions. The shape visualizes
volume rather than raw PCM; there is no autonomous animation or audio data in the keyboard.
Voice and "Insert last result" need Full Access, because
only that unlocks the app-group container. Without it they stay visible but disabled, and the status line says why;
the basic editing keys always work. Talk gestures are unchanged: tap locks recording, the next tap finishes, and a
long press records until release. The design lives in [`docs/ios.md`](../docs/ios.md).

| File | Role |
| --- | --- |
| `Shared/AppGroup.swift` | `SharedResult` (`id`, `text`, `mode`, `createdAt`) in `latest-result.json`. Files without `id` or `mode` still decode. `KeyboardPresence` (`seenAt`, `fullAccess`, `version`) in `keyboard-presence.json`. `PendingTake` and `PendingTakeStore` (`pending-take.json`), the pure `KeyboardResumeDecision`, and `KeyboardRecordLink` (`voicedraft://record?take=<id>&source=keyboard`). |
| `Shared/KeyboardBridge.swift` | Darwin notification names (`com.voicedraft.ios.take.start`, `.take.stop`, `.result.updated`, `.status.updated`), post and observe helpers, and `AppStatusStore` for `app-status.json`. |
| `Shared/KeyboardOpenAttempt.swift` | `KeyboardOpenStrategy`, the pure `KeyboardOpenSequence` (first success wins; upper-case scheme retry only after a lower-case failure; the status-line summary) and `KeyboardOpenAttemptStore` (`open-attempts.json`, last 20). |
| `VoiceDraftKeyboard/ContainingAppOpener.swift` | Opens the containing app: `NSExtensionContext.open`, then the responder chain's `UIApplication`, then `UIApplication` by class name. |
| `VoiceDraftKeyboard/KeyboardViewController.swift` | The voice take state machine (hold to talk, a short tap locks recording), status text, the basic keys' actions, `L10n`. |
| `VoiceDraftKeyboard/VoicePageView.swift` | The single page: status line, talk button, "Insert last result", bottom row. |
| `VoiceDraft/Views/KeyboardTakeView.swift` | Full-screen view for a take the keyboard opened the app for: elapsed time, level, Finish, Cancel, then the delivered result with Copy. |
| `VoiceDraft/Views/KeyboardSetupGuide.swift` | `KeyboardSetupStatus` (pure function of the marker), the Open Settings link, the three-step guide and the Home banner. |
| `VoiceDraftKeyboard/KeyButton.swift` | `KeyButton` (light and dark key styles) and `KeyRepeater` (held delete). |

Setup guide: whenever the keyboard appears with Full Access, it writes `keyboard-presence.json` as
`{ seenAt, fullAccess: true, version }`. The app re-reads it on launch and each time the scene becomes active, for
example after returning from Settings. Without the marker, Settings > Keyboard setup, the onboarding keyboard step and a
Home banner (dismissible until relaunch) show the guide. Its Open Settings button uses `openSettingsURLString`, which
lands on Settings > VoiceDraft, followed by three steps: Keyboards, VoiceDraft, Allow Full Access. Turning on the
VoiceDraft switch there adds the keyboard; General > Keyboard > Add New Keyboard is not needed. The Home banner reuses
the "not set up" status text. With the marker the
app shows "Keyboard enabled with Full Access" and the last-seen time. The marker is not removed when the keyboard is
disabled, because the extension cannot reach the container then.

The app writes `app-status.json` as `{ state: idle|listening|recording|processing, expiresAt, updatedAt, takeID?, lastError? }`
(`takeID` names the take in progress; older files without it still decode) and refreshes `expiresAt` while alive. The keyboard treats the app as available only when `state` is not `idle` and
`expiresAt` is in the future; during standby `expiresAt` never passes the standby deadline.

A take on standby first challenges the app with a fresh UUID (`app-check-request.json` / `app-check-reply.json` and
Darwin notifications). A persisted 15-minute lease can survive force-quit and is only an eligibility hint. The keyboard
shows Connecting until a matching ready reply arrives; after 500 ms without a reply, the same tap opens VoiceDraft.
The check never starts audio, a short released tap still locks recording, and a long hold released before a start
cancels. Active takes/processing check liveness every two seconds and immediately after Finish, with completed results
winning over a missing reply. Losing the app exits waiting and makes the next tap reopen it.

After the ready reply, the keyboard posts `take.start`; releasing a held recording posts `take.stop`. A press shorter
than 0.35 s locks recording, and the next tap posts `take.stop`. The keyboard inserts the result when
`result.updated` fires or when its 0.5 s poll finds a new `latest-result.json`, because Darwin notifications can be
coalesced. It gives up after 60 s without progress.

A take without standby: the button reads "Tap to dictate (opens VoiceDraft)". A tap writes `pending-take.json` and
opens `voicedraft://record` through `ContainingAppOpener`: `extensionContext.open` first (it reported false on
iOS 27.0.1), then the public `openURL:options:completionHandler:` of the `UIApplication` object reached by walking the
responder chain from the input view controller (matched by class; `UIWindowScene` answers the same selector but raises
inside an extension), then the same object looked up by class name; each is retried once
with the scheme spelled `VoiceDraft://` only after the lower-case form failed. The first success wins. The status line
shows "Opened VoiceDraft (method N)" or "Open failed: ext=… · chain=… · app=…", every try is appended to
`open-attempts.json` (last 20, no text content) and Settings > About shows the latest one. Apple treats the responder
chain route as an implementation detail that may change; the fallback is the standby-only mode. The keyboard resumes
or finishes such a take only while `app-status.json` shows the app recording or processing it (updated within
2 minutes, matching `takeID`); otherwise it drops the marker and says "The last take did not start". VoiceDraft
records and starts standby for **Keyboard standby** minutes (Settings, default 15). Debug attempts automatic return after real audio input and PiP preparation, using a fresh matching marker and
PID-validated host identity (system back action fallback). Release keeps manual return; `suspend` is not used. Back in the host app the keyboard
resumes from the marker: "VoiceDraft is recording…" with Finish (posts `take.stop`), and it inserts the result whose id
equals the marker's, then deletes the marker. Markers older than 10 minutes are dropped. The full flow and the App
Store reasoning are in [`docs/ios.md`](../docs/ios.md#process-model).

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

To run on a device, see Device build below.

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
| `Audio/` | `IOSAudioSessionController.swift` | Owns every `AVAudioSession` call: one configuration (`.playAndRecord`, `.measurement`, `[.allowBluetooth, .mixWithOthers, .defaultToSpeaker]`) set only when it differs, activation only when inactive, deactivation, and the active flag cleared on interruption or media-services reset. One instance is shared by the microphone and the keep-alive. |
| | `IOSAudioCapture.swift` | `AVAudioEngine` input tap, `AVAudioConverter` to 16 kHz mono PCM16; activates the shared session and can stop while keeping it active for standby. |
| | `IOSPictureInPictureKeepAlive.swift` | `StandbyKeepAlive` and `StandbyAudioEvent`: the video-call Picture in Picture window (1×1 pt source view, status content view) that keeps standby resident with the microphone closed and the shared session active, the window-closed and start-failure events, and the session's interruption and reset events. |
| | `PCMRouter.swift` | Discards audio outside a take; during a take buffers PCM for HTTP adapters and feeds `LiveAudioFeed` for WebSocket adapters. 10-minute cap, like the Mac. |
| `Pipeline/` | `TakeCoordinator.swift` | Validates the profiles and keys, runs `SpeechClient` and `WritingClient` with `QwenRequests.writing`, applies the selected style, records usage. |
| `Views/` | `RootView`, `HomeView`, `HistoryView`, `SettingsView`, `OnboardingView` | Tabs Dictate, History, Settings; first-launch onboarding. |

`SharedSettings` is stored and synced unchanged, vocabulary included. Sync uses `SyncClient` and `SyncCrypto` with the
Mac's revision rules. Download replaces settings and keys. Upload refuses when the server moved on with different
content and asks the user to download first. The server's 409 shows Core's conflict message.

### Takes

Hold the record button to record and release to stop. A short tap locks recording and a second tap stops it, using
Core's `RecordingGesture`. Modes are Polish and Translate. Each finished take is added to history and written to
`latest-result.json`, followed by a `result.updated` post. Every take or listening change rewrites `app-status.json`
and posts `status.updated`.

### Standby (listening session)

Standby keeps the app resident with the microphone closed between takes: `IOSPictureInPictureKeepAlive` uses a
video-call Picture in Picture window (`AVPictureInPictureController` with an `activeVideoCallSourceView` content
source). It is created and explicitly started while the source scene is foreground-active; starting on
`willResignActive` failed on device with AVKitErrorDomain(-1001). Availability follows the actual did-start callback,
with bounded retry/timeout while preparing. It runs until standby
ends, through takes. Debug automatically hides it using subpixel content height and a runtime-checked private controls
setter: the tested iOS 27.0.1 window has zero height, without an edge arrow. A visible/missing window fails the hidden
standby check; the Home control and standby deadline remain available to stop it. Release retains a visible window,
where tapping the window returns to the app and standby continues, while closing it (or the system
ending it, or a failed start) ends standby and publishes the status at once. The microphone and the keep-alive use
one session configuration owned by `IOSAudioSessionController` (`.playAndRecord`, `.measurement`,
`[.allowBluetooth, .mixWithOthers, .defaultToSpeaker]`), set and activated by whichever starts first; the session
stays active for the whole standby, because deactivating it ends video-call Picture in Picture. Each take builds a
fresh microphone engine and discards it afterwards; no engine runs between takes. On iOS 27.0.1 a category change
from the background failed with '!int' even with both categories mixable, which is why the category never changes.
Audio errors name the failed step (`AudioStepError`). `AppModel.settleStandbyAudio()` is the single policy
(recording: microphone, keep-alive untouched; standby: keep-alive; neither: everything off and the session
deactivated), unit-tested with `SilentAudioCapture` and `SilentStandbyKeepAlive`. An interruption leaves the window
up and the session is activated again when it ends or after a media-services reset. If iOS refuses to start recording
in the background or the session cannot be activated again, standby ends and `app-status.json` carries `lastError`,
which the keyboard shows; its next tap opens the app. Under the earlier silent-output keep-alive that is what
happened on iOS 27.0.1 (`take: engine.start failed: OSStatus 2003329396 'what'`); foreground preparation followed by two real background takes under PiP produced PCM on the device, and
screenshots confirmed the microphone indicator turns off between takes (details in `docs/ios.md`). Manual standby
briefly establishes input in the foreground and discards it; `IOSAudioCapture.start()` waits for an actual input
buffer with a three-second timeout per attempt. HFP format negotiation before readiness can rebuild the engine at
most twice after 300 ms, keeping the session active; configuration changes during a ready recording still interrupt
the take, and cancellation prevents a pending retry. The same preparation occurs naturally in a keyboard-opened take. Settings > Keep
microphone open during standby (`standbyKeepsMicrophoneOpen`, default off) keeps the microphone running for the
whole window instead. A keyboard take (Darwin
`take.start` or `voicedraft://record`) starts or extends it to now + `keyboardStandbyMinutes` (Settings > Keyboard
standby: Off, 5, 15 or 30; default 15; Off means no standby). "Start standby now" on the Dictate tab starts it by
hand. It ends at that fixed deadline (`StandbyPolicy`), not refreshed by use, or when the user turns it off; a take
running at the deadline finishes first. The microphone indicator is on only during a take (all window long with the
fallback setting), and audio outside a take is discarded.
While on standby, `app-status.json` carries a 15-minute lease refreshed every minute and capped at the deadline.
Without standby the status is already expired, so the keyboard offers "Tap to dictate (opens VoiceDraft)".

The app ignores keyboard `take.start` unless standby is on. A keyboard take always ends with a result file whose
`id` is the take id. On failure, including a missing key or no speech, the text is empty and the keyboard inserts
nothing. After a keyboard stop the app holds a background task until processing finishes.

## Tests

```sh
xcodebuild -project ios/VoiceDraft.xcodeproj -scheme VoiceDraft \
  -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
```

The tests cover status availability, the shared result file, the take state machine, `AppModel` takes driven with
silent audio and in-memory credentials, and `IOSLocalStore` round trips. No test opens the microphone, the Keychain
or the network.

## Device build

For device builds, choose your own Apple Development team in Xcode for the app, keyboard and test targets. Use bundle identifiers and an App Group registered to that team. Configure the same group in both entitlements files and the shared App Group identifier.

- Register the App Group once in the Xcode GUI before the first command-line build. Open each of `VoiceDraft` and
  `VoiceDraftKeyboard`, go to Signing & Capabilities, and select your registered group under App Groups. Command-line
  provisioning alone creates App IDs with the App Groups capability but no group assigned. Signing then fails with
  "Provisioning profile ... doesn't match the entitlements file's value for the
  com.apple.security.application-groups entitlement".
- `xcodebuild` needs the device's hardware UDID from `xcrun xctrace list devices`, not the CoreDevice identifier that
  `xcrun devicectl list devices` prints.
- Personal Team profiles expire after 7 days. Rebuild and reinstall before then.
- Automatic signing reuses an existing profile as long as it is still valid at build time, so a build made late in a
  profile's week still stops working on day 7. After building, check both embedded profiles' `ExpirationDate`:
  `security cms -D -i <app>/embedded.mobileprovision | plutil -extract ExpirationDate raw -o - -` and the same for
  `<app>/PlugIns/VoiceDraftKeyboard.appex/embedded.mobileprovision`. To force fresh profiles, move the old ones out of
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles` before building.
- On first install, trust the developer under Settings > General > VPN & Device Management, or launch fails with
  "profile has not been explicitly trusted by the user".

```sh
xcodebuild -project ios/VoiceDraft.xcodeproj -scheme VoiceDraft -configuration Debug \
  -destination 'id=<hardware UDID>' -derivedDataPath <derived data> \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <CoreDevice id> \
  <derived data>/Build/Products/Debug-iphoneos/VoiceDraft.app
xcrun devicectl device process launch --device <CoreDevice id> com.voicedraft.ios
```

Then add the keyboard under Settings > General > Keyboard > Keyboards > Add New Keyboard, allow Full Access, and grant
the microphone on the first take.
