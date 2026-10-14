# Legacy database fixture

`legacy-vault.db` was generated using the original `server/server.py` `VaultStore` from commit `16fe81e`, before removing that implementation. Seven successful writes leave revision 7 in the unchanged `vault` schema; the WAL was checkpointed before copying the file.

The envelope uses version 1, `PBKDF2-SHA256+AES-256-GCM`, 600,000 iterations, a 16-byte salt of `0x01`, and a 100-byte synthetic ciphertext of `0x02`, both standard base64 encoded. It contains no real configuration, credentials, audio, or decryptable user data.

The Go compatibility test copies this fixture into a temporary directory, reads revision 7, rejects stale/cancelled writes, updates to revision 8, and verifies the legacy SQL/JSON layout remains readable.
