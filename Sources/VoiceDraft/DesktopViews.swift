import SwiftUI
import AppKit
import VoiceDraftCore

private enum DesktopTheme {
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let muted = Color(red: 0.48, green: 0.48, blue: 0.50)
    static let surface = Color(red: 0.967, green: 0.967, blue: 0.970)
    static let line = Color.black.opacity(0.065)
    static let blue = Color(red: 0.15, green: 0.34, blue: 0.96)
}

struct DesktopRootView: View {
    @ObservedObject var state: AppState
    @State private var returnPage = "Studio"
    @State private var settingsTab = "Settings"
    private var settingsOpen: Bool { state.page == "Settings" }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                HStack(spacing: 0) {
                    sidebar
                    VStack(spacing: 0) {
                        if !state.error.isEmpty { feedback() }
                        ScrollView {
                            Group {
                                switch settingsOpen ? returnPage : state.page {
                                case "History": DesktopHistoryView(state: state)
                                case "Vocabulary": DesktopDictionaryView(state: state)
                                case "Models": ModelsView(state: state)
                                case "Sync": SyncView(state: state)
                                default: DesktopHomeView(state: state)
                                }
                            }
                            .frame(maxWidth: 1260, alignment: .leading)
                            .padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 36)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        if !state.notice.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(DesktopTheme.blue)
                                Text(L(state.notice)).foregroundStyle(.secondary)
                                Spacer()
                                Button { state.notice = "" } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).help(D("Dismiss"))
                            }.font(.caption).padding(.horizontal, 30).padding(.vertical, 10)
                        }
                    }.background(.white)
                }.disabled(settingsOpen).allowsHitTesting(!settingsOpen).accessibilityHidden(settingsOpen)
                if settingsOpen {
                    Color.black.opacity(0.36).ignoresSafeArea()
                    DesktopSettingsView(state: state, tab: $settingsTab, close: closeSettings)
                        .frame(width: min(1040, geometry.size.width - 80), height: geometry.size.height - 64)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
                        .onExitCommand(perform: closeSettings)
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 740)
        .background(.white).foregroundStyle(DesktopTheme.ink).tint(DesktopTheme.blue)
        .preferredColorScheme(.light).environment(\.locale, L10n.locale)
        .sheet(isPresented: $state.showingOnboarding) { OnboardingView(state: state) }
        .onReceive(NotificationCenter.default.publisher(for: .voiceDraftOpenSettings)) { _ in openSettings() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 25, weight: .bold))
                Text("VoiceDraft").font(.system(size: 23, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.top, 25)
            VStack(spacing: 5) {
                navigation("Studio", title: D("Home"), icon: "house")
                navigation("History", title: L("History"), icon: "clock.arrow.circlepath")
                navigation("Vocabulary", title: D("Dictionary"), icon: "book.closed")
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 13) {
                Label(D("Made for your words"), systemImage: "waveform").font(.system(size: 14, weight: .semibold))
                Text(D("Your models. Your vocabulary. A little less typing."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(17).background(.white, in: RoundedRectangle(cornerRadius: 20))
            HStack {
                footerButton("slider.horizontal.3", title: D("Settings")) { openSettings() }
                Spacer()
                footerButton("arrow.triangle.2.circlepath", title: L("Sync")) { openSettings(tab: "Sync") }
                Spacer()
                footerButton("info.circle", title: D("About")) { openSettings(tab: "About") }
                Spacer()
                footerButton("questionmark.circle", title: D("Help")) { openSettings(tab: "Help") }
            }.padding(.horizontal, 9).padding(.top, 16).overlay(alignment: .top) { Rectangle().fill(DesktopTheme.line).frame(height: 1) }
        }
        .padding(16).frame(width: 222).frame(maxHeight: .infinity)
        .background(DesktopTheme.surface, in: RoundedRectangle(cornerRadius: 26)).padding(10)
    }

    private func navigation(_ page: String, title: String, icon: String) -> some View {
        Button { state.page = page } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
                Text(title).font(.system(size: 16, weight: .medium))
                Spacer()
            }.padding(.horizontal, 13).padding(.vertical, 13)
                .background((settingsOpen ? returnPage : state.page) == page ? Color.black.opacity(0.07) : .clear,
                            in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain)
    }

    private func footerButton(_ icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 18)).frame(width: 28, height: 28) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(title).accessibilityLabel(title)
    }

    private func feedback() -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.circle")
            Text(L(state.error)).textSelection(.enabled)
            Spacer()
            Button { state.error = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(D("Dismiss"))
        }.font(.callout).foregroundStyle(.red).padding(14).background(Color.red.opacity(0.05))
    }

    private func openSettings(tab: String = "Settings") {
        if !settingsOpen { returnPage = state.page }
        NSApp.keyWindow?.makeFirstResponder(nil)
        settingsTab = tab; state.page = "Settings"
    }
    private func closeSettings() { state.page = returnPage }
}

extension Notification.Name {
    static let voiceDraftOpenSettings = Notification.Name("VoiceDraft.openSettings")
}

private struct DesktopTitle: View {
    let title: String
    var body: some View { Text(title).font(.system(size: 40, weight: .bold)).tracking(-1.2) }
}

private struct DesktopSurface<Content: View>: View {
    var shaded = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(shaded ? DesktopTheme.surface : .white, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(DesktopTheme.line))
    }
}

private struct KeyCaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                Text(key).font(.system(size: 15, weight: .semibold)).frame(minWidth: 22)
                    .padding(.horizontal, 7).padding(.vertical, 7)
                    .background(LinearGradient(colors: [.white, Color(white: 0.965)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black.opacity(0.19)))
            }
        }.fixedSize()
    }
}

private struct DesktopHomeView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(D("Speak, don't type.")).font(.system(size: 48, weight: .bold)).tracking(-1.8)
                .minimumScaleFactor(0.8).lineLimit(1)
            HStack(alignment: .top, spacing: 22) {
                VStack(spacing: 0) {
                    shortcut(.polish, title: D("Dictate"), detail: D("Messy thoughts → clear writing"), key: "Space")
                    Divider().padding(.horizontal, 20)
                    shortcut(.translate, title: L("Translate"), detail: D("Your voice, in another language"), key: "T")
                    Divider().padding(.horizontal, 20)
                    shortcut(.ask, title: D("Ask anything"), detail: D("Speak a question. Make room for an idea."), key: "A")
                }.background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(DesktopTheme.line))
                    .padding(10).background {
                        ZStack {
                            LinearGradient(colors: [Color(red: 0.94, green: 0.97, blue: 0.98), Color(red: 0.96, green: 0.95, blue: 0.99)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            Canvas { context, size in
                                for x in stride(from: 6.0, to: size.width, by: 10) {
                                    for y in stride(from: 6.0, to: size.height, by: 10) {
                                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.black.opacity(0.10)))
                                    }
                                }
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 30))
                    }
                DesktopSurface(shaded: true) {
                    stat("clock", value: "\(Int(state.history.reduce(0) { $0 + $1.duration }) / 60)", label: D("minutes recorded"))
                    stat("text.bubble", value: "\(state.history.count)", label: D("saved entries"))
                    stat("book.closed", value: "\(state.settings.vocabulary.entries.filter(\.enabled).count)", label: D("active terms"))
                    Text(D("Based on history on this Mac.")).font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(width: 190).padding(.top, 10)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(D("Try it here")).font(.system(size: 23, weight: .bold))
                Spacer()
                Label(D("Your testing workspace"), systemImage: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            StudioView(showsHeading: false, state: state)
            Text(D("Make it part of your day")).font(.system(size: 23, weight: .bold)).padding(.top, 8)
            HStack(alignment: .top, spacing: 14) {
                useCase("envelope", title: D("Emails & messages"), detail: D("Turn a quick thought into a clear message."), tint: .blue)
                useCase("doc.text", title: D("Notes & documents"), detail: D("Capture ideas while they are still fresh."), tint: .green)
                useCase("sparkles", title: D("Ideas & answers"), detail: D("Ask, explore, and refine with your writing model."), tint: .orange)
            }
        }
    }
    private func shortcut(_ mode: WritingMode, title: String, detail: String, key: String) -> some View {
        Button { state.mode = mode } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(state.shortcutLabel(mode == .translate ? .translate : mode == .ask ? .ask : .dictate)).font(.system(.caption, design: .monospaced))
            }.padding(.horizontal, 20).padding(.vertical, 18).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(state.busy).help(D("Choose a mode in the testing workspace"))
    }
    private func stat(_ icon: String, value: String, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 22, weight: .bold))
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private func useCase(_ icon: String, title: String, detail: String, tint: Color) -> some View {
        DesktopSurface {
            Image(systemName: icon).font(.system(size: 27)).foregroundStyle(tint).frame(height: 32)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).frame(minHeight: 50, alignment: .top)
        }
    }
}

private struct FilterPills: View {
    let labels: [String]
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(labels.indices, id: \.self) { index in
                Button { selection = index } label: {
                    Text(labels[index]).font(.system(size: 13, weight: selection == index ? .medium : .regular))
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .background(selection == index ? .white : .clear, in: Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == index ? [.isSelected] : [])
            }
        }.padding(5).background(Color(white: 0.945), in: Capsule())
    }
}

private struct DesktopDictionaryView: View {
    @ObservedObject var state: AppState
    @State private var query = ""
    @State private var filter = 0
    @State private var statusFilter = 0
    @State private var editing: VocabularyEntry?
    @State private var bulkOpen = false
    @State private var words = ""
    private var entries: [VocabularyEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.settings.vocabulary.entries.filter {
            (filter == 0 || (filter == 1 ? $0.origin == .automatic : $0.origin == .manual)) &&
            (statusFilter == 0 || (statusFilter == 1 ? $0.enabled : !$0.enabled)) &&
            (term.isEmpty || $0.text.localizedCaseInsensitiveContains(term) || $0.aliases.contains { $0.localizedCaseInsensitiveContains(term) })
        }.sorted {
            if $0.priority != $1.priority { return $0.priority }
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            return $0.text.localizedStandardCompare($1.text) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                DesktopTitle(title: D("Dictionary"))
                Spacer()
                Button { editing = VocabularyEntry() } label: {
                    Text(D("New word")).font(.system(size: 14, weight: .medium)).padding(.horizontal, 20).padding(.vertical, 12)
                        .foregroundStyle(.white).background(DesktopTheme.ink, in: Capsule())
                }.buttonStyle(.plain)
            }
            DictionaryFileControls(state: state)
            HStack(spacing: 16) {
                FilterPills(labels: [D("All"), D("Auto-added"), D("Manually-added")], selection: $filter)
                Spacer()
                Picker(D("Word status"), selection: $statusFilter) {
                    Text(D("All statuses")).tag(0)
                    Text(L("Enabled")).tag(1)
                    Text(D("Disabled")).tag(2)
                }.labelsHidden().frame(width: 120)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                SingleLineField(L("Search vocabulary"), text: $query).frame(width: 200)
            }
            if entries.isEmpty {
                emptyState(icon: "book.closed", title: query.isEmpty && filter == 0 && statusFilter == 0 ? L("Add names, products, or phrases you often say.") : D("No matching words"))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in
                        Button { editing = entry } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.origin == .automatic ? "sparkle" : "leaf.fill")
                                    .foregroundStyle(entry.origin == .automatic ? Color.teal : Color.gray.opacity(0.65)).font(.system(size: 13))
                                    .accessibilityLabel(entry.origin == .automatic ? D("Auto-added") : D("Manually-added"))
                                Text("\(entry.useCount)").font(.caption).foregroundStyle(.secondary).help(F("Uses", "使用次数"))
                                Text(entry.text).font(.system(size: 15)).lineLimit(1)
                                Spacer(minLength: 0)
                                if entry.priority { Image(systemName: "star.fill").foregroundStyle(.orange) }
                                if !entry.enabled { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                            }.padding(.horizontal, 16).padding(.vertical, 16).contentShape(Rectangle())
                                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesktopTheme.line))
                        }.buttonStyle(.plain).help(entry.text)
                            .contextMenu {
                                Button(L("Edit")) { editing = entry }
                                Button(entry.enabled ? D("Disable word") : D("Enable word")) {
                                    update { vocabulary in
                                        if let i = vocabulary.entries.firstIndex(where: { $0.id == entry.id }) { vocabulary.entries[i].enabled.toggle() }
                                    }
                                }
                                Button(L("Delete term"), role: .destructive) { update { $0.removeEntry(entry.id) } }
                            }
                    }
                }
            }
            HStack {
                Toggle(L("Enable app vocabulary"), isOn: Binding(get: { state.settings.vocabulary.enabled }, set: { enabled in update { $0.enabled = enabled } }))
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button(L("Add several terms")) { bulkOpen = true }.buttonStyle(.borderless)
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
            VStack(alignment: .leading, spacing: 12) {
                Toggle(D("Learn from corrections"), isOn: Binding(get: { state.settings.vocabulary.learnFromCorrections }, set: { value in update { $0.learnFromCorrections = value } }))
                Toggle(D("Discover words from dictation"), isOn: Binding(get: { state.settings.vocabulary.discoverFromDictation }, set: { value in update { $0.discoverFromDictation = value } }))
                Text(D("Learns names and specialist terms using your writing model after dictation. Corrections are added directly; discovered words need two separate takes while the app is open."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(D("For 45 seconds after insertion, supported editors can learn from changes to your dictated text. Other document text is not sent. Deleted words stay excluded from automatic learning."))
                    .font(.caption).foregroundStyle(.secondary)
                if !state.vocabularyLearningStatus.isEmpty {
                    Text(state.vocabularyLearningStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.toggleStyle(.switch).controlSize(.small).padding(18)
                .background(DesktopTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            DisclosureGroup(D("Model vocabulary details")) {
                VStack(alignment: .leading, spacing: 16) {
                    if let speech = state.settings.speech { VocabularyProjectionView(vocabulary: state.settings.vocabulary, profile: speech) }
                    ForEach(state.settings.vocabulary.legacyReferences.indices, id: \.self) { i in
                        let reference = state.settings.vocabulary.legacyReferences[i]
                        Text("\(reference.model) · \(reference.resourceID)").font(.caption).textSelection(.enabled)
                    }
                }.padding(.top, 12)
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            Text(L("Vocabulary and preferences are included in encrypted sync.")).font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { entry in
            VocabularyEntryEditor(entry: entry, save: { value in
                update { vocabulary in
                    if let i = vocabulary.entries.firstIndex(where: { $0.id == value.id }) { vocabulary.entries[i] = value }
                    else { vocabulary.entries.append(value) }
                }
            }, saveError: { state.error.isEmpty ? nil : L(state.error) })
        }
        .sheet(isPresented: $bulkOpen) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Add several terms")).font(.title2.bold())
                Text(L("One word or phrase per line. Existing terms are kept.")).foregroundStyle(.secondary)
                TextEditor(text: $words).frame(height: 190).border(DesktopTheme.line)
                HStack {
                    Spacer()
                    Button(L("Cancel")) { bulkOpen = false }
                    Button(L("Add to vocabulary")) {
                        update { $0.appendLines(words) }
                        if state.error.isEmpty { words = ""; bulkOpen = false }
                    }.buttonStyle(.borderedProminent).disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !state.error.isEmpty { Text(L(state.error)).foregroundStyle(.red) }
            }.padding(28).frame(width: 520)
        }
    }
    private func update(_ change: (inout AppVocabulary) -> Void) {
        var copy = state.settings; change(&copy.vocabulary); state.save(copy)
    }
}

private func emptyState(icon: String, title: String) -> some View {
    VStack(spacing: 15) {
        Image(systemName: icon).font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
        Text(title).font(.system(size: 15)).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity).padding(.vertical, 65)
}

private struct DesktopHistoryView: View {
    @ObservedObject var state: AppState
    @State private var query = ""
    @State private var filter = 0
    @State private var confirmClear = false
    @State private var expanded: Set<UUID> = []
    private var entries: [HistoryEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.history.filter {
            (filter == 0 || (filter == 2 ? $0.mode == .ask : $0.mode != .ask)) &&
            (term.isEmpty || $0.result.localizedCaseInsensitiveContains(term) || $0.original.localizedCaseInsensitiveContains(term))
        }.sorted { $0.date > $1.date }
    }
    private var days: [Date] { Set(entries.map { Calendar.current.startOfDay(for: $0.date) }).sorted(by: >) }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                DesktopTitle(title: L("History"))
                Spacer()
                Label(D("Only on this Mac"), systemImage: "internaldrive").font(.system(size: 13)).foregroundStyle(.secondary)
                Menu {
                    Button(L("Clear history…"), role: .destructive) { confirmClear = true }.disabled(state.history.isEmpty)
                } label: { Image(systemName: "ellipsis").font(.title3).frame(width: 28) }.menuStyle(.borderlessButton).fixedSize().help(L("Clear history…"))
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(D("Keep history"), systemImage: "internaldrive").font(.system(size: 15, weight: .semibold))
                        Text(F("Keep history for your chosen retention period.", "按设置的期限保留历史。")).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(L("Save future transcripts on this Mac"), isOn: Binding(get: { state.device.keepHistory }, set: { state.saveDevice(autoPaste: state.device.autoPaste, history: $0) }))
                        .labelsHidden().toggleStyle(.switch).help(L("Save future transcripts on this Mac"))
                }
                Divider()
                Label(D("Your history stays on your device"), systemImage: "lock").font(.system(size: 15, weight: .semibold))
                Text(F("History and retained recordings stay on this Mac. Manage audio retention in Settings.", "历史与保留的录音只存储在本机。可在设置中管理录音保存和保留期限。"))
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(22).background(DesktopTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            HStack {
                FilterPills(labels: [D("All"), D("Dictations"), D("Ask anything")], selection: $filter)
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                SingleLineField(L("Search your words"), text: $query).frame(width: 190)
            }
            if entries.isEmpty {
                emptyState(icon: "clock.arrow.circlepath", title: state.history.isEmpty ? L("Your words will find a home here.") : D("No matching entries"))
            }
            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: 12) {
                    Text(dayTitle(day)).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    LazyVStack(spacing: 0) {
                        let group = entries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            historyRow(entry)
                        }
                    }.background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DesktopTheme.line))
                }
            }
        }.confirmationDialog(L("Delete all local history?"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("Delete history"), role: .destructive) { state.deleteHistory() }
        }
    }
    private func historyRow(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Text(entry.date.formatted(.dateTime.hour().minute().locale(L10n.locale))).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                Text(entry.result).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    Button { if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) } } label: {
                        Image(systemName: expanded.contains(entry.id) ? "chevron.up" : "chevron.down")
                    }.help(D("Show details"))
                    Button { state.copyResult(entry.result) } label: { Image(systemName: "doc.on.doc") }.help(L("Copy"))
                    Button(role: .destructive) { state.deleteHistory(entry.id) } label: { Image(systemName: "trash") }.help(L("Delete history entry"))
                }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain)
            }
            if expanded.contains(entry.id) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if entry.audioID != nil {
                            Button(state.playingAudioID == entry.audioID ? F("Stop audio", "停止播放") : F("Play audio", "播放录音")) { state.play(entry) }
                            Button(F("Transcribe again", "重新识别")) { state.reprocess(entry, transcribeAgain: true) }
                        }
                        Button(F("Rewrite transcript", "重新处理文字")) { state.reprocess(entry, transcribeAgain: false) }
                        Text(F("Uses current models and style", "使用当前模型和风格")).font(.caption).foregroundStyle(.secondary)
                    }.disabled(state.busy)
                    Label("\(entry.mode.title) · \(entry.application)", systemImage: entry.mode.icon).font(.caption).foregroundStyle(.secondary)
                    if entry.original != entry.result {
                        Text(L("Original transcript")).font(.caption.weight(.semibold))
                        Text(entry.original).font(.system(size: 13)).textSelection(.enabled)
                    }
                }.padding(.leading, 86)
            }
        }.padding(17)
    }
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return D("Today") }
        if Calendar.current.isDateInYesterday(day) { return D("Yesterday") }
        return day.formatted(.dateTime.year().month(.wide).day().locale(L10n.locale))
    }
}

private struct DesktopSettingsView: View {
    @ObservedObject var state: AppState
    @Binding var tab: String
    let close: () -> Void
    private let tabs = [("Settings", "gearshape"), ("Personalization", "pencil.and.outline"), ("Models", "cpu"),
                        ("Sync", "arrow.triangle.2.circlepath"), ("About", "info.circle"), ("Help", "questionmark.circle")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tabs, id: \.0) { name, icon in
                    Button { tab = name } label: {
                        HStack(spacing: 11) {
                            Image(systemName: icon).frame(width: 20)
                            Text(title(name)).font(.system(size: 14))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 12).padding(.vertical, 12)
                            .background(tab == name ? Color.black.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(14).padding(.top, 20).frame(width: 195).background(DesktopTheme.surface)
            VStack(spacing: 0) {
                HStack {
                    Text(title(tab)).font(.system(size: 26, weight: .bold))
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 14)).frame(width: 28, height: 28) }
                        .keyboardShortcut(.cancelAction).buttonStyle(.plain).foregroundStyle(.secondary).help(D("Close settings")).accessibilityLabel(D("Close settings"))
                }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
                if !state.error.isEmpty {
                    Text(L(state.error)).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 30).padding(.bottom, 12)
                }
                ScrollView {
                    Group {
                        switch tab {
                        case "Models": ModelsView(state: state)
                        case "Sync": SyncView(state: state)
                        case "Personalization": DesktopPersonalizationView(state: state)
                        case "About": about
                        case "Help": help
                        default: general
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 30).padding(.bottom, 30)
                }
                if !state.notice.isEmpty {
                    Text(L(state.notice)).font(.caption).foregroundStyle(DesktopTheme.blue).padding(12)
                }
            }
        }
    }
    private func title(_ name: String) -> String {
        switch name {
        case "Models", "Sync": return L10n.text(name)
        default: return D(name)
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 30) {
            settingsSection(D("Shortcuts"), icon: "keyboard") { ShortcutPreferences(state: state) }
            RecordingPreferences(state: state)
            UpdatePreferences(state: state)
            settingsSection(D("Language"), icon: "globe") {
                settingsRow(L("Interface language"), detail: D("Choose the language used in VoiceDraft.")) {
                    Picker(L("Interface language"), selection: Binding(get: { state.interfaceLanguage }, set: { state.setLanguage($0) })) {
                        ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                    }.labelsHidden().frame(width: 190).disabled(state.busy)
                }
                settingsRow(L("Translation target language"), detail: state.settings.targetLanguage) {
                    Button(L("Edit")) { tab = "Personalization" }
                }
            }
            settingsSection(D("Audio"), icon: "mic") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Input device")).font(.system(size: 14, weight: .medium))
                    HStack {
                        Picker(L("Input device"), selection: Binding(get: { state.device.inputDeviceID ?? "" }, set: { state.selectInputDevice($0) })) {
                            let defaultName = state.inputDevices.first { $0.id == state.defaultInputID }?.name
                            Text(defaultName.map { L("System default — \($0)") } ?? L("System default")).tag("")
                            ForEach(state.inputDevices) { input in Text(input.name).tag(input.id) }
                            if let saved = state.device.inputDeviceID, !state.inputDevices.contains(where: { $0.id == saved }) {
                                Text(L("Unavailable: \(state.device.inputDeviceName ?? saved)")).tag(saved)
                            }
                        }.labelsHidden()
                        Button { state.refreshInputDevices() } label: { Image(systemName: "arrow.clockwise") }.help(L("Refresh devices"))
                    }.disabled(state.busy)
                }
            }
            settingsSection(D("General"), icon: "laptopcomputer") {
                settingsRow(D("Automatic insertion"), detail: L("Insert into the original app after recording")) {
                    Toggle(L("Insert into the original app after recording"), isOn: Binding(get: { state.device.autoPaste }, set: { state.saveDevice(autoPaste: $0, history: state.device.keepHistory) })).labelsHidden().toggleStyle(.switch)
                }
                settingsRow(D("Keep history"), detail: L("Save future transcripts on this Mac")) {
                    Toggle(L("Save future transcripts on this Mac"), isOn: Binding(get: { state.device.keepHistory }, set: { state.saveDevice(autoPaste: state.device.autoPaste, history: $0) })).labelsHidden().toggleStyle(.switch)
                }
                settingsRow(D("Accessibility"), detail: L("Allow Accessibility for insertion. Microphone permission is requested when you record.")) {
                    Button(L("Allow Accessibility")) { TextInsertion.requestAccess() }
                }
            }
        }
    }
    private func shortcutRow(_ title: String, detail: String, key: String) -> some View {
        settingsRow(title, detail: detail) { KeyCaps(keys: ["⌃", "⌥", key]) }
    }
    private func settingsSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            Divider()
            content()
        }
    }
    private func settingsRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control().controlSize(.large)
        }.padding(.bottom, 6)
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "waveform").font(.system(size: 42, weight: .bold)).foregroundStyle(DesktopTheme.blue)
            Text("VoiceDraft").font(.system(size: 30, weight: .bold, design: .rounded))
            Text(F("Version ", "版本 ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")).font(.caption).foregroundStyle(.secondary)
            Text(D("Your models. Your vocabulary. A little less typing.")).font(.title3)
            DesktopSurface(shaded: true) {
                Label(L("Your models. Your words."), systemImage: "lock.shield").font(.headline)
                Text(F("The sync server stores encrypted settings. Model calls go directly to your configured providers; history and retained audio stay on this Mac.", "同步服务器只保存加密配置。模型调用直接发送到你配置的服务商；历史和保留的录音留在本机。"))
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
            }
        }.padding(.top, 14)
    }
    private var help: some View {
        VStack(alignment: .leading, spacing: 22) {
            DesktopSurface(shaded: true) {
                Text(D("Start with your models")).font(.headline)
                Text(F("Choose speech and writing services using your own credentials.", "使用自己的凭证，独立选择语音识别与写作服务。"))
                    .font(.callout).foregroundStyle(.secondary)
                Button(L("Models")) { tab = "Models" }
            }
            DesktopSurface {
                Text(D("Try it here")).font(.headline)
                Text(L("Or type here to test your writing model.")).font(.callout).foregroundStyle(.secondary)
                Button(D("Home")) { close(); state.page = "Studio" }
            }
            DesktopSurface {
                Text(L("Make room for your voice")).font(.headline)
                Text(L("Allow Accessibility for insertion. Microphone permission is requested when you record.")).font(.callout).foregroundStyle(.secondary)
                Button(L("Allow Accessibility")) { TextInsertion.requestAccess() }
            }
        }
    }
}

private struct DesktopPersonalizationView: View {
    @ObservedObject var state: AppState
    @State private var style = ""
    @State private var language = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StyleLibraryView(state: state)
            Divider()
            Text(L("Your writing style")).font(.system(size: 16, weight: .semibold))
            TextEditor(text: $style).font(.body).frame(height: 180).padding(10)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.line))
            Text(L("Translation target language")).font(.system(size: 16, weight: .semibold))
            SingleLineField(L("Translation target language"), text: $language)
            Text(L("Vocabulary and preferences are included in encrypted sync.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Save preferences")) {
                    var copy = state.settings; copy.stylePrompt = style; copy.targetLanguage = language; state.save(copy)
                }.buttonStyle(.borderedProminent)
            }
        }.onAppear { style = state.settings.stylePrompt; language = state.settings.targetLanguage }
    }
}
