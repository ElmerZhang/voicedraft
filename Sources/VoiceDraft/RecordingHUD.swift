import SwiftUI
import VoiceDraftCore

enum DictationHUDKind {
    case compact, live, result, failure
    var size: CGSize {
        switch self {
        case .compact: return CGSize(width: 250, height: 76)
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
                liveCard
                capsule
            case .result, .failure: resultCard
            }
        }
        .padding(10).frame(width: state.hudKind.size.width, height: state.hudKind.size.height)
        // The panel frame animates between kinds; keep the content anchored to the bottom edge
        // so the capsule stays in place while a card grows upward.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottom)
        .foregroundStyle(.white).preferredColorScheme(.dark).environment(\.locale, L10n.locale)
    }

    // MARK: Compact capsule

    private var capsule: some View {
        HStack(spacing: 14) {
            Button { state.dismissHUD() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36).background(.white.opacity(0.16), in: Circle())
                    .contentShape(Circle())
            }.buttonStyle(.plain).help(L("Cancel")).accessibilityLabel(L("Cancel"))
            centre.frame(width: 96, height: 36).help(L(state.status))
            Button { state.finish() } label: {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black).frame(width: 36, height: 36)
                    .background(.white.opacity(state.recording ? 1 : 0.35), in: Circle())
                    .contentShape(Circle())
            }.buttonStyle(.plain).disabled(!state.recording).help(D("Finish dictation")).accessibilityLabel(D("Finish dictation"))
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .hudChrome(Capsule())
        .help(state.recordingDeviceName.isEmpty ? L(state.status) : L("Input: \(state.recordingDeviceName)") + " · " + elapsedText)
    }

    @ViewBuilder private var centre: some View {
        if state.recording {
            VStack(spacing: 3) {
                waveform
                HStack(spacing: 3) {
                    if state.recordingLocked { Image(systemName: "lock.fill").font(.system(size: 8, weight: .semibold)) }
                    Text(elapsedText).font(.system(size: 10, weight: .medium).monospacedDigit())
                }.foregroundStyle(.white.opacity(0.7)).accessibilityHidden(true)
            }
        } else if state.busy {
            VStack(spacing: 4) {
                ProgressView().controlSize(.small).frame(width: 16, height: 16).tint(.white)
                Text(state.phase == "starting" ? D("Starting…") : D("Processing…"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.8)
            }.accessibilityElement(children: .combine)
        } else {
            Image(systemName: "checkmark").font(.system(size: 18, weight: .medium))
        }
    }

    private var waveform: some View {
        TimelineView(.animation(minimumInterval: 0.10)) { time in
            HStack(spacing: 4) {
                ForEach(0..<11) { index in
                    let variation = 0.4 + 0.6 * abs(sin(time.date.timeIntervalSinceReferenceDate * 5 + Double(index) * 0.9))
                    Capsule().fill(.white).frame(width: 3, height: 3 + 17 * state.level * variation)
                }
            }.frame(width: 76, height: 20)
        }
        .accessibilityElement()
        .accessibilityLabel(([D("Recording")] + (state.recordingLocked ? [D("Locked")] : []) + [elapsedText]).joined(separator: " · "))
    }

    private var elapsedText: String {
        let seconds = max(0, Int(state.elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Cards

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(state.recording ? VD.Palette.recording : Color.white.opacity(0.5)).frame(width: 6, height: 6)
                Text(state.recording ? D("Live transcript") : D("Writing result")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text(state.recording ? D("Say corrections before finishing") : D("Streaming…")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
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
        }.padding(18).hudChrome(RoundedRectangle(cornerRadius: VD.Radius.panel, style: .continuous))
    }

    private var resultCard: some View {
        let failure = state.hudKind == .failure
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: failure ? "exclamationmark.circle.fill" : "doc.on.clipboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(failure ? VD.Palette.warning : VD.Palette.accent)
                Text(failure ? D("Could not finish") : D("Result ready")).font(.system(size: 16, weight: .semibold))
                Spacer()
                VDIconButton(systemName: "xmark", label: D("Dismiss"), tint: .white.opacity(0.6)) { state.dismissHUD() }
                    .padding(.trailing, -6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if failure || !state.error.isEmpty {
                        Text(L(state.error)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(state.hudText).font(.system(size: 15)).lineSpacing(5).foregroundStyle(.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack(spacing: 16) {
                Spacer()
                if !state.hudText.isEmpty {
                    Button { state.copyHUDResult() } label: {
                        Label(state.hudCopied ? L("Copied") : L("Copy"), systemImage: state.hudCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .medium)).padding(.horizontal, 18).padding(.vertical, 8)
                            .background(.white.opacity(0.13), in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
                if failure {
                    Button { state.page = "Studio"; state.showMain?(); state.dismissHUD() } label: {
                        // Same height as the Copy pill; the padding is hittable but has no fill.
                        Text(L("Open VoiceDraft")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
        }.padding(20).hudChrome(RoundedRectangle(cornerRadius: VD.Radius.panel, style: .continuous))
    }
}

private extension View {
    /// Dark floating-panel chrome: `hudPanel` over a thin material with a white hairline.
    func hudChrome<S: InsettableShape>(_ shape: S) -> some View {
        background(ZStack { Rectangle().fill(.ultraThinMaterial); VD.Palette.hudPanel.opacity(0.9) }.clipShape(shape))
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}
