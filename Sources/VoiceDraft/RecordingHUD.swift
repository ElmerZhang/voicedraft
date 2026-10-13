import SwiftUI
import VoiceDraftCore

enum DictationHUDKind {
    case compact, live, result, failure
    var size: CGSize {
        switch self {
        case .compact: return CGSize(width: 250, height: 80)
        case .live: return CGSize(width: 520, height: 258)
        case .result: return CGSize(width: 520, height: 254)
        case .failure: return CGSize(width: 520, height: 302)
        }
    }
}

struct RecordingHUD: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 10) {
            switch state.hudKind {
            case .compact: capsule
            case .live:
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(state.recording ? Color.green : Color.white.opacity(0.5)).frame(width: 6, height: 6)
                        Text(state.recording ? D("Live transcript") : F("Writing result", "写作结果")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                        Spacer()
                        Text(state.recording ? D("Say corrections before finishing") : F("Streaming…", "生成中…")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                    ScrollViewReader { reader in
                        ScrollView {
                            Text(state.liveTranscript).font(.system(size: 15)).lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("tail")
                        }.frame(height: 105)
                            .onChange(of: state.liveTranscript) { _ in reader.scrollTo("tail", anchor: .bottom) }
                            .onAppear { reader.scrollTo("tail", anchor: .bottom) }
                    }
                }.padding(18).background(panelBackground, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.16)))
                capsule
            case .result, .failure: resultCard
            }
        }
        .padding(10).frame(width: state.hudKind.size.width, height: state.hudKind.size.height)
        .foregroundStyle(.white).preferredColorScheme(.dark).environment(\.locale, L10n.locale)
    }
    private var panelBackground: Color { Color(red: 0.085, green: 0.085, blue: 0.09).opacity(0.98) }
    private var capsule: some View {
        HStack(spacing: 17) {
            Button { state.dismissHUD() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 36).background(.white.opacity(0.20), in: Circle())
            }.buttonStyle(.plain).help(L("Cancel")).accessibilityLabel(L("Cancel"))
            Group {
                if state.recording {
                    VStack(spacing: 2) {
                        waveform
                        if state.recordingLocked { Text(F("Locked", "已锁定")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)) }
                    }
                }
                else if state.busy { ProgressView().controlSize(.small).tint(.white).frame(width: 76, height: 28) }
                else { Image(systemName: "checkmark").font(.system(size: 18, weight: .medium)).frame(width: 76, height: 28) }
            }.help(L(state.status))
            Button { state.finish() } label: {
                Image(systemName: "checkmark").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.black).frame(width: 36, height: 36)
                    .background(.white.opacity(state.recording ? 1 : 0.35), in: Circle())
            }.buttonStyle(.plain).disabled(!state.recording).help(D("Finish dictation")).accessibilityLabel(D("Finish dictation"))
        }
        .padding(.horizontal, 9).padding(.vertical, 8).background(panelBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.32), lineWidth: 1))
        .help(state.recordingDeviceName.isEmpty ? L(state.status) : L("Input: \(state.recordingDeviceName)") + String(format: " · %02d:%02d", Int(state.elapsed) / 60, Int(state.elapsed) % 60))
    }
    private var waveform: some View {
        TimelineView(.animation(minimumInterval: 0.10)) { time in
            HStack(spacing: 4) {
                ForEach(0..<11) { index in
                    let variation = 0.4 + 0.6 * abs(sin(time.date.timeIntervalSinceReferenceDate * 5 + Double(index) * 0.9))
                    Capsule().fill(.white).frame(width: 3, height: 3 + 23 * state.level * variation)
                }
            }.frame(width: 76, height: 28)
        }.accessibilityLabel(L("Listening · speak naturally"))
    }
    private var resultCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 11) {
                Image(systemName: state.hudKind == .failure ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(state.hudKind == .failure ? .orange : Color(red: 0.4, green: 0.55, blue: 1))
                Text(state.hudKind == .failure ? D("Could not finish") : D("Copy last transcript"))
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { state.dismissHUD() } label: { Image(systemName: "xmark").font(.system(size: 15)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).help(D("Dismiss")).accessibilityLabel(D("Dismiss"))
            }
            if state.hudKind == .failure || !state.error.isEmpty {
                Text(L(state.error)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                Text(state.hudText).font(.system(size: 15)).lineSpacing(5)
                    .foregroundStyle(.white.opacity(0.83)).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack {
                Spacer()
                if !state.hudText.isEmpty {
                    Button { state.copyHUDResult() } label: {
                        Label(state.hudCopied ? L("Copied") : L("Copy"), systemImage: state.hudCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
                if state.hudKind == .failure {
                    Button { state.page = "Studio"; state.showMain?(); state.dismissHUD() } label: {
                        Text(L("Open VoiceDraft")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
        }.padding(23).background(panelBackground, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.24)))
    }
}
