import Foundation
import CoreFoundation

enum FnSystemAction {
    /// A missing preference can still mean macOS's default input-source action.
    /// Read only: writing this preference does not reliably apply it live.
    static func isDisabled() -> Bool {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let value = CFPreferencesCopyValue("AppleFnUsageType" as CFString, domain,
                                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber else {
            return false
        }
        return value.intValue == 0
    }
}
