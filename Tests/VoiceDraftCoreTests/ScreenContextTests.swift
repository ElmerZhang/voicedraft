import XCTest
@testable import VoiceDraftCore

/// Fake accessibility tree with `Int` nodes. No real AX, screen or OCR.
private struct FakeTree {
    var attributes: [Int: ScreenTextAttributes] = [:]
    var children: [Int: [Int]] = [:]
    var visibleChildren: [Int: [Int]] = [:]
    var parents: [Int: Int] = [:]
    var reads: (Int) -> Void = { _ in }

    mutating func add(_ node: Int, _ attrs: ScreenTextAttributes, under parent: Int? = nil) {
        attributes[node] = attrs
        if let parent { children[parent, default: []].append(node); parents[node] = parent }
    }

    func collect(title: String? = nil, focused: Int? = nil, value: String? = nil, range: NSRange? = nil,
                 limits: ScreenContextLimits = .standard, now: @escaping () -> TimeInterval = { 0 }) -> ScreenTextCollection {
        ScreenTextWalker.collect(window: 0, windowTitle: title, focused: focused, focusedValue: value, focusedRange: range,
            attributes: { reads($0); return attributes[$0] ?? ScreenTextAttributes(role: "AXGroup") },
            children: { node, visibleOnly in visibleOnly ? (visibleChildren[node] ?? children[node] ?? []) : (children[node] ?? []) },
            parent: { parents[$0] }, limits: limits, now: now)
    }
}

private func text(_ role: String, _ value: String, subrole: String = "") -> ScreenTextAttributes {
    ScreenTextAttributes(role: role, subrole: subrole, value: value)
}

final class ScreenContextTests: XCTestCase {
    // MARK: Walker

    func testFocusedFirstThenTitleNeighboursThenBodyWithoutReadingFocusedElement() {
        var tree = FakeTree()
        tree.add(0, ScreenTextAttributes(role: "AXWindow", title: "Fixture Window"))
        tree.add(1, ScreenTextAttributes(role: "AXGroup"), under: 0)
        tree.add(2, ScreenTextAttributes(role: "AXGroup"), under: 0)
        tree.add(3, text("AXStaticText", "Body paragraph"), under: 1)
        tree.add(4, text("AXTextArea", "never read"), under: 2)
        tree.add(5, text("AXStaticText", "Neighbour message"), under: 2)
        tree.add(6, ScreenTextAttributes(role: "AXHeading", title: "Section heading"), under: 1)
        tree.reads = { XCTAssertNotEqual($0, 4, "the focused element must not be read again") }
        let result = tree.collect(title: "Fixture Window", focused: 4, value: "ab😀cd", range: NSRange(location: 4, length: 0))
        XCTAssertEqual(result.segments.map(\.kind), [.focused, .windowTitle, .neighbour, .body, .heading])
        XCTAssertEqual(result.segments.map(\.text), ["ab😀cd", "Fixture Window", "Neighbour message", "Body paragraph", "Section heading"])
        XCTAssertEqual(result.segments[0].caretOffset, 4)
        XCTAssertEqual(result.segments.map(\.order), [0, 1, 2, 3, 4])
        XCTAssertEqual(result.contentCharacters, "Neighbourmessage".count + "Bodyparagraph".count + "Sectionheading".count)
    }

    func testSecureHiddenMenusControlsImagesAndToolbars() {
        var tree = FakeTree()
        tree.add(0, ScreenTextAttributes(role: "AXWindow"))
        tree.add(1, ScreenTextAttributes(role: "AXGroup", subrole: "AXSecureTextField"), under: 0)
        tree.add(2, text("AXStaticText", "SecretChild"), under: 1)
        tree.add(3, ScreenTextAttributes(role: "AXGroup", hidden: true), under: 0)
        tree.add(4, text("AXStaticText", "HiddenChild"), under: 3)
        tree.add(5, ScreenTextAttributes(role: "AXMenuBar"), under: 0)
        tree.add(6, ScreenTextAttributes(role: "AXMenuItem", title: "MenuTitle"), under: 5)
        tree.add(7, ScreenTextAttributes(role: "AXButton", title: "Deploy"), under: 0)
        tree.add(8, ScreenTextAttributes(role: "AXImage", description: "Avatar of Alice"), under: 0)
        tree.add(9, ScreenTextAttributes(role: "AXImage", description: String(repeating: "x", count: 81)), under: 0)
        tree.add(10, ScreenTextAttributes(role: "AXToolbar"), under: 0)
        tree.add(11, text("AXStaticText", "Toolbar label"), under: 10)
        tree.add(12, ScreenTextAttributes(role: "AXRadioButton", subrole: "AXTab", title: "TabTitle"), under: 0)
        tree.add(13, text("AXTextField", "field value", subrole: "AXSecureTextField"), under: 0)
        var visited: [Int] = []
        tree.reads = { visited.append($0) }
        let result = tree.collect()
        XCTAssertEqual(result.skippedSecure, 2)
        XCTAssertFalse(visited.contains(2), "secure subtrees are never descended")
        XCTAssertFalse(visited.contains(4), "hidden subtrees are never descended")
        XCTAssertFalse(visited.contains(6), "menus are never descended")
        XCTAssertEqual(result.segments.map(\.kind), [.control, .control, .control, .control])
        XCTAssertEqual(result.segments.map(\.text), ["Deploy", "Avatar of Alice", "TabTitle", "Toolbar label"])
        XCTAssertEqual(result.contentCharacters, 0)
    }

    func testNodeDepthTimeAndCharacterBudgets() {
        var chain = FakeTree()
        chain.add(0, ScreenTextAttributes(role: "AXWindow"))
        for node in 1...20 { chain.add(node, ScreenTextAttributes(role: "AXGroup", title: "Level \(node)"), under: node - 1) }
        var limits = ScreenContextLimits.standard
        limits.axNodes = 3
        var result = chain.collect(limits: limits)
        XCTAssertEqual(result.nodesVisited, 3); XCTAssertTrue(result.truncated)

        limits = .standard; limits.axDepth = 2
        result = chain.collect(limits: limits)
        XCTAssertEqual(result.nodesVisited, 3); XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.segments.map(\.text), ["Level 1", "Level 2"])

        var clock: TimeInterval = 0
        limits = .standard
        result = chain.collect(limits: limits, now: { clock += 0.04; return clock })
        XCTAssertTrue(result.truncated)
        XCTAssertLessThan(result.nodesVisited, 5, "a 150 ms budget stops the walk")

        limits = .standard; limits.charactersCollected = 12
        result = chain.collect(limits: limits)
        XCTAssertEqual(result.charactersCollected, 12); XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.segments.map(\.text), ["Level 1", "Level"])

        limits = .standard; limits.characterPerNode = 4
        result = chain.collect(limits: limits)
        XCTAssertEqual(result.segments.first?.text, "Leve")
    }

    func testCyclesTerminateAndVisibleChildrenAreUsedForLists() {
        var tree = FakeTree()
        tree.add(0, ScreenTextAttributes(role: "AXWindow"))
        tree.add(1, ScreenTextAttributes(role: "AXGroup", title: "Loop A"), under: 0)
        tree.add(2, ScreenTextAttributes(role: "AXGroup", title: "Loop B"), under: 1)
        tree.children[2] = [1, 0]          // child cycle
        tree.parents[1] = 2                 // parent cycle
        tree.add(3, ScreenTextAttributes(role: "AXList"), under: 0)
        tree.add(4, text("AXStaticText", "Visible row"), under: 3)
        tree.add(5, text("AXStaticText", "Offscreen row"), under: 3)
        tree.visibleChildren[3] = [4]
        let result = tree.collect(focused: 2, value: "draft")
        XCTAssertEqual(Set(result.segments.map(\.text)), ["draft", "Loop A", "Visible row"])
        XCTAssertFalse(result.segments.contains { $0.text == "Offscreen row" })
    }

    func testDuplicateTextDroppedAndNormalizationStripsInvisibleControls() {
        var tree = FakeTree()
        tree.add(0, ScreenTextAttributes(role: "AXWindow"))
        tree.add(1, text("AXStaticText", "Same text"), under: 0)
        tree.add(2, text("AXStaticText", "Same text"), under: 0)
        tree.add(3, text("AXStaticText", "A\u{202E}B\u{200B}C\u{2066}D\u{FEFF}E\u{0007}F   G\tH\r\nI\u{0085}J"), under: 0)
        let result = tree.collect()
        XCTAssertEqual(result.segments.map(\.text), ["Same text", "ABCDEF G H\nIJ"])
        XCTAssertEqual(ScreenTextWalker.normalize("  x\u{200D}y  "), "xy")
        XCTAssertEqual(ScreenTextWalker.normalize("长文本", limit: 2), "长文")
    }

    func testLongFocusedValueKeepsTextAroundCaret() {
        let value = String(repeating: "a", count: 3_000) + "CARET" + String(repeating: "b", count: 3_000)
        let result = FakeTree().collect(focused: 9, value: value, range: NSRange(location: 3_000, length: 0))
        let focused = result.segments[0]
        XCTAssertEqual(focused.text.count, 2_000)
        let caret = ScreenExcerptBuilder.characterIndex(in: focused.text, utf16Offset: focused.caretOffset!)
        XCTAssertTrue(focused.text[caret...].hasPrefix("CARET"))
    }

    // MARK: Policy

    func testExclusionsAreCaseInsensitiveAndVoiceDraftIsAlwaysExcluded() {
        var options = DesktopOptions()
        options.screenContextExcludedApps = ["com.Example.Mail"]
        XCTAssertFalse(ScreenContextPolicy.allows(bundleID: "COM.1PASSWORD.1PASSWORD", options: options, ownBundleID: "app.voicedraft"))
        XCTAssertFalse(ScreenContextPolicy.allows(bundleID: "com.apple.passwords", options: options, ownBundleID: nil))
        XCTAssertFalse(ScreenContextPolicy.allows(bundleID: "com.example.mail", options: options, ownBundleID: nil))
        XCTAssertFalse(ScreenContextPolicy.allows(bundleID: "App.VoiceDraft", options: options, ownBundleID: "app.voicedraft"))
        XCTAssertFalse(ScreenContextPolicy.allows(bundleID: nil, options: options, ownBundleID: nil))
        XCTAssertTrue(ScreenContextPolicy.allows(bundleID: "com.example.mail.helper", options: options, ownBundleID: nil), "no prefix wildcards")
        XCTAssertTrue(ScreenContextPolicy.allows(bundleID: "com.apple.Notes", options: options, ownBundleID: "app.voicedraft"))
        XCTAssertEqual(ScreenContextPolicy.builtInExcludedBundleIDs.count, 5)
    }

    func testShouldCaptureMatrix() {
        var options = DesktopOptions()
        func capture(external: Bool = true, secure: Bool = false, bundle: String = "com.apple.Notes") -> Bool {
            ScreenContextPolicy.shouldCapture(options: options, external: external, secure: secure, bundleID: bundle, ownBundleID: "app.voicedraft")
        }
        XCTAssertFalse(capture(), "master off by default")
        options.screenContext = true
        XCTAssertTrue(capture())
        XCTAssertFalse(capture(external: false), "Home takes never read the screen")
        XCTAssertFalse(capture(secure: true))
        XCTAssertFalse(capture(bundle: "com.bitwarden.desktop"))
        XCTAssertFalse(capture(bundle: "app.voicedraft"))
        options.screenContextASR = false
        XCTAssertTrue(capture())
        options.screenContextWriting = false
        XCTAssertFalse(capture(), "no consumers")
    }

    func testNeedsOCRThresholdCountsOnlyContentText() {
        XCTAssertTrue(ScreenContextPolicy.needsOCR(nil))
        let filler = ScreenTextSegment(kind: .focused, text: String(repeating: "f", count: 500), order: 0)
        var collection = ScreenTextCollection(segments: [filler,
            ScreenTextSegment(kind: .windowTitle, text: String(repeating: "t", count: 200), order: 1),
            ScreenTextSegment(kind: .control, text: String(repeating: "c", count: 200), order: 2),
            ScreenTextSegment(kind: .body, text: String(repeating: "b ", count: 119), order: 3)])
        XCTAssertEqual(collection.contentCharacters, 119)
        XCTAssertTrue(ScreenContextPolicy.needsOCR(collection))
        collection.segments.append(ScreenTextSegment(kind: .heading, text: "h", order: 4))
        XCTAssertFalse(ScreenContextPolicy.needsOCR(collection))
    }

    func testOCRLanguagesMapAndFilter() {
        let all = ["en-US", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "de-DE", "fr-FR", "es-ES"]
        XCTAssertEqual(ScreenContextPolicy.ocrLanguages(interface: "ja", supported: all), ["ja-JP", "zh-Hans", "en-US"])
        XCTAssertEqual(ScreenContextPolicy.ocrLanguages(interface: "zh-Hans", supported: all), ["zh-Hans", "en-US"])
        XCTAssertEqual(ScreenContextPolicy.ocrLanguages(interface: "zh-Hant", supported: all), ["zh-Hant", "zh-Hans", "en-US"])
        XCTAssertEqual(ScreenContextPolicy.ocrLanguages(interface: "en", supported: all), ["en-US", "zh-Hans"])
        for (code, expected) in [("ko", "ko-KR"), ("de", "de-DE"), ("fr", "fr-FR"), ("es", "es-ES")] {
            XCTAssertEqual(ScreenContextPolicy.ocrLanguages(interface: code, supported: all).first, expected)
        }
        XCTAssertEqual(ScreenContextPolicy.ocrLanguages(interface: "ko", supported: ["en-US"]), ["en-US"])
        XCTAssertEqual(ScreenContextPolicy.ocrLanguages(interface: "it", supported: all), ["zh-Hans", "en-US"])
        XCTAssertEqual(ScreenContextPolicy.ocrLanguages(interface: "ja", supported: []), [])
    }

    // MARK: ASR terms

    private func snapshot(_ terms: [ScreenTerm], excerpt: String = "") -> ScreenContextSnapshot {
        ScreenContextSnapshot(sources: [.accessibility], bundleID: "com.fixture.app", applicationName: "Fixture", excerpt: excerpt, terms: terms)
    }

    func testASRTermsRespectCountAndByteBudgets() {
        let many = (0..<400).map { ScreenTerm(text: "FixtureKit\($0)", kind: .camelCase) }
        XCTAssertEqual(ScreenContextPolicy.asrTerms(snapshot(many), vocabulary: AppVocabulary()).count, 300)
        let long = (0..<200).map { ScreenTerm(text: "Kit\($0)" + String(repeating: "x", count: 55), kind: .camelCase) }
        let limited = ScreenContextPolicy.asrTerms(snapshot(long), vocabulary: AppVocabulary())
        XCTAssertLessThan(limited.count, 200)
        XCTAssertLessThanOrEqual(limited.joined(separator: ", ").utf8.count, 6_000)
        XCTAssertGreaterThan(limited.joined(separator: ", ").utf8.count, 5_900)
        let shaped = [ScreenTerm(text: "x", kind: .quoted), ScreenTerm(text: "one two three four five", kind: .quoted),
                      ScreenTerm(text: "line\nbreak", kind: .quoted), ScreenTerm(text: String(repeating: "y", count: 65), kind: .quoted)]
        XCTAssertEqual(ScreenContextPolicy.asrTerms(snapshot(shaped), vocabulary: AppVocabulary()), [])
        XCTAssertEqual(ScreenContextPolicy.asrTerms(nil, vocabulary: AppVocabulary()), [])
    }

    func testASRTermsExcludeEveryVocabularySpellingAndHonourGlobalSwitch() {
        var vocabulary = AppVocabulary(words: "VoiceDraft\nDoubao\nFigma Design\nnotion app")
        vocabulary.entries[1].enabled = false
        vocabulary.entries[2].aliases = ["Figma"]
        vocabulary.entries[3].displayAs = "Notion"
        vocabulary.excludedAutomaticTerms.insert(AppVocabulary.automaticTermKey("Raycast"))
        let terms = ["voicedraft", "doubao", "figma", "NOTION", "raycast", "KeepKit"].map { ScreenTerm(text: $0, kind: .camelCase) }
            + [ScreenTerm(text: "章山", kind: .cjkRun)]
        let ordered = [ScreenTerm(text: "章山", kind: .cjkRun)] + terms.dropLast()
        XCTAssertEqual(ScreenContextPolicy.asrTerms(snapshot(ordered), vocabulary: vocabulary), ["KeepKit", "章山"])
        vocabulary.enabled = false
        XCTAssertEqual(ScreenContextPolicy.asrTerms(snapshot(terms), vocabulary: vocabulary), [])
        XCTAssertEqual(ScreenContextPolicy.keys(of: ["VoiceDraft"]), [AppVocabulary.automaticTermKey("voicedraft")])
    }

    // MARK: Excerpt

    private func excerpt(_ segments: [ScreenTextSegment], limit: Int = 1_500, selection: String = "") -> String {
        ScreenExcerptBuilder.excerpt(from: ScreenTextCollection(segments: segments), limit: limit, excludingSelection: selection)
    }

    func testExcerptWindowsAroundUTF16CaretWithEmojiAndCJK() {
        let text = String(repeating: "字", count: 800) + "😀" + String(repeating: "尾", count: 300)
        let caret = 800 + 2 // after the emoji (a surrogate pair)
        let result = excerpt([ScreenTextSegment(kind: .focused, text: text, order: 0, caretOffset: caret)])
        XCTAssertEqual(result.count, 900)
        XCTAssertTrue(result.contains("字😀尾"))
        XCTAssertEqual(result.filter { $0 == "尾" }.count, 200)
        XCTAssertEqual(result.filter { $0 == "字" }.count, 699)
        // An offset inside the surrogate pair rounds down to a character boundary.
        let inside = excerpt([ScreenTextSegment(kind: .focused, text: text, order: 0, caretOffset: 801)])
        XCTAssertTrue(inside.hasSuffix(String(repeating: "尾", count: 199)))
        XCTAssertEqual(ScreenExcerptBuilder.characterIndex(in: "a😀b", utf16Offset: 2), "a😀b".index(after: "a😀b".startIndex))
        XCTAssertEqual(ScreenExcerptBuilder.characterIndex(in: "ab", utf16Offset: 99), "ab".endIndex)
        // Without a caret the end of the draft is used.
        let tail = excerpt([ScreenTextSegment(kind: .focused, text: String(repeating: "x", count: 1_000) + "END", order: 0)])
        XCTAssertTrue(tail.hasSuffix("END")); XCTAssertEqual(tail.count, 900)
    }

    func testExcerptCutsLatinWindowsAtWordBoundaries() {
        let words = (0..<400).map { "word\($0)" }.joined(separator: " ")
        let caret = (words as NSString).range(of: "word200").location
        let result = excerpt([ScreenTextSegment(kind: .focused, text: words, order: 0, caretOffset: caret)])
        XCTAssertTrue(result.hasPrefix("word"), result)
        XCTAssertFalse(result.hasSuffix(" "))
        let first = result.split(separator: " ").first.map(String.init) ?? ""
        XCTAssertTrue(words.split(separator: " ").contains(Substring(first)), "the leading partial word is dropped")
    }

    func testExcerptOrderingCapsSelectionAndRedaction() {
        let segments = [
            ScreenTextSegment(kind: .focused, text: "Reply to Alice about SELECTED PART here", order: 0, caretOffset: 5),
            ScreenTextSegment(kind: .windowTitle, text: "Chat — Fixture", order: 1),
            ScreenTextSegment(kind: .neighbour, text: "Alice: card 4111111111111111 works\nAlice: password is hunter2", order: 2),
            ScreenTextSegment(kind: .control, text: "Send", order: 3),
            ScreenTextSegment(kind: .heading, text: "Project room", order: 4),
            ScreenTextSegment(kind: .body, text: "key AKfixture0123456789abcdefXYZ shown\nsee https://example.invalid/page\nShared line", order: 5),
            ScreenTextSegment(kind: .ocrLine, text: "Shared line", order: 6)
        ]
        let result = excerpt(segments, selection: "SELECTED PART")
        XCTAssertEqual(result.components(separatedBy: "\n"), [
            "Reply to Alice about  here",
            "Title: Chat — Fixture · Project room",
            "Alice: card [number] works",
            "key [redacted] shown",
            "Shared line"
        ])
        XCTAssertFalse(result.contains("Send"), "controls never reach the excerpt")
        let body = (0..<300).map { ScreenTextSegment(kind: .body, text: "Body line number \($0) with filler text", order: $0) }
        XCTAssertEqual(excerpt(body).count, 1_500)
        XCTAssertLessThanOrEqual(excerpt(body, limit: 100).count, 100)
        XCTAssertEqual(excerpt(body, limit: 0), "")
    }

    // MARK: Cache

    func testCacheExpiryEvictionAndRemoval() {
        var cache = ScreenContextCache()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let item = snapshot([ScreenTerm(text: "CacheKit", kind: .camelCase)])
        cache.store(item, key: ScreenContextCache.key(pid: 12, windowID: 1), now: t0)
        XCTAssertEqual(cache.snapshot(for: "12:1", now: t0.addingTimeInterval(59)), item)
        XCTAssertNil(cache.snapshot(for: "12:1", now: t0.addingTimeInterval(60)))
        XCTAssertEqual(cache.count, 0)
        for window in 1...5 { cache.store(item, key: "12:\(window)", now: t0) }
        XCTAssertEqual(cache.count, 4)
        XCTAssertNil(cache.snapshot(for: "12:1", now: t0), "oldest entry evicted")
        cache.store(item, key: "123:1", now: t0)
        cache.remove(pid: 12)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.snapshot(for: "123:1", now: t0))
        cache.clear()
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: Writing context, snapshots and scans

    func testWritingContextModeMatrix() {
        let terms = [ScreenTerm(text: "章山", kind: .cjkRun)] + (0..<50).map { ScreenTerm(text: "WriteKit\($0)", kind: .camelCase) }
        let item = ScreenContextSnapshot(sources: [.ocr], bundleID: "b", applicationName: "A", excerpt: "Nearby text", terms: terms)
        for mode in [WritingMode.polish, .translate] {
            let context = ScreenWritingContext(snapshot: item, mode: mode)
            XCTAssertEqual(context?.excerpt, "Nearby text"); XCTAssertEqual(context?.terms.count, 40)
            XCTAssertEqual(context?.source, .ocr); XCTAssertFalse(context?.terms.contains("章山") ?? true)
        }
        let edit = ScreenWritingContext(snapshot: item, mode: .edit)
        XCTAssertEqual(edit?.excerpt, ""); XCTAssertEqual(edit?.terms.first, "WriteKit0")
        XCTAssertNil(ScreenWritingContext(snapshot: item, mode: .verbatim))
        XCTAssertNil(ScreenWritingContext(snapshot: item, mode: .ask))
        let lowOnly = ScreenContextSnapshot(sources: [.accessibility], bundleID: "b", applicationName: "A", excerpt: "Text",
                                            terms: [ScreenTerm(text: "章山", kind: .cjkRun)])
        XCTAssertNil(ScreenWritingContext(snapshot: lowOnly, mode: .edit))
        XCTAssertEqual(ScreenWritingContext(snapshot: lowOnly, mode: .polish)?.terms, [])
    }

    func testSnapshotMakeAndMerge() {
        let collection = ScreenTextCollection(segments: [ScreenTextSegment(kind: .body, text: "Use VoiceDraft with ZetaKit today.", order: 0)],
                                              nodesVisited: 3, charactersCollected: 34)
        let made = ScreenContextSnapshot.make(collection: collection, source: .accessibility, bundleID: "com.fixture", applicationName: "Fixture",
                                              vocabulary: AppVocabulary(words: "VoiceDraft"), now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(made?.terms.map(\.text), ["ZetaKit"], "existing vocabulary is excluded")
        XCTAssertEqual(made?.excerpt, "Use VoiceDraft with ZetaKit today.")
        XCTAssertEqual(made?.nodesVisited, 3)
        XCTAssertNil(ScreenContextSnapshot.make(collection: ScreenTextCollection(), source: .ocr, bundleID: "b", applicationName: "A", vocabulary: AppVocabulary()))

        let ax = ScreenContextSnapshot(sources: [.accessibility], bundleID: "b", applicationName: "A", excerpt: "A line\nShared",
                                       terms: [ScreenTerm(text: "VoiceDraft", kind: .camelCase), ScreenTerm(text: "章山", kind: .cjkRun)],
                                       nodesVisited: 2, capturedAt: Date(timeIntervalSince1970: 1))
        let ocr = ScreenContextSnapshot(sources: [.ocr], bundleID: "b", applicationName: "A", excerpt: "Shared\nB line",
                                        terms: [ScreenTerm(text: "voicedraft", kind: .camelCase), ScreenTerm(text: "Figma", kind: .embeddedLatin)],
                                        truncated: true, capturedAt: Date(timeIntervalSince1970: 2))
        let merged = ScreenContextSnapshot.merged(ax, ocr)
        XCTAssertEqual(merged?.sources, [.accessibility, .ocr])
        XCTAssertEqual(merged?.excerpt, "A line\nShared\nB line")
        XCTAssertEqual(merged?.terms.map(\.text), ["VoiceDraft", "Figma", "章山"])
        XCTAssertEqual(merged?.truncated, true); XCTAssertEqual(merged?.capturedAt, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(ScreenContextSnapshot.merged(nil, ocr), ocr)
        XCTAssertEqual(ScreenContextSnapshot.merged(ax, nil), ax)
        XCTAssertNil(ScreenContextSnapshot.merged(nil, nil))
    }

    func testScanCandidatesFitTheFilterPrecondition() {
        let lines = (0..<260).map { "Mention ScanKit\($0)A here" }.joined(separator: "\n")
        let collection = ScreenTextCollection(segments: [ScreenTextSegment(kind: .body, text: lines, order: 0),
                                                         ScreenTextSegment(kind: .body, text: "VoiceDraft too", order: 1)])
        let scan = ScreenContextScan.make(collections: [collection], source: .accessibility, applicationName: "Fixture",
                                          vocabulary: AppVocabulary(words: "VoiceDraft"))
        XCTAssertEqual(scan.candidates.count, 200)
        XCTAssertTrue(scan.limited)
        XCTAssertTrue(scan.candidates.allSatisfy { $0.sources.isEmpty && !$0.isProject && (2...64).contains($0.text.count) })
        XCTAssertFalse(scan.candidates.contains { $0.text == "VoiceDraft" })
        XCTAssertEqual(scan.source, .accessibility); XCTAssertEqual(scan.applicationName, "Fixture")
    }
}
