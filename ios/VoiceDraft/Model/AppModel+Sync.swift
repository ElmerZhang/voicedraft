import CryptoKit
import Foundation
import VoiceDraftCore

/// Sync with the user's VoiceDraft server through Core's `SyncClient` and `SyncCrypto`, with the same
/// envelope, revision rules and Keychain handling as the Mac app. History and audio never leave the device.
extension AppModel {
    var syncToken: String { (try? dependencies.credentials.read(CredentialAccount.syncToken)) ?? "" }
    var syncPassphrase: String { (try? dependencies.credentials.read(CredentialAccount.syncPassphrase)) ?? "" }

    /// Validates and stores the connection. URLs must be HTTPS, or HTTP on localhost (`Endpoint.validate`
    /// through `SyncClient`). A different URL or token restarts revision tracking.
    @discardableResult
    func configureSync(url: String, token: String, passphrase: String) -> Bool {
        do {
            let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !syncing else {
                throw VoiceDraftError.message("Wait for the current sync to finish before changing the connection.")
            }
            _ = try SyncClient(baseURL: url, token: token)
            guard passphrase.count >= 12 else {
                throw VoiceDraftError.message("Choose a sync passphrase with at least 12 characters.")
            }
            let identity = SHA256.hash(data: Data((url + "|" + token).utf8)).map { String(format: "%02x", $0) }.joined()
            try dependencies.credentials.write(token, account: CredentialAccount.syncToken)
            try dependencies.credentials.write(passphrase, account: CredentialAccount.syncPassphrase)
            updateDevice { device in
                if identity != device.syncIdentity {
                    device.syncRevision = 0
                    device.syncIdentity = identity
                    device.dirty = true
                    device.lastSyncedAt = nil
                }
                device.serverURL = url
            }
            errorMessage = ""
            setSync(status: "Connection saved. Download or upload to continue.")
            return true
        } catch {
            errorMessage = .init(error: error)
            return false
        }
    }

    /// The current settings plus every profile's key, exactly what the Mac uploads.
    func syncSnapshot() throws -> SyncSnapshot {
        var keys: [String: String] = [:]
        for profile in settings.profiles {
            keys[profile.id.uuidString] = try dependencies.credentials.read(CredentialAccount.profile(profile.id))
        }
        return SyncSnapshot(settings: settings, credentials: keys)
    }

    /// Replaces local settings, vocabulary and API keys with the server copy.
    func downloadSync() async {
        guard !syncing, !busy else { return }
        setSyncing(true)
        defer { setSyncing(false) }
        do {
            let client = try SyncClient(baseURL: device.serverURL, token: syncToken)
            let passphrase = syncPassphrase
            let remote = try await client.fetch()
            guard let envelope = remote.payload else {
                throw VoiceDraftError.message("The server is empty. Upload settings from a device first.")
            }
            let decoded = try await Task.detached { try SyncCrypto.decrypt(envelope, passphrase: passphrase) }.value
            guard !busy else { throw VoiceDraftError.message("Settings changed during sync. Try again.") }
            try applySnapshot(decoded, revision: remote.revision)
            setSync(status: syncedStatus())
        } catch { setSync(status: .init(error: error)) }
    }

    /// Encrypts and uploads the local state on top of the revision this device last saw. When the server
    /// moved on with different content the upload stops and asks the user to download first.
    func uploadSync() async {
        guard !syncing, !busy else { return }
        setSyncing(true)
        defer { setSyncing(false) }
        do {
            let client = try SyncClient(baseURL: device.serverURL, token: syncToken)
            let passphrase = syncPassphrase
            let before = try syncSnapshot()
            let remote = try await client.fetch()
            guard remote.revision >= device.syncRevision else {
                throw VoiceDraftError.message("The server revision moved backwards. Check the server backup before downloading explicitly.")
            }
            if let envelope = remote.payload, remote.revision != device.syncRevision {
                let decoded = try await Task.detached { try SyncCrypto.decrypt(envelope, passphrase: passphrase) }.value
                guard decoded == before else {
                    throw VoiceDraftError.message("The server has changes from another device. Download them first, then reapply your edits. Nothing was overwritten.")
                }
                updateDevice { $0.syncRevision = remote.revision; $0.dirty = false; $0.lastSyncedAt = Date() }
                setSync(status: syncedStatus())
                return
            }
            let envelope = try await Task.detached { try SyncCrypto.encrypt(before, passphrase: passphrase) }.value
            // A 409 from another device's concurrent upload surfaces as Core's "Sync conflict" message.
            let saved = try await client.upload(envelope, revision: remote.revision)
            let after = try syncSnapshot()
            updateDevice { $0.syncRevision = saved.revision; $0.dirty = after != before; $0.lastSyncedAt = Date() }
            setSync(status: syncedStatus())
        } catch { setSync(status: .init(error: error)) }
    }

    /// Mirrors the Mac `apply`: validate, keep a recovery copy, write keys, then settings; roll keys back if
    /// anything fails.
    func applySnapshot(_ incoming: SyncSnapshot, revision: Int) throws {
        try incoming.validate()
        let store = dependencies.store
        let credentials = dependencies.credentials
        try store?.write(settings, name: "settings-before-sync")
        var old: [String: String] = [:]
        for profile in incoming.settings.profiles {
            old[profile.id.uuidString] = try credentials.read(CredentialAccount.profile(profile.id))
        }
        do {
            for profile in incoming.settings.profiles {
                try credentials.write(incoming.credentials[profile.id.uuidString] ?? "",
                                      account: CredentialAccount.profile(profile.id))
            }
            try store?.saveSettings(incoming.settings)
        } catch {
            for (account, value) in old { try? credentials.write(value, account: account) }
            throw error
        }
        var device = device
        device.syncRevision = revision
        device.dirty = false
        device.lastSyncedAt = Date()
        applySyncedState(settings: incoming.settings, device: device)
        persistDevice()
    }
}
