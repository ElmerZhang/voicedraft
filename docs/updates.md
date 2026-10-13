# Self-hosted signed updates

The user selected self-hosted HTTPS and has not provisioned a URL. VoiceDraft includes the updater and a local release tool; hosting remains a separate deployment step.

## One-time signing setup

Create an Ed25519 release key in a private directory, outside the repository and public web root:

```sh
swift scripts/make-update.swift keygen /secure/private/voicedraft-update-key
```

The file is created with mode 0600, and the command refuses to overwrite a key. Save a secure backup. The printed **public** key goes in VoiceDraft → Settings → Software updates; the private key stays only with the release operator. This signature is independent of Apple Developer ID signing.

## Build and sign a release

Use a strictly increasing numeric build number and a numeric version. The default development build is 0.2.0 (2):

```sh
VOICEDRAFT_VERSION=0.2.1 VOICEDRAFT_BUILD=3 ./scripts/build-app.sh
```

For distributed apps, provide `VOICEDRAFT_CODESIGN_IDENTITY` and complete your Developer ID/notarization workflow. The existing default remains ad-hoc signing for personal local builds. Gatekeeper, TCC and macOS login-item behavior should be accepted using your actual signed installation.

Choose a fresh output directory and an immutable HTTPS ZIP URL, then sign:

```sh
VOICEDRAFT_RELEASE_NOTES='Describe the user-visible changes.' \
  swift scripts/make-update.swift sign \
  "$PWD/dist/VoiceDraft.app" \
  https://updates.example.com/voicedraft/0.2.1/VoiceDraft.zip \
  /secure/private/voicedraft-update-key \
  "$PWD/output/releases/0.2.1" arm64
```

The command creates `VoiceDraft.zip` and `update.json`. It does not upload anything. `x86_64` and `universal` are accepted only when you actually build that architecture; the packaging command does not cross-compile on your behalf. Publish the ZIP first and replace the feed last. Use separate feeds when shipping separate architectures.

Serve both files directly over HTTPS, without redirects or login cookies. Configure a stable manifest URL such as `https://updates.example.com/voicedraft/update.json` and the public key in the app. Enable daily checks or click Check now. Signed metadata includes version/build, architecture, minimum macOS, download URL, exact byte length, SHA-256 and notes.

## Installation behavior

Checks fetch metadata only. Clicking **Install and restart** downloads into a private staging directory beside the current app, verifies the manifest signature and ZIP digest, checks archive paths/size/type, extracts the app, checks its bundle ID/version/build and code signature, then quits and replaces the current bundle. The old bundle is kept during replacement for rollback if moving or opening the new app fails. Configuration, Keychain, history and audio directories are untouched.

The running app must be named `VoiceDraft.app` in a writable directory. A non-writable system Applications directory requires moving it to a user-writable Applications directory; the app does not request administrator access. Updates require a greater build number and a matching architecture/OS. There is no automatic downgrade or silent installation.

Never host the private key. To rotate keys, distribute a release that deliberately changes the trusted public key/configuration first; merely signing the next manifest with another key will be rejected. Keep the previous package and feed available to the release operator for recovery.
