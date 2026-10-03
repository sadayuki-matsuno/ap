import Foundation

/// Rough content-kind heuristic (for list display and filtering; not meant to be exact)
public enum ContentKind: String, Sendable {
    case text, code, markdown, url, json

    /// Only this many leading bytes are inspected (regexes over megabytes dominated copy time)
    static let sampleBytes = 64 * 1024

    public static func classify(_ content: String) -> ContentKind {
        let isLarge = content.utf8.count > sampleBytes
        // A cut in the middle of a scalar only yields a trailing replacement character, which is harmless here
        let sample = isLarge ? String(decoding: content.utf8.prefix(sampleBytes), as: UTF8.self) : content
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .text }

        if !isLarge, !trimmed.contains(where: \.isWhitespace),
           let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "file", "ssh"].contains(scheme), url.host != nil || scheme == "file" {
            return .url
        }

        // JSON needs the whole text; JSONSerialization is fast even for megabytes
        if let first = trimmed.first, first == "{" || first == "[",
           let data = content.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            return .json
        }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        let markdownLines = lines.filter { line in
            let stripped = line.drop(while: { $0 == " " })
            return stripped.hasPrefix("# ") || stripped.hasPrefix("## ") || stripped.hasPrefix("### ")
                || stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("> ")
                || stripped.hasPrefix("```") || stripped.hasPrefix("| ")
        }
        if trimmed.contains("```") || markdownLines.count >= 2 || trimmed.hasPrefix("#") && trimmed.contains("\n") {
            return .markdown
        }

        let codePatterns = [
            #"(?m)^\s*(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|WITH)\s"#,
            #"(?m)^\s*(git|cd|ls|cat|echo|curl|gh|npm|yarn|pnpm|make|swift|go|docker|kubectl|brew|sudo|export|python3?|node)\s"#,
            #"\b(func|def|class|struct|import|package|return|const|let|var|fn)\b.*[{(=:]"#,
            #"(?m)(&&|\|\||;\s*$|\{\s*$|=>|->)"#,
        ]
        for pattern in codePatterns
        where trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            // Japanese prose that merely contains these symbols stays text (U+3002 is the ideographic full stop)
            if pattern.hasPrefix(#"(?m)(&&"#), trimmed.contains("\u{3002}") { continue }
            return .code
        }
        return .text
    }
}
