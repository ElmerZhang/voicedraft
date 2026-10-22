# VoiceDraft iOS (skeleton)

Hand-authored Xcode project for a future VoiceDraft iOS client. No third-party dependencies.

- `VoiceDraft/`: SwiftUI app (`com.voicedraft.ios`), iOS 17.0+, iPhone only.
- `VoiceDraftKeyboard/`: custom keyboard extension (`com.voicedraft.ios.keyboard`), embedded in the app.
- `Shared/`: code compiled into both targets. `SharedResultStore` passes the latest result through
  `latest-result.json` in the `group.com.voicedraft` app-group container.

Build from the repository root:

```sh
xcodebuild -project ios/VoiceDraft.xcodeproj -scheme VoiceDraft \
  -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
```

No `DEVELOPMENT_TEAM` is set. Pick a team in Xcode to run on a device; the app group must be registered for that team.

The project does not yet link `VoiceDraftCore` from the Swift package at the repository root.
Recording is a placeholder: the record button only reflects press state.
