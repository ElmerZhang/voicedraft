import SwiftUI
import VoiceDraftCore

/// Placeholder home screen. Recording is not implemented yet; the button only reflects press state.
struct ContentView: View {
    @State private var isHolding = false
    @State private var lastResult: SharedResult?
    @Environment(\.scenePhase) private var scenePhase

    private let store = SharedResultStore()

    var body: some View {
        VStack(spacing: 32) {
            Text("VoiceDraft")
                .font(.largeTitle.bold())

            Text(isHolding ? "Recording (placeholder)" : "Idle")
                .font(.headline)
                .foregroundStyle(isHolding ? .red : .secondary)

            Text(isHolding ? "Release to stop" : "Hold to record")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 220, height: 220)
                .background(Circle().fill(isHolding ? Color.red : Color.accentColor))
                .scaleEffect(isHolding ? 1.05 : 1)
                .animation(.easeOut(duration: 0.15), value: isHolding)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isHolding = true }
                        .onEnded { _ in isHolding = false }
                )
                .accessibilityAddTraits(.isButton)

            VStack(alignment: .leading, spacing: 8) {
                Text("Last shared result")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(lastResult?.text ?? "No result yet")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            // Exercises the VoiceDraftCore link until the real pipeline is wired in.
            Text("Settings schema v\(SharedSettings().schemaVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
    }

    private func reload() {
        lastResult = store.read()
    }
}

#Preview {
    ContentView()
}
