import SwiftUI
import VoiceDraftCore

/// Local history, newest first. Tap copies the result; swipe deletes. Never synced.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView {
                        Label(AppText.t("No history yet"), systemImage: "clock")
                    } description: {
                        Text(verbatim: model.device.keepHistory
                             ? AppText.t("Finished takes are kept on this iPhone only.")
                             : AppText.t("History is turned off in Settings."))
                    }
                } else {
                    List {
                        MessageBanner().listRowSeparator(.hidden)
                        ForEach(model.history) { entry in
                            Button { model.copy(entry.result) } label: { HistoryRow(entry: entry) }
                                .buttonStyle(.plain)
                                .accessibilityHint(AppText.t("Copies the result"))
                        }
                        .onDelete { offsets in
                            for id in offsets.map({ model.history[$0].id }) { model.deleteHistory(id) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(Text(verbatim: AppText.t("History")))
            .toolbar {
                if !model.history.isEmpty {
                    Button(AppText.t("Clear"), role: .destructive) { confirmingClear = true }
                }
            }
            .confirmationDialog(AppText.t("Delete all history on this iPhone?"), isPresented: $confirmingClear,
                                titleVisibility: .visible) {
                Button(AppText.t("Delete all"), role: .destructive) { model.clearHistory() }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(entry.mode.title, systemImage: entry.mode.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.date.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: entry.result).lineLimit(4)
            if entry.original != entry.result, !entry.original.isEmpty {
                Text(verbatim: entry.original).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
