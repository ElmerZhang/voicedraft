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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.sceneBecameActive() }
        }
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
