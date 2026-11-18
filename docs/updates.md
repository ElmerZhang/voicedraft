# Self-hosted signed updates

The user selected self-hosted HTTPS and has not provisioned a URL. VoiceDraft includes the updater and a local release tool; hosting remains a separate deployment step.

## One-time signing setup

Create an Ed25519 release key in a private directory, outside the repository and public web root:

```sh
swift scripts/make-update.swift keygen /secure/private/voicedraft-update-key
```

The file is created with mode 0600, and the command refuses to overwrite a key. Save a secure backup. The printed **public** key goes in VoiceDraft → Settings → Software updates; the private key stays only with the release operator. This signature is independent of Apple Developer ID signing.

## Build and sign a release

Use a strictly increasing numeric build number and a numeric version. The preview build defaults to 0.2.10 (12):

```sh
VOICEDRAFT_VERSION=0.2.10 VOICEDRAFT_BUILD=12 ./scripts/build-app.sh
```

For a public Mac download, check out the release commit in a clean worktree and set `VOICEDRAFT_CODESIGN_IDENTITY` to the full Developer ID Application certificate name. The build script enables hardened runtime and microphone access for that identity. It includes the AGPL text and the source revision in the bundle. For a fork or source archive, set `VOICEDRAFT_SOURCE_URL` to the matching public source. Local builds default to ad-hoc signing.

After signing, notarize the app, staple the accepted ticket, and then create the downloadable ZIP:

```sh
ditto -c -k --keepParent dist/VoiceDraft.app dist/notary-submission.zip
xcrun notarytool submit dist/notary-submission.zip --keychain-profile "$NOTARY_PROFILE" --wait
# Continue after the service reports Accepted.
xcrun stapler staple dist/VoiceDraft.app
xcrun stapler validate dist/VoiceDraft.app
spctl --assess --type execute --verbose=2 dist/VoiceDraft.app
ditto -c -k --keepParent dist/VoiceDraft.app dist/VoiceDraft-0.2.10-macOS-arm64.zip
shasum -a 256 dist/VoiceDraft-0.2.10-macOS-arm64.zip
```

Publish the final ZIP and checksum on the GitHub Release for the matching tag. State the minimum macOS version, CPU architecture and known limitations in its release notes. A self-hosted updater feed is optional.

Choose a fresh output directory and an immutable HTTPS ZIP URL, then sign:

```sh
VOICEDRAFT_RELEASE_NOTES='Describe the user-visible changes.' \
  swift scripts/make-update.swift sign \
  "$PWD/dist/VoiceDraft.app" \
  https://updates.example.com/voicedraft/0.2.10/VoiceDraft.zip \
  /secure/private/voicedraft-update-key \
  "$PWD/output/releases/0.2.10" arm64
```

The command creates `VoiceDraft.zip` and `update.json`. It does not upload anything. `x86_64` and `universal` are accepted only when you actually build that architecture; the packaging command does not cross-compile on your behalf. Publish the ZIP first and replace the feed last. Use separate feeds when shipping separate architectures.

Serve both files directly over HTTPS, without redirects or login cookies. Configure a stable manifest URL such as `https://updates.example.com/voicedraft/update.json` and the public key in the app. Enable daily checks or click Check now. Signed metadata includes version/build, architecture, minimum macOS, download URL, exact byte length, SHA-256 and notes.

## Installation behavior

Checks fetch metadata only. Clicking **Install and restart** downloads into a private staging directory beside the current app, verifies the manifest signature and ZIP digest, checks archive paths/size/type, extracts the app, checks its bundle ID/version/build and code signature, then quits and replaces the current bundle. The old bundle is kept during replacement for rollback if moving or opening the new app fails. Configuration, Keychain, history and audio directories are untouched.

The running app must be named `VoiceDraft.app` in a writable directory. A non-writable system Applications directory requires moving it to a user-writable Applications directory; the app does not request administrator access. Updates require a greater build number and a matching architecture/OS. There is no automatic downgrade or silent installation.

Never host the private key. To rotate keys, distribute a release that deliberately changes the trusted public key/configuration first; merely signing the next manifest with another key will be rejected. Keep the previous package and feed available to the release operator for recovery.
