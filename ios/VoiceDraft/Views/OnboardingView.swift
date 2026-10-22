import SwiftUI
import VoiceDraftCore

/// First launch: bring your own key, and the two ways to get configured.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text(verbatim: AppText.t("Welcome to VoiceDraft"))
                        .font(.largeTitle.bold())
                    Text(verbatim: AppText.t("Speak, and VoiceDraft turns it into clean text with the speech and writing models you choose. You bring your own API keys: audio and text go straight from this iPhone to your providers, never through a VoiceDraft service."))
                    option(systemImage: "icloud.and.arrow.down", title: AppText.t("Download from your sync server"),
                           detail: AppText.t("Already use VoiceDraft on a Mac with sync? Enter the same server, token and passphrase in Settings > Sync, then download. Models, keys, styles and vocabulary arrive in one step."))
                    option(systemImage: "key", title: AppText.t("Enter keys on this iPhone"),
                           detail: AppText.t("Open Settings > Models and add an API key for the speech and writing models."))
                    option(systemImage: "keyboard", title: AppText.t("Add the keyboard"),
                           detail: AppText.t("Settings > Keyboard setup explains how to insert results into any app."))
                    Button {
                        model.completeOnboarding()
                    } label: {
                        Text(verbatim: AppText.t("Get started")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(24)
            }
        }
        .interactiveDismissDisabled()
    }

    private func option(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title).font(.headline)
                Text(verbatim: detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
