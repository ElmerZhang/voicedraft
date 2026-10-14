import Foundation

/// Small, curated starter packs. Nothing is added until the user reviews and continues.
public enum VocabularyDomain: String, CaseIterable, Identifiable, Sendable {
    case artificialIntelligence, software, design, data, hardware, research
    public var id: String { rawValue }
    public var terms: [String] {
        switch self {
        case .artificialIntelligence: return ["ChatGPT", "Claude", "OpenAI", "Anthropic", "DeepSeek", "Qwen", "Gemini", "Llama", "Ollama", "LangChain", "Hugging Face", "vLLM"]
        case .software: return ["GitHub", "GitLab", "TypeScript", "JavaScript", "SwiftUI", "Kotlin", "PostgreSQL", "Kubernetes", "Docker", "Redis", "Next.js", "SQLite"]
        case .design: return ["Figma", "FigJam", "Framer", "Webflow", "Axure", "ProtoPie", "Notion", "Midjourney", "Blender", "InDesign", "Photoshop"]
        case .data: return ["NumPy", "pandas", "PyTorch", "TensorFlow", "scikit-learn", "Jupyter", "Matplotlib", "Seaborn", "Polars", "ClickHouse", "Apache Spark", "Databricks"]
        case .hardware: return ["ESP32", "STM32", "Raspberry Pi", "Arduino", "KiCad", "Altium Designer", "FreeRTOS", "MicroPython", "PlatformIO", "Verilog"]
        case .research: return ["Zotero", "EndNote", "LaTeX", "arXiv", "Overleaf", "PubMed", "Crossref", "MathType", "Wolfram Mathematica"]
        }
    }
}

public struct DomainVocabularySelection {
    public var domains: Set<VocabularyDomain>
    private var excluded: Set<String> = []
    public init(domains: Set<VocabularyDomain> = []) { self.domains = domains }
    public var terms: [String] {
        var seen = Set<String>()
        return VocabularyDomain.allCases.filter { domains.contains($0) }.flatMap(\.terms)
            .filter { seen.insert(AppVocabulary.automaticTermKey($0)).inserted }
    }
    public func isSelected(_ term: String) -> Bool { !excluded.contains(AppVocabulary.automaticTermKey(term)) }
    public mutating func select(_ term: String, enabled: Bool) {
        let key = AppVocabulary.automaticTermKey(term)
        if enabled { excluded.remove(key) } else { excluded.insert(key) }
    }
    public static func knownTerms(in vocabulary: AppVocabulary) -> Set<String> {
        Set(vocabulary.entries.flatMap { [$0.text, $0.displayAs] + $0.aliases }.map(AppVocabulary.automaticTermKey))
    }
    public func additions(to vocabulary: AppVocabulary) -> [VocabularyEntry] {
        let known = Self.knownTerms(in: vocabulary)
        return terms.filter { isSelected($0) && !known.contains(AppVocabulary.automaticTermKey($0)) }
            .map { VocabularyEntry(text: $0) }
    }
    public func merge(into vocabulary: inout AppVocabulary) throws {
        let entries = additions(to: vocabulary)
        for entry in entries { try entry.validate() }
        vocabulary.entries.append(contentsOf: entries)
    }
}
