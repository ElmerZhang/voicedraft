# Architecture

## Boundaries

```text
SwiftUI views
    -> AppState (recording workflow, settings, synchronization)
        -> AppKit / AVFoundation (shortcuts, audio, focus, insertion)
        -> LocalStore / KeychainStore (local persistence)
        -> VoiceDraftCore
            -> QwenRequests -> HTTPTransport -> user's Bailian endpoint
            -> SyncCrypto -> SyncClient -> encrypted configuration server
```

Views submit changes through AppState; they do not write storage. The model adapter owns provider protocol details; the coordinator owns capture, cancellation, output delivery, and history. The server stores opaque encrypted configuration and does not proxy inference, receive audio, or manage model billing.

## Models and inference

`ModelProfile` has a stable UUID, role, name, full endpoint, model ID, and additional JSON parameters. A saved profile's UUID also identifies its local Keychain credential. Speech and writing profiles can have different accounts, endpoints, regions, and models. Additional JSON cannot override messages, model, streaming mode, or authentication.

The initial adapter supports Qwen3-ASR-Flash's compatible HTTP `input_audio` format and Qwen text generation's chat completion format. Recording uses mono 16 kHz 16-bit PCM WAV. The four-minute limit keeps raw audio below the ASR profile's file limit. Audio is converted to a data URL and sent with vocabulary context. Writing mode determines the system instruction; transcript and selected text are structured data in the user message. Qwen may still make semantic mistakes; outputs are editable and the original transcript remains accessible.

Recordings are written to a randomly named file with user-only permissions, read at stop, then deleted even if a later model request fails. No audio is stored by the sync server. Provider-side handling follows the user's Bailian account and endpoint policies; client-side deletion is not a claim about provider retention. A forced process termination can leave a temporary recording; startup cleanup is tracked in the roadmap.

An active run captures its selected models, credentials, vocabulary, mode, selection, and input target before recording. Configuration changes do not alter a running request. Cancel invalidates the run ID and cancels the task; late responses cannot insert text. When writing fails after ASR succeeds, the raw transcript is preserved and no partial rewrite is automatically inserted.

## System integration

SwiftUI owns the application menu through scene commands; AppKit owns the main window and recording panel. Standard editing shortcuts (undo, redo, cut, copy, paste, and select all) dispatch through AppKit's responder chain to the focused editor, including model configuration sheets. Do not assign `NSApp.mainMenu` during launch: SwiftUI can replace it when assembling its scene menus.

All nine single-line inputs use `SingleLineField`, an AppKit `NSTextField`/`NSSecureTextField` bridge with `usesSingleLineMode` enabled. The native field editor replaces pasted line/paragraph separators with spaces and suppresses newline insertion commands; text scrolls horizontally. A one-line height or SwiftUI `lineLimit` alone is not an input constraint. Keep the native editing path for undo, selection, and input methods; multiline transcript, selection, vocabulary, style, and JSON editors remain `TextEditor` views.

On explicit saves, profile names/endpoints/model IDs, translation targets, API keys, and sync URL/token values are trimmed at their edges. Model requests also trim the model ID and reject a whitespace-only ID, including for older stored configurations and unsaved connection tests. Model editors trim existing profile values on opening; search ignores outer query whitespace. Sync passphrases retain their exact spaces, since those spaces affect encryption. Existing credentials are not rewritten merely by opening a page.

Carbon global hotkeys start/stop workflows. A nonactivating AppKit panel displays recording state without stealing focus. Accessibility captures the frontmost application's focused element and selected range/text. Before insertion, the app rechecks process, field, selection, and range. Password fields are excluded.

Insertion first uses the Accessibility selected-text attribute when supported. Otherwise it temporarily supplies the clipboard and sends Command-V. Existing clipboard formats are restored after 800 ms only if no newer clipboard change occurred. Paste is best effort; slow or nonstandard editors may need manual copying. The app never sends Enter or runs a model-generated command. Selected-text access and insertion require real-app compatibility testing.

## Persistence

`~/Library/Application Support/VoiceDraft/` contains versioned settings, per-device preferences, and up to 500 history records in user-readable JSON with mode 0600. The directory uses mode 0700. This is local storage, not an encrypted history database. Keys and the synchronization access token/passphrase use Keychain items accessible only on the device while unlocked.

History, recordings, microphone settings, paste preferences, and server login details are not part of the shared configuration. Disabling history affects future entries; deletion removes existing entries separately. Before an explicit remote replacement, the previous nonsecret settings are copied to `settings-before-sync.json`. This backup excludes keys; it is not a full encrypted vault backup.

## Encrypted sync protocol v1

Plaintext snapshot: `{settings: SharedSettings, credentials: {profileUUID: apiKey}}`.

1. The client validates the snapshot and derives a 256-bit key from the passphrase using PBKDF2-HMAC-SHA256, 600,000 iterations, and a fresh random 16-byte salt for each upload.
2. AES-256-GCM encrypts the UTF-8 JSON with a fresh nonce. Authenticated associated data is the UTF-8 string `VoiceDraft.sync.v1`.
3. The envelope has exactly `version: 1`, `algorithm: "PBKDF2-SHA256+AES-256-GCM"`, `iterations: 600000`, `salt` (base64), and `ciphertext` (base64 of CryptoKit's combined `nonce || ciphertext || tag`). This format is implementable on other platforms.
4. The service authenticates a separate bearer access token. The passphrase never leaves the client. Knowledge of the access token permits reading/replacing ciphertext but does not decrypt it.
5. `GET /v1/sync` returns `{revision, payload}`. Empty vaults return revision 0 and null payload. `PUT /v1/sync` requires the last known revision and the encrypted envelope; a SQLite transaction increments the revision atomically or returns HTTP 409.
6. The client decrypts and validates a remote snapshot before applying it. It refuses automatic overwrite when both local and remote settings changed. A remote copy identical to local state can reconcile a previous upload whose response was lost.

Sync is whole-vault optimistic concurrency, not field-level merging. The initial service has one vault and access token per deployment. Devices use that shared token; user registration, individual device revocation, teams, and multiple tenant vaults are future work. Changing the passphrase alone cannot decrypt the existing vault: coordinated vault migration/rotation is not implemented.

HTTPS is mandatory except loopback development. HTTP redirects are rejected to avoid forwarding credentials. The client detects decreasing revisions relative to a previous successful sync; there is no server-independent freshness proof for a new device. The server can observe envelope size, revisions, and access timing. End-to-end encryption does not hide that metadata or stop a server administrator from deleting data.

## Extension path

Add other providers through protocol-specific request builders and response parsers, with an explicit adapter discriminator in the profile schema and a migration. Do not assume a changed model ID makes ASR protocols compatible. Add streaming as a separate session lifecycle with cancellation and incremental results, preserving current batch behavior. Future clients must reproduce encryption test vectors and sync revision behavior before being released.
