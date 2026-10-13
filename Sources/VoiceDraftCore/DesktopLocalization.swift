import Foundation

/// Page-layout copy has its own table so it can evolve independently of provider messages.
public func D(_ key: String) -> String {
    L10n.text(key, table: "Desktop")
}
