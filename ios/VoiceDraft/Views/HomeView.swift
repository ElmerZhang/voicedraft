import SwiftUI
import VoiceDraftCore

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker(AppText.t("Mode"), selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                        ForEach(IOSDeviceSettings.modes) { mode in
                            Text(verbatim: mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.busy)

                    if model.mode == .ask { AskCard() }

                    MessageBanner()
                    KeyboardSetupBanner()

                    Text(verbatim: statusText)
                        .font(.headline)
                        .foregroundStyle(model.takeState == .recording ? .red : .secondary)
                        .monospacedDigit()
                        .accessibilityAddTraits(.updatesFrequently)

                    RecordButton()

                    if model.takeState == .recording {
                        Button(AppText.t("Cancel"), role: .cancel) { model.cancelTake() }
                    } else if model.takeState == .processing {
                        ProgressView()
                    }

                    ResultCard()
                    ListeningCard()

                    Label {
                        Text(verbatim: AppText.t("Use the VoiceDraft keyboard to insert the last result into any app, or to start a take while listening is on."))
                    } icon: {
                        Image(systemName: "keyboard")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(Text(verbatim: "VoiceDraft"))
        }
    }

    private var statusText: String {
        switch model.takeState {
        case .recording:
            let seconds = Int(model.elapsed)
            return AppText.t("Recording {0}", String(format: "%d:%02d", seconds / 60, seconds % 60))
        case .processing:
            return model.transcript.isEmpty ? AppText.t("Recognizing speech…") : AppText.t("Writing…")
        case .idle:
            return model.listening ? AppText.t("On standby for the keyboard") : AppText.t("Hold to talk, or tap to lock")
        }
    }
}

/// Hold to record and release to stop; a short tap locks recording and a second tap stops it.
/// Tap versus hold uses Core's `RecordingGesture`, the same rule as the Mac shortcut.
struct RecordButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var gesture = RecordingGesture()
    @State private var pressed = false

    var body: some View {
        let recording = model.takeState == .recording
        ZStack {
            Circle()
                .fill(recording ? Color.red : Color.accentColor)
                .overlay(
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 10)
                        .scaleEffect(1 + model.level * 0.25)
                        .opacity(recording ? 1 : 0)
                )
            VStack(spacing: 8) {
                Image(systemName: recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 44, weight: .semibold))
                Text(verbatim: recording
                     ? (gesture.locked ? AppText.t("Tap to stop") : AppText.t("Release to stop"))
                     : AppText.t("Hold to talk"))
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
        }
        .frame(width: 200, height: 200)
        .scaleEffect(pressed ? 0.96 : 1)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .animation(.easeOut(duration: 0.1), value: model.level)
        .opacity(model.takeState == .processing ? 0.5 : 1)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    switch gesture.press(at: ProcessInfo.processInfo.systemUptime, idle: model.takeState == .idle) {
                    case .start: if !model.startTake() { gesture.reset() }
                    case .finish: model.stopTake()
                    case .none: break
                    }
                }
                .onEnded { _ in
                    pressed = false
                    let effect = gesture.release(at: ProcessInfo.processInfo.systemUptime,
                                                 active: model.takeState == .recording)
                    if effect == .finish { model.stopTake() }
                }
        )
        .onChange(of: model.takeState) { _, state in
            if state != .recording { gesture.reset() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppText.t(recording ? "Stop recording" : "Start recording"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if model.takeState == .recording { model.stopTake() } else if model.takeState == .idle { model.startTake() }
        }
    }
}

/// Ask anything: the hint and optional reference text for in-app takes. Keyboard takes send the host's selected
/// text instead, for that take only.
struct AskCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppText.t("Ask anything"), systemImage: WritingMode.ask.icon)
                .font(.headline)
            Text(verbatim: AppText.t("Speak a question. Make room for an idea."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: AppText.t("Reference text (optional)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            TextEditor(text: $model.askReference)
                .frame(minHeight: 88, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
                .disabled(model.busy)
                .accessibilityLabel(AppText.t("Reference text (optional)"))
            Text(verbatim: AppText.t("Sent to the writing model only as reference for your question. It is never saved or synced."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }
}

/// The latest result. An Ask anything answer is titled "Answer" with the spoken question above it; Copy copies
/// the answer only.
struct ResultCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let text = displayedText
        let question = model.shownQuestion
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: AppText.t(model.showsAnswer ? "Answer" : "Result")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.copy(text)
                } label: {
                    Label(AppText.t("Copy"), systemImage: "doc.on.doc")
                }
                .font(.caption.weight(.semibold))
                .disabled(text.isEmpty || model.takeState == .processing)
            }
            if !question.isEmpty, question != text {
                Text(verbatim: question)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(AppText.t("Question: {0}", question))
            }
            Text(verbatim: text.isEmpty ? AppText.t("Your text appears here.") : text)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private var displayedText: String {
        if !model.resultText.isEmpty { return model.resultText }
        if model.takeState != .idle { return model.transcript }
        return model.lastResult?.text ?? ""
    }
}

struct ListeningCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.listening }, set: { value in
                Task { await model.setListening(value) }
            })) {
                Label(AppText.t("Start standby now"), systemImage: model.listening ? "dot.radiowaves.left.and.right" : "mic.slash")
            }
            .tint(.red)
            Text(verbatim: model.device.standbyKeepsMicrophoneOpen
                 ? AppText.t("During standby the keyboard can start and stop takes without opening VoiceDraft. The microphone stays open, so the orange microphone indicator stays on. Audio outside a take is discarded and never sent. The keyboard also starts standby by itself after it opens VoiceDraft to record.")
                 : AppText.t("During standby the keyboard can start and stop takes without opening VoiceDraft. VoiceDraft stays resident in the background and opens the microphone only while you hold to talk, so the microphone indicator is off between takes. The keyboard also starts standby by itself after it opens VoiceDraft to record."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !model.device.standbyKeepsMicrophoneOpen {
                Text(verbatim: model.standbyWindowHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if model.listening, let endsAt = model.listeningEndsAt {
                Text(verbatim: AppText.t("Standby ends at {0}.", endsAt.formatted(.dateTime.hour().minute().locale(L10n.locale))))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }
}
