# Security policy

## Reporting a vulnerability

Please do not open a public issue. Either open a private GitHub security advisory on this repository, or email the maintainer at elmerzhang8@gmail.com. Include the affected version, steps to reproduce and the impact you see.

## Supported versions

Only the latest release receives security fixes.

## Threat model

VoiceDraft has no account system and no VoiceDraft-operated inference service. Audio and text go straight from your Mac to the model provider you configured. The optional sync server stores one client-side encrypted envelope (PBKDF2-SHA256, 600,000 iterations, then AES-256-GCM).

| Actor | Can see | Cannot see |
| --- | --- | --- |
| The sync server operator | The ciphertext envelope and its size, revision numbers, when and how often you sync, and your bearer access token. | Your model settings, vocabulary, API keys or sync passphrase in plaintext. Audio. History. The server has no audio pipeline, and history is never synced. |
| The model provider you configured | The audio, text, selections and vocabulary hints that you send to it, plus your API key for that provider. Optional screen context while that feature is on. | Your other providers' keys, your sync passphrase, your sync server data, and your local history. |
| Someone with your Mac's user account | Local history (plain JSON, mode 0600, up to 500 records), local settings, usage logs, and any retained audio. Keychain items such as API keys, the sync token and the passphrase are readable only on your unlocked device. | Nothing is hidden from a fully compromised, unlocked account. Local history is not encrypted. |

## What we promise

- No telemetry.
- No inference proxy. We never route your audio or text through a VoiceDraft-operated service.
- No audio on the sync server.
- Your sync passphrase never leaves the client.
- API keys are stored in the Keychain and reach the server only inside the encrypted envelope.
- History never syncs.

## What we cannot protect against

- A model provider that logs or retains what you send it.
- A compromised or unlocked Mac account, malware with Accessibility or Keychain access, or physical access to an unlocked device.
- A weak sync passphrase. Anyone who obtains the ciphertext can try to guess it offline, so choose a long, unique one.
- Loss of your passphrase. There is no account recovery.
- Traffic analysis. The server operator and network observers can see access timing and envelope size, and you must provide HTTPS yourself when self-hosting.
- Text you dictate into the wrong application, or apps that expose their contents to Accessibility.
