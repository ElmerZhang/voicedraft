import SwiftUI
import AppKit
import VoiceDraftCore

/// Main window shell: floating sidebar, the three main pages and the in-window settings overlay.
/// Only Home ("Studio"), History and Vocabulary are pages. `AppState.page == "Settings"` opens the overlay on
/// `AppState.settingsTab`; the legacy page names "Models" and "Sync" are normalized to that overlay.
struct DesktopRootView: View {
    @ObservedObject var state: AppState
    @State private var returnPage = "Studio"
    private static let mainPages: Set<String> = ["Studio", "History", "Vocabulary"]
    private static let settingsPages: Set<String> = ["Settings", "Models", "Sync"]
    private var settingsOpen: Bool { Self.settingsPages.contains(state.page) }
    private var visiblePage: String {
        if settingsOpen { return returnPage }
        return Self.mainPages.contains(state.page) ? state.page : "Studio"
    }
    private var settingsTab: Binding<String> {
        Binding(get: { state.page == "Models" || state.page == "Sync" ? state.page : state.settingsTab },
                set: { tab in state.openSettings(tab) })
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                HStack(spacing: 0) {
                    sidebar.ignoresSafeArea(edges: .top)
                    VStack(spacing: 0) {
                        if !state.error.isEmpty && !settingsOpen {
                            VDInlineNotice(kind: .error, text: L(state.error), dismissLabel: D("Dismiss")) { state.error = "" }
                                .padding(.horizontal, 30).padding(.top, VD.Space.xl)
                        }
                        ScrollView {
                            Group {
                                switch visiblePage {
                                case "History": DesktopHistoryView(state: state)
                                case "Vocabulary": DesktopVocabularyView(state: state)
                                default: DesktopHomeView(state: state)
                                }
                            }
                            .frame(maxWidth: 1260, alignment: .leading)
                            .padding(.horizontal, 30).padding(.top, VD.Space.l).padding(.bottom, 36)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        if !state.notice.isEmpty && !settingsOpen {
                            VDInlineNotice(kind: .success, text: L(state.notice), dismissLabel: D("Dismiss")) { state.notice = "" }
                                .padding(.horizontal, 30).padding(.vertical, VD.Space.m)
                        }
                    }.background(VD.Palette.canvas.ignoresSafeArea())
                }.disabled(settingsOpen).allowsHitTesting(!settingsOpen).accessibilityHidden(settingsOpen)
                if settingsOpen {
                    VD.Palette.scrim.ignoresSafeArea()
                    DesktopSettingsView(state: state, tab: settingsTab, close: closeSettings)
                        .frame(width: min(1040, geometry.size.width - 80), height: geometry.size.height - 64)
                        .background(VD.Palette.canvas, in: RoundedRectangle(cornerRadius: VD.Radius.panel, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: VD.Radius.panel, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: VD.Radius.panel, style: .continuous).strokeBorder(VD.Palette.line))
                        .shadow(color: VD.Palette.shadow, radius: 28, y: 12)
                        .onExitCommand(perform: closeSettings)
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 740)
        .background(VD.Palette.canvas.ignoresSafeArea()).foregroundStyle(VD.Palette.ink).tint(VD.Palette.accent)
        .environment(\.locale, L10n.locale)
        .sheet(isPresented: $state.showingOnboarding) { OnboardingView(state: state) }
        .onReceive(NotificationCenter.default.publisher(for: .voiceDraftOpenSettings)) { _ in state.openSettings() }
        .onAppear { pageChanged(state.page) }
        .onChange(of: state.page) { pageChanged($0) }
    }

    private func pageChanged(_ page: String) {
        if Self.mainPages.contains(page) { returnPage = page; return }
        if page == "Models" || page == "Sync" { state.settingsTab = page; state.page = "Settings" }
        // Commit or drop any in-progress page edit before the overlay disables the page.
        if settingsOpen { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 25, weight: .bold))
                Text("VoiceDraft").font(VD.Font.brand)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.top, 34).accessibilityElement(children: .combine)
            VStack(spacing: VD.Space.xs) {
                navigation("Studio", title: D("Home"), icon: "house")
                navigation("History", title: L("History"), icon: "clock.arrow.circlepath")
                navigation("Vocabulary", title: D("Vocabulary"), icon: "book.closed")
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: VD.Space.m) {
                Label(D("Made for your words"), systemImage: "waveform").font(VD.Font.body.weight(.semibold))
                Text(D("Your models. Your vocabulary. A little less typing."))
                    .font(VD.Font.detail).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.padding(VD.Space.l).frame(maxWidth: .infinity, alignment: .leading)
                .background(VD.Palette.elevated, in: RoundedRectangle(cornerRadius: VD.Radius.card, style: .continuous))
            HStack {
                VDIconButton(systemName: "slider.horizontal.3", label: D("Settings"), size: 17) { state.openSettings() }
                Spacer()
                VDIconButton(systemName: "arrow.triangle.2.circlepath", label: L("Sync"), size: 17) { state.openSettings("Sync") }
                Spacer()
                VDIconButton(systemName: "info.circle", label: D("About"), size: 17) { state.openSettings("About") }
                Spacer()
                VDIconButton(systemName: "questionmark.circle", label: D("Help"), size: 17) { state.openSettings("Help") }
            }.padding(.horizontal, VD.Space.s).padding(.top, VD.Space.l)
                .overlay(alignment: .top) { Rectangle().fill(VD.Palette.line).frame(height: 1) }
        }
        .padding(VD.Space.l).frame(width: 222).frame(maxHeight: .infinity)
        .background(VD.Palette.surface, in: RoundedRectangle(cornerRadius: VD.Radius.panel, style: .continuous))
        .padding(10)
    }

    private func navigation(_ page: String, title: String, icon: String) -> some View {
        let selected = visiblePage == page
        return Button { state.page = page } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
                Text(title).font(VD.Font.navigation)
                Spacer()
            }.padding(.horizontal, 13).padding(.vertical, 13)
                .background(selected ? VD.Palette.selection : .clear, in: RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func closeSettings() { state.page = returnPage }
}

extension Notification.Name {
    static let voiceDraftOpenSettings = Notification.Name("VoiceDraft.openSettings")
}

/// Informational list of the enabled dictate / translate / edit / ask / insert-last shortcuts, shown as key caps.
private struct ShortcutSummaryList: View {
    @ObservedObject var state: AppState
    var rowPadding: CGFloat = 20
    private var bindings: [ShortcutBinding] {
        [ShortcutAction.dictate, .translate, .edit, .ask, .insertLast].compactMap { action in
            state.device.features.shortcuts.first { $0.action == action && $0.enabled }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if bindings.isEmpty {
                VStack(alignment: .leading, spacing: VD.Space.s) {
                    Text(D("No shortcuts are on")).font(VD.Font.cardTitle)
                    Text(D("Turn on a shortcut in Settings to dictate from any app.")).font(VD.Font.detail).foregroundStyle(.secondary)
                    Button(D("Settings")) { state.openSettings() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(rowPadding)
            }
            ForEach(Array(bindings.enumerated()), id: \.element.id) { index, binding in
                if index > 0 { Divider().padding(.horizontal, rowPadding) }
                HStack(spacing: VD.Space.l) {
                    VStack(alignment: .leading, spacing: VD.Space.xs) {
                        Text(title(binding.action)).font(VD.Font.cardTitle)
                        Text(detail(binding.action)).font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: VD.Space.s)
                    VDKeyCaps(label: binding.label, size: 13)
                }.padding(.horizontal, rowPadding).padding(.vertical, VD.Space.l)
                    .accessibilityElement(children: .combine)
            }
        }
    }
    private func title(_ action: ShortcutAction) -> String {
        switch action {
        case .dictate: return D("Dictate")
        case .ask: return D("Ask anything")
        default: return action.title
        }
    }
    private func detail(_ action: ShortcutAction) -> String {
        switch action {
        case .translate: return D("Your voice, in another language")
        case .edit: return D("Speak an instruction for selected text.")
        case .ask: return D("Speak a question. Make room for an idea.")
        case .insertLast: return action.detail ?? ""
        default: return D("Messy thoughts → clear writing")
        }
    }
}

private struct DesktopHomeView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.xl) {
            Text(D("Speak, don't type.")).font(VD.Font.hero).tracking(-1.2)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            FnShortcutStatus(state: state)
            HStack(alignment: .top, spacing: VD.Space.xl) {
                ShortcutSummaryList(state: state)
                    .background(VD.Palette.elevated, in: RoundedRectangle(cornerRadius: VD.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VD.Radius.card, style: .continuous).strokeBorder(VD.Palette.line))
                    .padding(10).background { wash }
                VDSurface(style: .shaded) {
                    stat("clock", value: "\(Int(state.history.reduce(0) { $0 + $1.duration }) / 60)", label: D("minutes recorded"))
                    stat("text.bubble", value: "\(state.history.count)", label: D("saved entries"))
                    stat("book.closed", value: "\(state.settings.vocabulary.entries.filter(\.enabled).count)", label: D("active terms"))
                    Text(D("Based on history on this Mac.")).font(VD.Font.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(width: 200).padding(.top, 10)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(D("Try it here")).font(VD.Font.sectionTitle)
                Spacer()
                Label(D("Your testing workspace"), systemImage: "slider.horizontal.3").font(VD.Font.detail).foregroundStyle(.secondary)
            }.padding(.top, VD.Space.s)
            StudioView(showsHeading: false, state: state)
        }
    }
    /// Decorative tinted dot grid behind the shortcut card; adapts to the appearance.
    private var wash: some View {
        ZStack {
            LinearGradient(colors: [VD.Palette.washStart, VD.Palette.washEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                for x in stride(from: 6.0, to: size.width, by: 10) {
                    for y in stride(from: 6.0, to: size.height, by: 10) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.primary.opacity(0.10)))
                    }
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: VD.Radius.card + 10, style: .continuous)).accessibilityHidden(true)
    }
    private func stat(_ icon: String, value: String, label: String) -> some View {
        HStack(spacing: VD.Space.m) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(VD.Font.statValue)
                Text(label).font(VD.Font.footnote).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

private struct DesktopVocabularyView: View {
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
    private var vocabularyEnabled: Binding<Bool> {
        Binding(get: { state.settings.vocabulary.enabled }, set: { enabled in update { $0.enabled = enabled } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.xl) {
            VDPageHeader(D("Vocabulary")) {
                HStack(spacing: VD.Space.s) {
                    Button(D("New word")) { editing = VocabularyEntry() }.buttonStyle(.vdPill)
                    VDOverflowMenu(label: D("More actions")) {
                        Button(L("Add several terms")) { bulkOpen = true }
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VD.Space.m) {
                    pills
                    Spacer(minLength: VD.Space.s)
                    statusPicker
                    masterToggle
                    VDSearchField(title: L("Search vocabulary"), text: $query, width: 180)
                }
                VStack(alignment: .leading, spacing: VD.Space.m) {
                    HStack(spacing: VD.Space.m) { pills; Spacer(minLength: VD.Space.s); masterToggle }
                    HStack(spacing: VD.Space.m) { statusPicker; Spacer(minLength: VD.Space.s); VDSearchField(title: L("Search vocabulary"), text: $query, width: 220) }
                }
            }
            if !state.settings.vocabulary.enabled {
                VDInlineNotice(kind: .info, text: D("App vocabulary is off. Your words are kept but not sent to your models."))
            }
            if entries.isEmpty {
                VDEmptyState(icon: "book.closed", title: query.isEmpty && filter == 0 && statusFilter == 0 ? L("Add names, products, or phrases you often say.") : D("No matching words"))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: VD.Space.m)], alignment: .leading, spacing: VD.Space.m) {
                    ForEach(entries) { entry in chip(entry) }
                }.opacity(state.settings.vocabulary.enabled ? 1 : 0.6)
            }
            VDSurface(style: .shaded, spacing: VD.Space.s) {
                Label(D("Automatic learning"), systemImage: "sparkles").font(VD.Font.cardTitle)
                VDSettingRow(title: D("Learn from corrections"), detail: D("For 45 seconds after insertion, supported editors can learn from changes to your dictated text. Other document text is not sent. Deleted words stay excluded from automatic learning.")) {
                    VDSwitch(D("Learn from corrections"), isOn: Binding(get: { state.settings.vocabulary.learnFromCorrections }, set: { value in update { $0.learnFromCorrections = value } }))
                }
                Divider()
                VDSettingRow(title: D("Discover words from dictation"), detail: D("Learns names and specialist terms using your writing model after dictation. Corrections are added directly; discovered words need two separate takes while the app is open.")) {
                    VDSwitch(D("Discover words from dictation"), isOn: Binding(get: { state.settings.vocabulary.discoverFromDictation }, set: { value in update { $0.discoverFromDictation = value } }))
                }
                Text(F("Manual spellings take priority. Automatic terms stay enabled with lower priority; edit and save a term to confirm it.", "手动拼写优先。自动词条保持启用，但优先级较低；编辑并保存即可确认该拼写。"))
                    .font(VD.Font.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !state.vocabularyLearningStatus.isEmpty {
                    Text(state.vocabularyLearningStatus).font(VD.Font.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            DisclosureGroup(D("Model vocabulary details")) {
                VStack(alignment: .leading, spacing: VD.Space.l) {
                    if let speech = state.settings.speech { VocabularyProjectionView(vocabulary: state.settings.vocabulary, profile: speech) }
                    ForEach(state.settings.vocabulary.legacyReferences.indices, id: \.self) { i in
                        let reference = state.settings.vocabulary.legacyReferences[i]
                        Text("\(reference.model) · \(reference.resourceID)").font(VD.Font.detail).textSelection(.enabled)
                    }
                }.padding(.top, VD.Space.m)
            }.font(VD.Font.detail).foregroundStyle(.secondary)
            // The import/export/extraction buttons own their review sheet, so they stay as buttons instead of menu items.
            VStack(alignment: .leading, spacing: VD.Space.m) {
                VDSectionHeader(icon: "square.and.arrow.down.on.square", title: D("Import and export"))
                VocabularyFileControls(state: state)
            }
            Text(L("Vocabulary and preferences are included in encrypted sync.")).font(VD.Font.footnote).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { entry in
            VocabularyEntryEditor(entry: entry, save: { value in
                update { vocabulary in
                    if let i = vocabulary.entries.firstIndex(where: { $0.id == value.id }) { vocabulary.entries[i] = value }
                    else { vocabulary.entries.append(value) }
                }
            }, saveError: { state.error.isEmpty ? nil : L(state.error) })
        }
        .sheet(isPresented: $bulkOpen) { bulkSheet }
    }
    private var pills: some View {
        VDFilterPills(labels: [D("All"), D("Auto-added"), D("Manually-added")], selection: $filter).fixedSize()
    }
    private var statusPicker: some View {
        Picker(D("Word status"), selection: $statusFilter) {
            Text(D("All statuses")).tag(0)
            Text(L("Enabled")).tag(1)
            Text(D("Disabled")).tag(2)
        }.labelsHidden().fixedSize()
    }
    private var masterToggle: some View {
        Toggle(L("Enable app vocabulary"), isOn: vocabularyEnabled).toggleStyle(.switch).font(VD.Font.detail).fixedSize()
    }
    private func chip(_ entry: VocabularyEntry) -> some View {
        Button { editing = entry } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.origin == .automatic ? "sparkle" : "leaf.fill")
                    .foregroundStyle(entry.origin == .automatic ? AnyShapeStyle(VD.Palette.accent) : AnyShapeStyle(.tertiary)).font(.system(size: 13))
                    .accessibilityLabel(entry.origin == .automatic ? D("Auto-added") : D("Manually-added"))
                Text("\(entry.useCount)").font(VD.Font.footnote).foregroundStyle(.secondary).monospacedDigit().help(F("Uses", "使用次数"))
                Text(entry.text).font(.system(size: 15)).lineLimit(1)
                Spacer(minLength: 0)
                if entry.priority { Image(systemName: "star.fill").foregroundStyle(VD.Palette.warning) }
                if !entry.enabled { Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityLabel(D("Disabled")) }
            }.padding(.horizontal, VD.Space.l).padding(.vertical, VD.Space.l)
                .background(VD.Palette.elevated, in: RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous).strokeBorder(VD.Palette.line))
                .contentShape(RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
                .opacity(entry.enabled ? 1 : 0.65)
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
    private var bulkSheet: some View {
        VocabularyBulkAddSheet(state: state, words: $words, isPresented: $bulkOpen)
    }
    private func update(_ change: (inout AppVocabulary) -> Void) {
        var copy = state.settings; change(&copy.vocabulary); state.save(copy)
    }
}

/// Vocabulary's "Add several terms" sheet; standalone so `VOICEDRAFT_CAPTURE_SHEETS` can render it.
struct VocabularyBulkAddSheet: View {
    @ObservedObject var state: AppState
    @Binding var words: String
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.l) {
            VStack(alignment: .leading, spacing: VD.Space.xs) {
                Text(L("Add several terms")).font(VD.Font.sheetTitle)
                Text(L("One word or phrase per line. Existing terms are kept.")).font(VD.Font.detail).foregroundStyle(.secondary)
            }
            TextEditor(text: $words).font(VD.Font.body).vdEditorBox(minHeight: 190, maxHeight: 190)
            if !state.error.isEmpty {
                VDInlineNotice(kind: .error, text: L(state.error), dismissLabel: D("Dismiss")) { state.error = "" }
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { isPresented = false }.keyboardShortcut(.cancelAction)
                Button(L("Add to vocabulary")) {
                    var copy = state.settings; copy.vocabulary.appendLines(words); state.save(copy)
                    if state.error.isEmpty { words = ""; isPresented = false }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.vdSheet(width: 520)
    }
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
    private var keepHistory: Binding<Bool> {
        Binding(get: { state.device.keepHistory }, set: { state.saveDevice(autoPaste: state.device.autoPaste, history: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.xl) {
            VDPageHeader(L("History")) {
                HStack(spacing: VD.Space.m) {
                    Label(D("Only on this Mac"), systemImage: "internaldrive").font(VD.Font.detail).foregroundStyle(.secondary)
                    VDOverflowMenu(label: D("More actions")) {
                        Toggle(D("Keep history"), isOn: keepHistory)
                        Divider()
                        Button(L("Clear history…"), role: .destructive) { confirmClear = true }.disabled(state.history.isEmpty)
                    }
                }
            }
            if !state.device.keepHistory {
                VDInlineNotice(kind: .info, text: D("History is off. New transcripts are not saved on this Mac."))
            }
            HStack(spacing: VD.Space.m) {
                VDFilterPills(labels: [D("All"), D("Dictations"), D("Ask anything")], selection: $filter).fixedSize()
                Spacer(minLength: VD.Space.s)
                VDSearchField(title: L("Search your words"), text: $query, width: 200)
            }
            if entries.isEmpty {
                VDEmptyState(icon: "clock.arrow.circlepath", title: state.history.isEmpty ? L("Your words will find a home here.") : D("No matching entries"))
            }
            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: VD.Space.s) {
                    Text(dayTitle(day)).font(VD.Font.detail.weight(.medium)).foregroundStyle(.secondary).padding(.leading, VD.Space.xs)
                    VDSurface(padding: 0, spacing: 0) {
                        let group = entries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.horizontal, VD.Space.l) }
                            historyRow(entry)
                        }
                    }
                }
            }
            Label(F("History and retained recordings stay on this Mac. Manage audio retention in Settings.", "历史与保留的录音只存储在本机。可在设置中管理录音保存和保留期限。"), systemImage: "lock")
                .font(VD.Font.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.confirmationDialog(L("Delete all local history?"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("Delete history"), role: .destructive) { state.deleteHistory() }
        }
    }
    private func historyRow(_ entry: HistoryEntry) -> some View {
        let isExpanded = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: VD.Space.m) {
            HStack(alignment: .top, spacing: VD.Space.l) {
                Text(entry.date.formatted(.dateTime.hour().minute().locale(L10n.locale))).font(VD.Font.detail).foregroundStyle(.secondary)
                    .monospacedDigit().frame(width: 70, alignment: .leading).padding(.top, 6)
                Text(entry.result).font(VD.Font.body).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                HStack(spacing: 2) {
                    VDIconButton(systemName: isExpanded ? "chevron.up" : "chevron.down", label: isExpanded ? D("Hide details") : D("Show details")) {
                        if isExpanded { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                    }
                    VDIconButton(systemName: "doc.on.doc", label: L("Copy")) { state.copyResult(entry.result) }
                    VDIconButton(systemName: "trash", label: L("Delete history entry")) { state.deleteHistory(entry.id) }
                }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: VD.Space.m) {
                    Label("\(entry.mode.title) · \(entry.application)", systemImage: entry.mode.icon).font(VD.Font.detail).foregroundStyle(.secondary)
                    if entry.original != entry.result {
                        VDSurface(style: .shaded, padding: VD.Space.m, spacing: VD.Space.xs) {
                            Text(L("Original transcript")).font(VD.Font.detail.weight(.semibold)).foregroundStyle(.secondary)
                            Text(entry.original).font(VD.Font.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: VD.Space.s) {
                        if entry.audioID != nil {
                            Button(state.playingAudioID == entry.audioID ? F("Stop audio", "停止播放") : F("Play audio", "播放录音")) { state.play(entry) }
                            Button(F("Transcribe again", "重新识别")) { state.reprocess(entry, transcribeAgain: true) }
                        }
                        Button(F("Rewrite transcript", "重新处理文字")) { state.reprocess(entry, transcribeAgain: false) }
                        Text(F("Uses current models and style", "使用当前模型和风格")).font(VD.Font.footnote).foregroundStyle(.secondary)
                    }.disabled(state.busy)
                }.padding(.leading, 86).padding(.trailing, 92)
            }
        }.padding(VD.Space.l)
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
    @State private var accessibilityAllowed: Bool?
    @State private var screenRecordingAllowed: Bool?
    private let tabs = [("Settings", "gearshape"), ("Personalization", "pencil.and.outline"), ("Models", "cpu"),
                        ("Sync", "arrow.triangle.2.circlepath"), ("About", "info.circle"), ("Help", "questionmark.circle")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: VD.Space.xs) {
                ForEach(tabs, id: \.0) { name, icon in
                    Button { tab = name } label: {
                        HStack(spacing: 11) {
                            Image(systemName: icon).frame(width: 20)
                            Text(title(name)).font(VD.Font.body)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, VD.Space.m).padding(.vertical, VD.Space.m)
                            .background(tab == name ? VD.Palette.selection : .clear, in: RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == name ? [.isSelected] : [])
                }
                Spacer()
            }.padding(14).padding(.top, 20).frame(width: 195).background(VD.Palette.surface)
            VStack(spacing: 0) {
                VDPageHeader(title(tab)) {
                    VDIconButton(systemName: "xmark", label: D("Close settings"), size: 14, action: close).keyboardShortcut(.cancelAction)
                }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
                if !state.error.isEmpty {
                    VDInlineNotice(kind: .error, text: L(state.error), dismissLabel: D("Dismiss")) { state.error = "" }
                        .padding(.horizontal, 30).padding(.bottom, VD.Space.m)
                }
                ScrollView {
                    Group {
                        switch tab {
                        case "Models": ModelsView(state: state, showsHeading: false)
                        case "Sync": SyncView(state: state, showsHeading: false)
                        case "Personalization": DesktopPersonalizationView(state: state)
                        case "About": about
                        case "Help": help
                        default: general
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 30).padding(.bottom, 30)
                }
                if !state.notice.isEmpty {
                    VDInlineNotice(kind: .success, text: L(state.notice), dismissLabel: D("Dismiss")) { state.notice = "" }
                        .padding(.horizontal, 30).padding(.vertical, VD.Space.m)
                }
            }
        }
        .task {
            // Accessibility and Screen Recording can be granted in System Settings while the overlay is open.
            repeat {
                accessibilityAllowed = state.insertionAuthorized
                screenRecordingAllowed = state.preview || ScreenRecordingPermission.granted
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func title(_ name: String) -> String {
        switch name {
        case "Models", "Sync": return L10n.text(name)
        default: return D(name)
        }
    }
    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VD.Space.s) {
            VDSectionHeader(icon: icon, title: title)
            content()
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: VD.Space.xxl) {
            section(D("Shortcuts"), icon: "keyboard") { ShortcutPreferences(state: state) }
            RecordingPreferences(state: state)
            ScreenContextPreferences(state: state, screenRecordingAllowed: screenRecordingAllowed)
            section(D("Audio"), icon: "mic") {
                VDSettingRow(title: L("Input device"), detail: D("Used when you record with a shortcut or on Home.")) {
                    HStack(spacing: VD.Space.xs) {
                        Picker(L("Input device"), selection: Binding(get: { state.device.inputDeviceID ?? "" }, set: { state.selectInputDevice($0) })) {
                            let defaultName = state.inputDevices.first { $0.id == state.defaultInputID }?.name
                            Text(defaultName.map { L("System default — \($0)") } ?? L("System default")).tag("")
                            ForEach(state.inputDevices) { input in Text(input.name).tag(input.id) }
                            if let saved = state.device.inputDeviceID, !state.inputDevices.contains(where: { $0.id == saved }) {
                                Text(L("Unavailable: \(state.device.inputDeviceName ?? saved)")).tag(saved)
                            }
                        }.labelsHidden().frame(maxWidth: 300)
                        VDIconButton(systemName: "arrow.clockwise", label: L("Refresh devices")) { state.refreshInputDevices() }
                    }.disabled(state.busy)
                }
            }
            section(D("Language"), icon: "globe") {
                VDSettingRow(title: L("Interface language"), detail: D("Choose the language used in VoiceDraft.")) {
                    Picker(L("Interface language"), selection: Binding(get: { state.interfaceLanguage }, set: { state.setLanguage($0) })) {
                        ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                    }.labelsHidden().frame(width: 190).disabled(state.busy)
                }
                VDSettingRow(title: L("Translation target language"), detail: state.settings.targetLanguage) {
                    Button(L("Edit")) { tab = "Personalization" }
                }
            }
            section(D("General"), icon: "laptopcomputer") {
                VDSettingRow(title: D("Automatic insertion"), detail: L("Insert into the original app after recording")) {
                    VDSwitch(L("Insert into the original app after recording"), isOn: Binding(get: { state.device.autoPaste }, set: { state.saveDevice(autoPaste: $0, history: state.device.keepHistory) }))
                }
                VDSettingRow(title: D("Keep history"), detail: L("Save future transcripts on this Mac")) {
                    VDSwitch(L("Save future transcripts on this Mac"), isOn: Binding(get: { state.device.keepHistory }, set: { state.saveDevice(autoPaste: state.device.autoPaste, history: $0) }))
                }
                VDSettingRow(title: D("Accessibility"), detail: L("Allow Accessibility for insertion. Microphone permission is requested when you record.")) {
                    if accessibilityAllowed ?? state.insertionAuthorized {
                        VDBadge(text: D("Allowed"), tint: VD.Palette.success)
                    } else {
                        Button(L("Allow Accessibility")) { TextInsertion.requestAccess() }
                    }
                }
                LaunchPreferences(state: state)
            }
            UpdatePreferences(state: state)
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: VD.Space.xl) {
            HStack(spacing: VD.Space.l) {
                Image(systemName: "waveform").font(.system(size: 42, weight: .bold)).foregroundStyle(VD.Palette.accent)
                VStack(alignment: .leading, spacing: VD.Space.xs) {
                    Text("VoiceDraft").font(VD.Font.brand)
                    Text(F("Version ", "版本 ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"))
                        .font(VD.Font.detail).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Text(D("Your models. Your vocabulary. A little less typing.")).font(VD.Font.sectionTitle.weight(.regular))
            VDSurface(style: .shaded, spacing: VD.Space.s) {
                Label(L("Your models. Your words."), systemImage: "lock.shield").font(VD.Font.cardTitle)
                Text(F("The sync server stores encrypted settings. Model calls go directly to your configured providers; history and retained audio stay on this Mac.", "同步服务器只保存加密配置。模型调用直接发送到你配置的服务商；历史和保留的录音留在本机。"))
                    .font(VD.Font.body).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, VD.Space.xs)
    }
    private var help: some View {
        VStack(alignment: .leading, spacing: VD.Space.l) {
            VDSurface(style: .shaded, spacing: VD.Space.s) {
                Text(D("Start with your models")).font(VD.Font.cardTitle)
                Text(F("Choose speech and writing services using your own credentials.", "使用自己的凭证，独立选择语音识别与写作服务。"))
                    .font(VD.Font.body).foregroundStyle(.secondary)
                Button(L("Models")) { tab = "Models" }.padding(.top, VD.Space.xs)
            }
            VDSurface(padding: 0, spacing: 0) {
                Text(D("Shortcuts")).font(VD.Font.cardTitle).padding([.horizontal, .top], 20).padding(.bottom, VD.Space.xs)
                ShortcutSummaryList(state: state)
            }
            VDSurface(spacing: VD.Space.s) {
                Text(D("Try it here")).font(VD.Font.cardTitle)
                Text(L("Or type here to test your writing model.")).font(VD.Font.body).foregroundStyle(.secondary)
                Button(D("Home")) { close(); state.page = "Studio" }.padding(.top, VD.Space.xs)
            }
            VDSurface(spacing: VD.Space.s) {
                Text(L("Make room for your voice")).font(VD.Font.cardTitle)
                Text(L("Allow Accessibility for insertion. Microphone permission is requested when you record.")).font(VD.Font.body).foregroundStyle(.secondary)
                if accessibilityAllowed ?? state.insertionAuthorized {
                    Label(D("Accessibility is allowed"), systemImage: "checkmark.circle.fill").font(VD.Font.detail).foregroundStyle(VD.Palette.success)
                } else {
                    Button(L("Allow Accessibility")) { TextInsertion.requestAccess() }.padding(.top, VD.Space.xs)
                }
            }
        }
    }
}

private struct DesktopPersonalizationView: View {
    @ObservedObject var state: AppState
    @State private var style = ""
    @State private var language = ""
    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.xxl) {
            StyleLibraryView(state: state)
            VStack(alignment: .leading, spacing: VD.Space.m) {
                VDSectionHeader(icon: "text.quote", title: L("Your writing style"))
                Text(D("Used when no named style applies.")).font(VD.Font.detail).foregroundStyle(.secondary)
                TextEditor(text: $style).font(VD.Font.body).vdEditorBox(minHeight: 180, maxHeight: 180)
            }
            VStack(alignment: .leading, spacing: VD.Space.m) {
                VDSectionHeader(icon: "globe", title: L("Translation target language"))
                SingleLineField(L("Translation target language"), text: $language).frame(maxWidth: 360)
                HStack(spacing: VD.Space.m) {
                    Button(L("Save preferences")) {
                        var copy = state.settings; copy.stylePrompt = style; copy.targetLanguage = language; state.save(copy)
                    }.buttonStyle(.borderedProminent)
                        .disabled(style == state.settings.stylePrompt && language == state.settings.targetLanguage)
                    Text(D("Saves the writing style and translation target.")).font(VD.Font.detail).foregroundStyle(.secondary)
                }.padding(.top, VD.Space.xs)
            }
            Text(L("Vocabulary and preferences are included in encrypted sync.")).font(VD.Font.footnote).foregroundStyle(.secondary)
        }.onAppear { style = state.settings.stylePrompt; language = state.settings.targetLanguage }
    }
}
