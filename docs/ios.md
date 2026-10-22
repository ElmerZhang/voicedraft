# iOS client

The iOS client is a container app plus a custom keyboard extension under `ios/`. It shares `VoiceDraftCore` with the Mac app and keeps the same rules: users bring their own provider keys, calls go straight from the device to the configured provider, nothing is proxied, and the only server the app talks to is a VoiceDraft sync server chosen by the user. This page owns the iOS boundaries; [architecture.md](architecture.md) owns everything shared with the Mac app.

## Scope

| Included in the first cut | Deliberately excluded |
| --- | --- |
| In-app dictation with Polish, Translate and Ask using the shared adapters and prompts | Edit mode (no selection access from a keyboard) |
| Sync download/upload with the existing envelope and `/v1/sync` protocol | Per-app writing styles and screen context (the extension cannot identify its host app) |
| Vocabulary, styles and provider profiles from `SharedSettings` | Agent context discovery (`AgentContextScanner` reads Codex/Claude folders that do not exist on iOS) |
| Local history, plain JSON like the Mac, never synced | Self-updating (the App Store updates the app) |
| Keyboard extension: insert last result, trigger recording in the container app, minimal typing | Hosted-sync purchase and any in-app purchase (follows later, in the container app only) |

## Process model

Apple keyboard extensions have no microphone access and may not launch other apps (App Store guideline 4.4.1). Recording therefore happens only in the container app. Three flows exist:

1. **In-app dictation.** Hold the record button, release, the app runs the shared speech and writing pipeline, shows the result, copies it on request, appends it to local history and writes it to the app group as the latest result.
2. **Insert from the keyboard.** The keyboard reads the latest result from the app group and inserts it through `textDocumentProxy`. This needs Full Access because the app group container is gated by it.
3. **Record from the keyboard.** The keyboard posts a Darwin notification to start or stop a take. If the container app is alive (foreground, or background with an active listening session), it records, runs the pipeline, writes the result to the app group and posts a result notification; the keyboard inserts it. If the app is not alive, the keyboard shows an "Open VoiceDraft" hint and does nothing else. The keyboard never guesses or retries.

A listening session is explicit: the user turns it on in the app, it keeps the audio session active under the `audio` background mode, and it ends after an idle timeout or when the user turns it off. The app does not play silent audio or use other keep-alive tricks.

## Trust boundaries

| Location | Holds | Never holds |
| --- | --- | --- |
| App group container `group.com.voicedraft` | Latest result (text, mode, timestamp), keyboard status flags, the UI language preference | API keys, sync token, passphrase, history, audio |
| Container app Keychain | API keys, sync token, sync passphrase | — |
| Container app documents (file protection complete) | Settings JSON, history JSON, optional retained audio | — |
| Keyboard extension | Nothing persistent of its own | Any network code. The extension does not link the provider clients and makes no requests |

The keyboard requires Full Access only for the app group. Because the extension contains no networking and is open source, the Full Access warning can be answered with a verifiable statement rather than a promise.

The sync server sees exactly what it sees from the Mac: one ciphertext envelope, its size, revision numbers and access timing. History and audio never leave the device.

## Audio path

The Mac feeds `PCM16Audio` from an `AVCaptureAudioDataOutput` sample buffer. iOS uses an `AVAudioEngine` input tap, converts to 16 kHz mono PCM16 with `AVAudioConverter`, and feeds the same `LiveAudioFeed` for WebSocket adapters or buffers a WAV for HTTP adapters. The audio session uses the `.record` category with Bluetooth allowed and is activated only while a take or a listening session is running.

## Settings and localization

`SharedSettings` is reused unchanged; `applicationStyles` and `screenContextExcludedApps` are ignored on iOS. Device-local options live in an iOS `DeviceSettings` variant. `VoiceDraftCore` resources load through `Bundle.module`; the language preference lives in the app-group `UserDefaults` suite so the app and the keyboard agree.

## App Store constraints that shape the design

- The keyboard offers a next-keyboard button and basic typing without Full Access; voice features explain why Full Access is needed instead of failing silently.
- The extension launches nothing, contains no marketing and no purchases.
- Microphone, and nothing else, is requested by the container app, with a usage string that says audio goes only to the provider the user configured.
- The App Privacy answer is "data not collected": the developer operates no service that receives user data.

## Build

```sh
xcodebuild -project ios/VoiceDraft.xcodeproj -scheme VoiceDraft \
  -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
```

The project links the root package product `VoiceDraftCore`. `swift test --disable-sandbox` at the repository root remains the shared test entry point; iOS-only code is tested through the Xcode project.
