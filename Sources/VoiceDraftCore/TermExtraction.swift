import Foundation
import NaturalLanguage

/// Local, pure term extraction shared by agent-context discovery (C6) and
/// on-screen context. `.agentContext` reproduces the C6 heuristic exactly;
/// `.screenContext` adds screen-only rules and rejection filters.
public enum TermExtractor {
    public struct Options: Sendable, Equatable {
        /// false = exact C6 behaviour.
        public var screen: Bool
        public init(screen: Bool) { self.screen = screen }
        public static let agentContext = Options(screen: false)
        public static let screenContext = Options(screen: true)
    }

    public struct Candidate: Equatable, Sendable {
        public let text: String
        public let kind: ScreenTerm.Kind
        public let count: Int
        /// UTF-16 offset of the first occurrence in the filtered text (ordering only).
        public let firstOffset: Int
        public init(text: String, kind: ScreenTerm.Kind, count: Int, firstOffset: Int) {
            self.text = text; self.kind = kind; self.count = count; self.firstOffset = firstOffset
        }
    }

    // MARK: Shared line filter

    private static let unsafeLineMarkers = ["api_key", "api-key", "secret", "password", "bearer ", "private key", "token=", "https://", "http://"]

    static func isUnsafeLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return unsafeLineMarkers.contains { lower.contains($0) }
    }

    /// Drops lines containing credential or URL markers. Shared by both callers.
    public static func safeLines(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !isUnsafeLine($0) }.joined(separator: "\n")
    }

    public static func candidates(in text: String, options: Options) throws -> [Candidate] {
        options.screen ? try screenCandidates(text) : try agentCandidates(text)
    }

    // MARK: Stoplists (reviewable constants)

    /// Generic acronyms that mirror the C6 filter prompt.
    public static let acronymStoplist: Set<String> = [
        "PR", "UI", "API", "AI", "SDK", "HTTP", "HTTPS", "URL", "JSON", "HTML", "CSS", "PDF", "README", "TODO", "OK", "ID", "FAQ", "AM", "PM"
    ]

    /// Common window chrome and UI words, compared case-insensitively.
    public static let englishUIStoplist: Set<String> = Set([
        "ok", "cancel", "file", "edit", "view", "window", "help", "settings", "search", "send", "reply", "share", "done", "new", "open",
        "save", "close", "today", "yesterday", "tomorrow", "inbox", "back", "forward", "next", "previous", "delete", "remove", "add", "more",
        "less", "home", "menu", "insert", "format", "tools", "preferences", "options", "undo", "redo", "copy", "paste", "cut", "select",
        "all", "find", "replace", "print", "export", "import", "sign", "in", "out", "log", "login", "logout", "account", "profile",
        "notifications", "messages", "message", "chat", "chats", "contacts", "calendar", "mail", "archive", "trash", "draft", "drafts",
        "sent", "favorites", "recent", "recents", "downloads", "documents", "desktop", "apply", "continue", "submit", "yes", "no",
        "loading", "untitled", "show", "hide", "sort", "filter", "refresh", "update", "upload", "download", "like", "follow", "comment",
        "comments", "edited", "online", "offline", "pinned", "mute", "unread", "read", "the", "and", "or", "of", "to", "for", "on", "at",
        "by", "with", "from", "this", "that", "you", "we", "it", "is", "are", "was", "be", "not"
    ])

    /// Chinese UI words and function words that are never useful terms.
    public static let cjkStoplist: Set<String> = [
        "发送", "搜索", "设置", "取消", "确定", "文件", "编辑", "我们", "这个", "那个", "可以", "没有", "什么", "已经", "今天", "昨天",
        "明天", "你们", "他们", "她们", "它们", "自己", "大家", "时候", "现在", "然后", "但是", "因为", "所以", "如果", "虽然", "还是",
        "或者", "而且", "不是", "就是", "只是", "还有", "一下", "一个", "一些", "这些", "那些", "这样", "那样", "怎么", "为什么", "哪里",
        "这里", "那里", "知道", "觉得", "应该", "需要", "可能", "正在", "开始", "结束", "问题", "东西", "事情", "时间", "地方", "今年",
        "去年", "明年", "上午", "下午", "晚上", "早上", "刚才", "马上", "好的", "谢谢", "没事", "可是", "这么", "那么", "多少", "几个",
        "一样", "一起", "一直", "非常", "比较", "特别", "其实", "当然", "确实", "真的", "一定", "不要", "不用", "不会", "不能", "能够",
        "就要", "还要", "回复", "转发", "分享", "删除", "复制", "粘贴", "撤销", "保存", "打开", "关闭", "新建", "返回", "首页", "消息",
        "通知", "联系人", "收藏", "更多", "全部", "查看", "详情", "登录", "退出", "帮助", "窗口", "视图", "格式", "工具", "文本", "输入",
        "完成", "下载", "上传", "刷新", "星期", "已读", "未读", "置顶", "表情", "图片", "语音", "视频", "链接", "评论", "点赞", "关注"
    ]

    /// Single Han characters that do not start or end a repeated n-gram term.
    static let cjkEdgeFunctionCharacters: Set<Character> = Set("的了是在和与及或把被我你他她它们这那就也都还又很吗呢吧啊着过给从对向说个有不")

    // MARK: C6 (agent context)

    private static let c6Pattern = #"(?<![A-Za-z0-9_-])(?:[A-Z][a-z]+(?:[A-Z][A-Za-z0-9]*)+|[A-Z]{2,12}|[A-Za-z]{2,20}_[A-Za-z_]{2,30})(?![A-Za-z0-9_-])"#

    private static func agentCandidates(_ source: String) throws -> [Candidate] {
        // Avoid lines containing credentials/URLs and cap the proposed list. The user reviews every import.
        let text = safeLines(source)
        var tally = Tally()
        let regex = try NSRegularExpression(pattern: c6Pattern)
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let range = Range(match.range, in: text) else { continue }
            let term = String(text[range])
            guard (2...64).contains(term.count) else { continue }
            let kind: ScreenTerm.Kind = term.contains("_") ? .identifier : term.allSatisfy(\.isUppercase) ? .acronym : .camelCase
            tally.add(term, kind: kind, offset: match.range.location)
        }
        // Quoted local terminology also covers Chinese product/project names.
        let quoted = try NSRegularExpression(pattern: #"[`「『]([\p{Han}A-Za-z0-9_]{2,24})[`」』]"#)
        for match in quoted.matches(in: text, range: range) {
            guard let termRange = Range(match.range(at: 1), in: text) else { continue }
            tally.add(String(text[termRange]), kind: .quoted, offset: match.range(at: 1).location)
        }
        return Array(tally.candidates.sorted { $0.count == $1.count ? $0.text < $1.text : $0.count > $1.count }.prefix(200))
    }

    // MARK: Screen

    private static let screenScrub = try! NSRegularExpression(pattern: #"\S*(?:://|[/\\])\S*|\S+@\S+\.\S+|(?<!\S)~\S*"#)
    // \x{22} is the ASCII double quote (kept out of the raw literal for the localization checker).
    private static let quotedPattern = try! NSRegularExpression(pattern:
        #"“(?!\s)([^”\n]{2,24})(?<!\s)”|「(?!\s)([^」\n]{2,24})(?<!\s)」|『(?!\s)([^』\n]{2,24})(?<!\s)』|《(?!\s)([^》\n]{2,24})(?<!\s)》|\x{22}(?!\s)([^\x{22}\n]{2,24})(?<!\s)\x{22}|`(?!\s)([^`\n]{2,24})(?<!\s)`"#)
    private static let properNamePattern = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9_'’-])(?:[A-Z][a-z]+|[A-Z]{2,12})(?:[ ](?:[A-Z][a-z]+|[A-Z]{2,12})){1,3}(?![A-Za-z0-9_'’-])"#)
    private static let dottedPattern = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9_.-])[A-Za-z][A-Za-z0-9]*(?:[-.][A-Za-z0-9]+)+(?![A-Za-z0-9_-])(?!\.[A-Za-z0-9])"#)
    private static let wordPattern = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9_-])(?:([A-Za-z]{2,20}_[A-Za-z_]{2,30})|([A-Z][a-z]+(?:[A-Z][A-Za-z0-9]*)+|[a-z]{1,10}[A-Z][A-Za-z0-9]{1,30})|([A-Z]{2}[A-Z0-9]{0,10}))(?![A-Za-z0-9_-])"#)
    private static let latinTokenPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.-])[A-Za-z][A-Za-z0-9]{2,31}(?![A-Za-z0-9_.-])"#)
    private static let hanRunPattern = try! NSRegularExpression(pattern: #"\p{Han}{2,}"#)

    private static let rejectedSuffixes: Set<String> = [
        "com", "net", "org", "io", "cn", "dev", "app", "ai",
        "md", "txt", "swift", "json", "png", "pdf", "jpg", "jpeg", "gif", "svg", "html", "htm", "css", "js", "ts", "py", "go",
        "rs", "c", "h", "m", "mm", "cpp", "java", "kt", "rb", "sh", "yml", "yaml", "toml", "xml", "plist", "csv", "log", "zip",
        "gz", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "mov", "mp3", "mp4", "wav", "dmg", "pkg", "app", "exe", "lock"
    ]
    private static let leadingStopwords: Set<String> = [
        "The", "A", "An", "This", "That", "These", "Those", "Our", "My", "Your", "Their", "We", "I", "It", "In", "On", "At", "For",
        "To", "And", "Or", "But", "If", "When", "With", "From", "Hi", "Hello", "Dear", "Thanks", "Please", "So", "Then", "Also"
    ]

    private static func screenCandidates(_ source: String) throws -> [Candidate] {
        let filtered = safeLines(source)
        let text = screenScrub.stringByReplacingMatches(in: filtered, range: NSRange(filtered.startIndex..., in: filtered), withTemplate: " ")
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var tally = Tally()
        var claimed = IndexSet()
        func free(_ range: NSRange) -> Bool { !claimed.intersects(integersIn: range.location..<(range.location + range.length)) }
        func claim(_ range: NSRange) { claimed.insert(integersIn: range.location..<(range.location + range.length)) }

        // Quoted spans claim their quote marks and content.
        for match in quotedPattern.matches(in: text, range: full) {
            guard let inner = (1...6).lazy.map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
            let term = ns.substring(with: inner)
            guard !term.contains(where: { "。！？.!?".contains($0) }) else { continue }
            tally.add(term, kind: .quoted, offset: inner.location); claim(match.range)
        }
        // Proper names: 2-4 title-case words, leading function words removed.
        var properInitial: [String: Bool] = [:]
        for match in properNamePattern.matches(in: text, range: full) where free(match.range) {
            var words = ns.substring(with: match.range).split(separator: " ").map(String.init)
            var start = match.range.location
            while let first = words.first, leadingStopwords.contains(first) {
                start += (first as NSString).length + 1; words.removeFirst()
            }
            guard words.count >= 2 else { continue }
            let term = words.joined(separator: " ")
            let range = NSRange(location: start, length: (term as NSString).length)
            let initial = isSentenceInitial(ns, at: range.location) && !isSpeakerLabel(ns, after: range.location + range.length)
            properInitial[term] = (properInitial[term] ?? true) && initial
            tally.add(term, kind: .properName, offset: range.location); claim(range)
        }
        // Dotted or kebab identifiers.
        for match in dottedPattern.matches(in: text, range: full) where free(match.range) {
            let term = ns.substring(with: match.range)
            let segments = term.split(whereSeparator: { $0 == "-" || $0 == "." })
            let mixed = term.contains(where: \.isLetter) && term.contains(where: \.isNumber)
            guard mixed || segments.count >= 3 else { continue }
            if term.contains("."), let last = term.split(separator: ".").last, rejectedSuffixes.contains(last.lowercased()) { continue }
            tally.add(term, kind: .identifier, offset: match.range.location); claim(match.range)
        }
        // snake_case, camelCase and acronyms.
        for match in wordPattern.matches(in: text, range: full) where free(match.range) {
            let kind: ScreenTerm.Kind = match.range(at: 1).location != NSNotFound ? .identifier
                : match.range(at: 2).location != NSNotFound ? .camelCase : .acronym
            tally.add(ns.substring(with: match.range), kind: kind, offset: match.range.location); claim(match.range)
        }
        // Latin words embedded in Chinese text.
        for match in latinTokenPattern.matches(in: text, range: full) where free(match.range) {
            let term = ns.substring(with: match.range)
            guard term.filter(\.isLetter).count >= 3, term.first?.isUppercase == true || term.contains(where: \.isNumber),
                  isHan(ns, before: match.range.location) || isHan(ns, after: match.range.location + match.range.length) else { continue }
            tally.add(term, kind: .embeddedLatin, offset: match.range.location); claim(match.range)
        }
        for candidate in cjkRuns(ns, full: full, isFree: free) {
            tally.add(candidate.text, kind: .cjkRun, offset: candidate.firstOffset, count: candidate.count)
        }
        return tally.candidates.filter { candidate in
            if candidate.kind == .properName, properInitial[candidate.text] == true, candidate.count < 2 { return false }
            return isAcceptedScreenTerm(candidate.text)
        }.sorted { $0.firstOffset < $1.firstOffset }
    }

    /// Low-confidence repeated Han words. NLTokenizer splits unknown names such as
    /// personal names into single characters, so runs of single-character tokens
    /// also contribute repeated 2-4 character n-grams (substring-suppressed).
    private static func cjkRuns(_ ns: NSString, full: NSRange, isFree: (NSRange) -> Bool) -> [Candidate] {
        var words = Tally(), grams = Tally()
        let tokenizer = NLTokenizer(unit: .word)
        for match in hanRunPattern.matches(in: ns as String, range: full) where isFree(match.range) {
            let run = ns.substring(with: match.range)
            tokenizer.string = run
            tokenizer.setLanguage(.simplifiedChinese)
            var tokens: [(text: String, offset: Int)] = []
            tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
                tokens.append((String(run[range]), match.range.location + NSRange(range, in: run).location)); return true
            }
            var singles: [(text: String, offset: Int)] = []
            func flushSingles() {
                defer { singles.removeAll() }
                guard singles.count >= 2 else { return }
                for start in singles.indices {
                    for length in 2...4 where start + length <= singles.count {
                        let gram = singles[start..<(start + length)].map(\.text).joined()
                        guard let first = gram.first, let last = gram.last,
                              !cjkEdgeFunctionCharacters.contains(first), !cjkEdgeFunctionCharacters.contains(last) else { continue }
                        grams.add(gram, kind: .cjkRun, offset: singles[start].offset)
                    }
                }
            }
            for token in tokens {
                if token.text.count == 1 { singles.append(token); continue }
                flushSingles()
                if (2...6).contains(token.text.count), token.text.unicodeScalars.allSatisfy(isHanScalar) {
                    words.add(token.text, kind: .cjkRun, offset: token.offset)
                }
            }
            flushSingles()
        }
        let repeatedGrams = grams.candidates.filter { $0.count >= 2 }
        let maximalGrams = repeatedGrams.filter { gram in
            !repeatedGrams.contains { $0.text != gram.text && $0.count == gram.count && $0.text.contains(gram.text) }
        }
        var merged = Tally()
        for candidate in words.candidates.filter({ $0.count >= 2 }) + maximalGrams where !cjkStoplist.contains(candidate.text) {
            merged.add(candidate.text, kind: .cjkRun, offset: candidate.firstOffset, count: candidate.count)
        }
        return Array(merged.candidates.sorted { $0.count == $1.count ? $0.firstOffset < $1.firstOffset : $0.count > $1.count }.prefix(60))
    }

    /// Rejection filters applied to every screen-mode kind.
    static func isAcceptedScreenTerm(_ term: String) -> Bool {
        guard (2...64).contains(term.count), !term.contains(where: \.isNewline),
              term.split(whereSeparator: \.isWhitespace).count <= 4 else { return false }
        if term.range(of: #"^[vV]?[0-9][0-9.:/_-]*$"#, options: .regularExpression) != nil { return false }
        if term.count >= 7, term.allSatisfy(\.isHexDigit) { return false }
        if isSecretLike(term) { return false }
        if acronymStoplist.contains(term.uppercased()) && term == term.uppercased() { return false }
        let words = term.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        if words.allSatisfy(englishUIStoplist.contains) { return false }
        if cjkStoplist.contains(term) { return false }
        return true
    }

    /// At least 20 characters of `[A-Za-z0-9_+/=-]` mixing letters and digits.
    static func isSecretLike<S: StringProtocol>(_ token: S) -> Bool {
        guard token.count >= 20 else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+/=-")
        return token.allSatisfy(allowed.contains) && token.contains(where: \.isLetter) && token.contains(where: \.isNumber)
    }

    private static func isSentenceInitial(_ ns: NSString, at location: Int) -> Bool {
        var index = location - 1
        while index >= 0 {
            let c = ns.character(at: index)
            if c == 0x20 || c == 0x09 { index -= 1; continue }
            return [0x2E, 0x21, 0x3F, 0x0A, 0x3002, 0xFF01, 0xFF1F].contains(c)
        }
        return true
    }

    /// "Alice Chen: …" at a line start is a chat speaker label, not a sentence start.
    private static func isSpeakerLabel(_ ns: NSString, after location: Int) -> Bool {
        location < ns.length && (ns.character(at: location) == 0x3A || ns.character(at: location) == 0xFF1A)
    }

    private static func isHan(_ ns: NSString, before location: Int) -> Bool {
        var index = location - 1
        if index >= 0, ns.character(at: index) == 0x20 { index -= 1 }
        return index >= 0 && isHanUnit(ns.character(at: index))
    }

    private static func isHan(_ ns: NSString, after location: Int) -> Bool {
        var index = location
        if index < ns.length, ns.character(at: index) == 0x20 { index += 1 }
        return index < ns.length && isHanUnit(ns.character(at: index))
    }

    private static func isHanUnit(_ unit: unichar) -> Bool {
        (0x4E00...0x9FFF).contains(unit) || (0x3400...0x4DBF).contains(unit) || (0xF900...0xFAFF).contains(unit) || (0xD840...0xD87E).contains(unit)
    }

    static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x20000...0x3134F).contains(v)
    }
}

/// Counts occurrences by exact spelling; the first kind and offset win.
private struct Tally {
    private var index: [String: Int] = [:]
    private(set) var candidates: [TermExtractor.Candidate] = []
    mutating func add(_ text: String, kind: ScreenTerm.Kind, offset: Int, count: Int = 1) {
        if let i = index[text] {
            let old = candidates[i]
            candidates[i] = .init(text: text, kind: old.kind, count: old.count + count, firstOffset: min(old.firstOffset, offset))
        } else {
            index[text] = candidates.count
            candidates.append(.init(text: text, kind: kind, count: count, firstOffset: offset))
        }
    }
}
