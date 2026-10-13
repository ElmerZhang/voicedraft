# Architecture

## Boundaries

```text
SwiftUI views
    -> AppState (recording workflow, settings, synchronization)
        -> AppKit / AVFoundation (shortcuts, audio, focus, insertion)
        -> LocalStore / KeychainStore (local persistence)
        -> VoiceDraftCore
            -> SpeechClient / QwenRequests -> HTTPTransport / WebSocket session -> user's Bailian endpoint
            -> SyncCrypto -> SyncClient -> encrypted configuration server
```

Views submit changes through AppState; they do not write storage. The model adapter owns provider protocol details; the coordinator owns capture, cancellation, output delivery, and history. The server stores opaque encrypted configuration and does not proxy inference, receive audio, or manage model billing.

## Models and inference

`ModelProfile` has a stable UUID, role, name, full endpoint, model ID, explicit adapter, speech vocabulary options, and additional JSON parameters. `ModelCatalog` lists only supported ASR models; each entry specifies its adapter and vocabulary capability. Text models use the chat adapter with a model picker and a custom Qwen text deployment option. A saved profile's UUID also identifies its local Keychain credential. Speech and writing profiles can have different accounts, endpoints, regions, and models. Additional JSON cannot override messages, model, streaming mode, or authentication.

Speech adapters are separate: Qwen3-ASR-Flash uses compatible HTTP chat audio and unweighted vocabulary context; Qwen-Audio-3.0/3.1-ASR-Flash uses native HTTP `input`/`parameters` and `output.text`; Qwen-Audio-3.1-ASR-Flash-Message uses task-based WebSocket inference. Weighted models merge personal vocabulary (default weight 1–5) with per-profile overrides (1–5 or 50, at most 50 super hotwords). The app limits the merged vocabulary to 2,000 distinct entries and each entry to 100 characters. The model editor hides unsupported weight controls. Advanced speech parameters are limited to each adapter's supported keys and cannot override the task envelope, audio format, or vocabulary controls.

Recording uses mono 16 kHz 16-bit PCM WAV, limited to four minutes. All recognition still starts after stop. The Message adapter sends `run-task`, waits for `task-started`, sends the recorded WAV in 3,200-byte binary frames while concurrently receiving events, sends `finish-task`, and waits for `task-finished`. It replaces final sentences by ID, ignores provisional and heartbeat results, and rejects unexpected task IDs and incomplete/empty results. This is a recorded-audio WebSocket workflow, not live microphone streaming. The 120-second task deadline, cancellation, and all exits close the socket and unblock pending receives/sends. Native URLSession supplies TLS and the existing delegate rejects redirects. Tests inject an in-memory socket at this boundary; native network behavior and account availability need real-account validation.

Before opening the microphone, the coordinator validates the selected adapter/model/endpoint and vocabulary. Unknown legacy ASR IDs remain available for editing but cannot fall back to chat HTTP. Provider failures expose the HTTP status, recognized diagnostic codes, and UUID request/task IDs; arbitrary error messages are omitted because providers can echo audio, prompts, or credentials.

Writing mode determines the system instruction; transcript and selected text are structured data in the user message. Qwen may still make semantic mistakes; outputs are editable and the original transcript remains accessible.

Recordings are written to a randomly named file with user-only permissions, read at stop, then deleted even if a later model request fails. No audio is stored by the sync server. Provider-side handling follows the user's Bailian account and endpoint policies; client-side deletion is not a claim about provider retention. A forced process termination can leave a temporary recording; startup cleanup is tracked in the roadmap.

An active run captures its selected models, credentials, vocabulary, mode, selection, and input target before recording. Configuration changes do not alter a running request. Cancel invalidates the run ID and cancels the task; late responses cannot insert text. When writing fails after ASR succeeds, the raw transcript is preserved and no partial rewrite is automatically inserted.

## System integration

SwiftUI owns the application menu through scene commands; AppKit owns the main window and recording panel. Standard editing shortcuts (undo, redo, cut, copy, paste, and select all) dispatch through AppKit's responder chain to the focused editor, including model configuration sheets. Do not assign `NSApp.mainMenu` during launch: SwiftUI can replace it when assembling its scene menus.

All single-line inputs, including custom model IDs and per-model hotwords, use `SingleLineField`, an AppKit `NSTextField`/`NSSecureTextField` bridge with `usesSingleLineMode` enabled. The native field editor replaces pasted line/paragraph separators with spaces and suppresses newline insertion commands; text scrolls horizontally. A one-line height or SwiftUI `lineLimit` alone is not an input constraint. Keep the native editing path for undo, selection, and input methods; multiline transcript, selection, vocabulary, style, and JSON editors remain `TextEditor` views.

On explicit saves, profile names/endpoints/model IDs, translation targets, API keys, and sync URL/token values are trimmed at their edges. Model requests also trim the model ID and reject a whitespace-only ID, including for older stored configurations and unsaved connection tests. Model editors trim existing profile values on opening; search ignores outer query whitespace. Sync passphrases retain their exact spaces, since those spaces affect encryption. Existing credentials are not rewritten merely by opening a page. Model editors check Keychain metadata and display a fixed masked placeholder plus a saved-key label. The placeholder is never credential data. An empty replacement preserves the stored key; removing it requires the explicit Remove saved key action followed by Save. Cancelling leaves Keychain unchanged.

Carbon global hotkeys start/stop workflows. A nonactivating AppKit panel displays recording state without stealing focus. Accessibility captures the frontmost application's focused element and selected range/text. Before insertion, the app rechecks process, field, selection, and range. Password fields are excluded.

Insertion first uses the Accessibility selected-text attribute when supported. Otherwise it temporarily supplies the clipboard and sends Command-V. Existing clipboard formats are restored after 800 ms only if no newer clipboard change occurred. Paste is best effort; slow or nonstandard editors may need manual copying. The app never sends Enter or runs a model-generated command. Selected-text access and insertion require real-app compatibility testing.

## Persistence

`~/Library/Application Support/VoiceDraft/` contains versioned settings, per-device preferences, and up to 500 history records in user-readable JSON with mode 0600. The directory uses mode 0700. This is local storage, not an encrypted history database. Keys and the synchronization access token/passphrase use Keychain items accessible only on the device while unlocked.

History, recordings, microphone settings, paste preferences, and server login details are not part of the shared configuration. Disabling history affects future entries; deletion removes existing entries separately. Before an explicit remote replacement, the previous nonsecret settings are copied to `settings-before-sync.json`. This backup excludes keys; it is not a full encrypted vault backup.

## Settings schema v2

Schema v2 stores the explicit adapter and speech options. Decoding v1 infers adapters only for exact catalog ASR IDs, retains profile UUIDs and credential associations, and converts known endpoint paths/schemes on the same region/workspace origin. Custom paths and unknown ASR IDs are preserved for user repair. Storage validation accepts either secure transport so a mismatched legacy address cannot prevent other local data from loading; inference still enforces the selected adapter’s transport before capture. Migration does not read or rewrite credentials and does not automatically write local settings on launch; the next explicit save persists v2. Both local loads and decrypted snapshots use this migration. Newer schema versions fail closed. Older app versions reject v2 rather than sending a WebSocket model through chat HTTP. Update all syncing clients before sharing v2 settings. The encryption envelope and opaque server protocol are unchanged.

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

Add catalog entries only alongside a protocol adapter, capability definitions, and request/response/cancellation fixtures. Do not assume a changed model ID makes ASR protocols compatible. Add live microphone streaming as a separate capture/session lifecycle, preserving current recorded-audio behavior. Future clients must reproduce encryption test vectors and sync revision behavior before being released.
