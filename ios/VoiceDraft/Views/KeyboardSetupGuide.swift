import SwiftUI
import UIKit
import VoiceDraftCore

/// Whether the keyboard has been enabled, judged only from the presence marker the keyboard writes
/// with Full Access. iOS has no public API for this.
enum KeyboardSetupStatus: Equatable {
    case notSetUp
    case enabled(lastSeen: Date)

    init(presence: KeyboardPresence?) {
        if let presence, presence.fullAccess {
            self = .enabled(lastSeen: presence.seenAt)
        } else {
            self = .notSetUp
        }
    }

    var isSetUp: Bool {
        if case .enabled = self { return true }
        return false
    }

    /// Home shows the compact setup banner only while the keyboard is not set up and the user has not
    /// dismissed it in this session.
    func showsHomeBanner(dismissed: Bool) -> Bool {
        !isSetUp && !dismissed
    }

    /// The status line shown above the setup guide.
    var message: String {
        switch self {
        case .notSetUp:
            return AppText.t("Keyboard not set up yet. Everything is done on the VoiceDraft page in Settings.")
        case .enabled(let lastSeen):
            let time = lastSeen.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale))
            return AppText.t("Keyboard enabled with Full Access (last seen {0})", time)
        }
    }
}

enum KeyboardSettingsLink {
    /// Opens Settings > VoiceDraft, which lists "Keyboards" for apps that ship a keyboard extension.
    /// Uses only the public `openSettingsURLString`.
    @MainActor static func open() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

struct KeyboardStatusLine: View {
    let status: KeyboardSetupStatus

    var body: some View {
        Label {
            Text(verbatim: status.message)
        } icon: {
            Image(systemName: status.isSetUp ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(status.isSetUp ? Color.green : Color.orange)
        }
    }
}

/// The three steps after "Open Settings", the button, and why Full Access is needed.
struct KeyboardSetupSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, AppText.t("Tap Keyboards."))
            step(2, AppText.t("Turn on VoiceDraft — this adds the keyboard; you do not need General > Keyboard > Add New Keyboard."))
            step(3, AppText.t("Turn on Allow Full Access."))
            Button {
                KeyboardSettingsLink.open()
            } label: {
                Label(AppText.t("Open Settings"), systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
            Text(verbatim: AppText.t("Full Access only lets the keyboard read results from VoiceDraft. The keyboard has no networking code and is open source."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)").font(.headline).foregroundStyle(.tint)
            Text(verbatim: text)
        }
    }
}

/// Home's compact banner, shown while the keyboard is not set up.
struct KeyboardSetupBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.keyboardSetup.showsHomeBanner(dismissed: model.keyboardBannerDismissed) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "keyboard").foregroundStyle(.tint)
                Text(verbatim: model.keyboardSetup.message)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(AppText.t("Open Settings")) { KeyboardSettingsLink.open() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button { model.keyboardBannerDismissed = true } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(AppText.t("Dismiss"))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        }
    }
}
