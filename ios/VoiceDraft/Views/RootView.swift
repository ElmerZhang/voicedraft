import SwiftUI
import VoiceDraftCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label(AppText.t("Dictate"), systemImage: "mic") }
            HistoryView()
                .tabItem { Label(AppText.t("History"), systemImage: "clock") }
            SettingsView()
                .tabItem { Label(AppText.t("Settings"), systemImage: "gearshape") }
        }
        // Strings are resolved when views are built; rebuild everything when the language changes.
        .id(model.language)
        .fullScreenCover(isPresented: $model.showingOnboarding) {
            OnboardingView()
                .environmentObject(model)
                .pairingConfirmation(model: model, active: true)
        }
        // While onboarding covers the tabs, onboarding presents the confirmation instead.
        .pairingConfirmation(model: model, active: !model.showingOnboarding)
        .fullScreenCover(isPresented: Binding(get: { model.keyboardTakeID != nil },
                                              set: { if !$0 { model.dismissKeyboardTake() } })) {
            KeyboardTakeView()
                .environmentObject(model)
        }
        // Cold launches deliver links here too; the model is already loaded by then.
        .onOpenURL { url in
            if !model.receiveRecordLink(url) { model.receivePairingLink(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.sceneBecameActive() }
        }
    }
}

/// Asks before a pairing link replaces this iPhone's connection, settings and API keys.
struct PairingConfirmation: ViewModifier {
    @ObservedObject var model: AppModel
    let active: Bool

    func body(content: Content) -> some View {
        let pairing = model.pendingPairing
        let host = pairing.flatMap { URL(string: $0.serverURL)?.host } ?? ""
        content.alert(
            Text(verbatim: AppText.t("Connect to {0} and download the server copy?", host)),
            isPresented: Binding(get: { active && model.pendingPairing != nil },
                                 set: { if !$0, active { model.pendingPairing = nil } }),
            presenting: pairing
        ) { pairing in
            Button(AppText.t("Connect")) { Task { await model.connectPairing(pairing) } }
            Button(AppText.t("Cancel"), role: .cancel) { model.pendingPairing = nil }
        } message: { _ in
            Text(verbatim: AppText.t("This replaces the settings and API keys on this iPhone."))
        }
    }
}

extension View {
    func pairingConfirmation(model: AppModel, active: Bool) -> some View {
        modifier(PairingConfirmation(model: model, active: active))
    }
}

/// Shows `AppModel.errorMessage` or `notice` as a dismissible banner.
struct MessageBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.errorMessage.isEmpty {
            banner(AppText.render(model.errorMessage), systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                model.errorMessage = ""
            }
        } else if !model.notice.isEmpty {
            banner(AppText.render(model.notice), systemImage: "checkmark.circle.fill", tint: .green) {
                model.notice = ""
            }
            .task(id: model.notice.key) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                model.notice = ""
            }
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(verbatim: text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(AppText.t("Dismiss"))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}
