import Foundation

/// Reads declarations as data only. Never executes a manifest or searches the repository.
enum ProjectVocabulary {
    static let manifests = ["package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod"]
    private static let generic: Set<String> = ["app", "apps", "src", "source", "sources", "test", "tests", "example", "examples", "server", "client", "web", "main", "master", "project", "projects", "workspace", "workspaces", "work", "home", "users", "desktop", "documents", "downloads", "tmp", "temp", "build", "dist", "packages"]

    static func name(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...64).contains(value.count), !generic.contains(value.lowercased()),
              value.first?.isLetter == true,
              value.allSatisfy({ $0.isLetter || $0.isNumber || " ._-+".contains($0) }),
              !value.contains("..") else { return nil }
        return value
    }

    static func declaredName(data: Data, filename: String) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var raw: String?
        switch filename {
        case "package.json":
            raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String
            if let scoped = raw, scoped.hasPrefix("@"), scoped.split(separator: "/").count == 2 {
                raw = scoped.split(separator: "/").last.map(String.init)
            }
        case "Package.swift":
            raw = capture(#"\bPackage\s*\(\s*name\s*:\s*"([^"\r\n]+)""#, text)
        case "Cargo.toml", "pyproject.toml":
            let section = filename == "Cargo.toml" ? "package" : "project"
            var active = false
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { active = trimmed.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == "[\(section)]" }
                if active, let value = capture(#"^\s*name\s*=\s*["']([^"'\r\n]+)["']\s*(?:#.*)?$"#, line) { raw = value; break }
            }
        case "go.mod":
            if let module = capture(#"(?m)^\s*module\s+([^\s]+)"#, text) {
                var parts = module.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: "/")
                if parts.count > 1, parts.last?.range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil { parts.removeLast() }
                raw = parts.last.map(String.init)
            }
        default: break
        }
        return raw.flatMap(name)
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
