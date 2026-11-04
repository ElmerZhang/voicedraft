import SwiftUI
import VoiceDraftCore

/// Full-screen view for a take the keyboard opened the app for (`voicedraft://record`). The user may leave
/// at any time with the system back affordance and finish from the keyboard; the result goes to the keyboard
/// either way.
struct KeyboardTakeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            content
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }

    private var isThisTake: Bool { model.takeSource == .keyboard && model.takeState != .idle }

    private var deliveredText: String? {
        guard let result = model.lastResult, result.id == model.keyboardTakeID, !result.text.isEmpty else { return nil }
        return result.text
    }

    @ViewBuilder
    private var content: some View {
        if isThisTake, model.takeState == .recording {
            recording
        } else if isThisTake {
            processing
        } else if let text = deliveredText {
            delivered(text)
        } else {
            finishedWithoutResult
        }
    }

    private var recording: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.red)
                .scaleEffect(1 + min(max(model.level, 0), 1) * 0.3)
                .animation(.easeOut(duration: 0.1), value: model.level)
                .accessibilityHidden(true)
            Text(verbatim: elapsedText)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Button {
                model.stopTake()
            } label: {
                Text(verbatim: AppText.t("Finish")).font(.title2.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Button(AppText.t("Cancel"), role: .cancel) { model.dismissKeyboardTake() }
            Text(verbatim: AppText.t("Recording. Tap the back arrow or swipe from the bottom edge to return to the previous app and keep talking; finish from the keyboard."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var processing: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(verbatim: model.transcript.isEmpty ? AppText.t("Recognizing speech…") : AppText.t("Writing…"))
                .font(.headline)
            if !model.resultText.isEmpty {
                Text(verbatim: model.resultText).foregroundStyle(.secondary).lineLimit(6)
            }
        }
    }

    private func delivered(_ text: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text(verbatim: AppModel.isAnswer(model.lastResult)
                 ? AppText.t("Answer sent to the keyboard. Go back to the previous app to insert or copy it.")
                 : AppText.t("Sent to the keyboard. Go back to the previous app to insert it."))
                .font(.headline)
                .multilineTextAlignment(.center)
            ScrollView {
                Text(verbatim: text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 240)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            HStack {
                Button(AppText.t("Copy")) { model.copy(text) }.buttonStyle(.bordered)
                Button(AppText.t("Done")) { model.dismissKeyboardTake() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var finishedWithoutResult: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 48)).foregroundStyle(.orange)
            Text(verbatim: model.errorMessage.isEmpty ? AppText.t("Nothing was recorded.") : AppText.render(model.errorMessage))
                .multilineTextAlignment(.center)
            Button(AppText.t("Done")) { model.dismissKeyboardTake() }.buttonStyle(.borderedProminent)
        }
    }

    private var elapsedText: String {
        let seconds = Int(model.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
