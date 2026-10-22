import Foundation

/// The three sync values a new device needs. Built from the pairing link; never stored by Core.
public struct SyncPairing: Equatable, Sendable {
    public var serverURL: String
    public var token: String
    public var passphrase: String

    public init(serverURL: String, token: String, passphrase: String) {
        self.serverURL = serverURL
        self.token = token
        self.passphrase = passphrase
    }
}

/// `voicedraft://sync?url=<server>&token=<token>&passphrase=<passphrase>`.
///
/// The link carries the access token and the passphrase in clear text, so it is as sensitive as the
/// passphrase itself: apps show it only on demand and never store it. Every value is validated with the
/// same rules as a manual connection (`SyncClient` for the URL and token, 12 characters for the passphrase).
public enum SyncPairingLink {
    public static let scheme = "voicedraft"
    public static let host = "sync"

    /// Query-safe characters minus the ones that delimit or reinterpret query values.
    private static let allowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+/?")
        return set
    }()

    /// Validates the values and builds the link.
    public static func build(serverURL: String, token: String, passphrase: String) throws -> URL {
        let pairing = SyncPairing(serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                  token: token.trimmingCharacters(in: .whitespacesAndNewlines), passphrase: passphrase)
        try validate(pairing)
        let query = [("url", pairing.serverURL), ("token", pairing.token), ("passphrase", pairing.passphrase)]
            .map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        guard let url = URL(string: "\(scheme)://\(host)?\(query)") else { throw invalid }
        return url
    }

    /// Parses and validates a pairing link.
    public static func parse(_ url: URL) throws -> SyncPairing {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems else { throw invalid }
        var values: [String: String] = [:]
        for item in items {
            // A repeated field is ambiguous; refuse instead of picking one.
            guard values[item.name] == nil, let value = item.value?.removingPercentEncoding else { throw invalid }
            values[item.name] = value
        }
        guard let serverURL = values["url"], let token = values["token"], let passphrase = values["passphrase"] else {
            throw invalid
        }
        let pairing = SyncPairing(serverURL: serverURL, token: token, passphrase: passphrase)
        try validate(pairing)
        return pairing
    }

    private static func validate(_ pairing: SyncPairing) throws {
        _ = try SyncClient(baseURL: pairing.serverURL, token: pairing.token)
        guard pairing.passphrase.count >= 12 else {
            throw VoiceDraftError.message("Choose a sync passphrase with at least 12 characters.")
        }
    }

    private static var invalid: VoiceDraftError {
        .message("This is not a VoiceDraft sync pairing link.")
    }
}
