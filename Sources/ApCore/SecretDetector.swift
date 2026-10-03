import Foundation

/// Detects known token formats. Matching content is treated as concealed
public enum SecretDetector {
    /// Each rule has a literal anchor that every match starts with. The anchor is found with a fast literal
    /// search and the regex only runs on a short window there, so large text costs a linear scan, not six regex passes
    static let rules: [(anchor: String, regex: NSRegularExpression)] = [
        ("ghp_", #"\bghp_[A-Za-z0-9]{30,}"#),
        ("github_pat_", #"\bgithub_pat_[A-Za-z0-9_]{30,}"#),
        ("sk-", #"\bsk-(ant-|proj-|live-|test-)?[A-Za-z0-9_\-]{20,}"#),
        ("AKIA", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("-----BEGIN ", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("xox", #"\bxox[baprs]-[A-Za-z0-9\-]{8,}"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// Longest match the window must hold (anchor + body); longer tokens still match on their first part
    static let windowLength = 256

    public static func containsSecret(_ content: String) -> Bool {
        let text = NSString(string: content)
        for rule in rules {
            var searchStart = 0
            while searchStart < text.length {
                let found = text.range(
                    of: rule.anchor, options: .literal,
                    range: NSRange(location: searchStart, length: text.length - searchStart))
                if found.location == NSNotFound { break }
                // Include one preceding character so \b sees the real boundary
                let windowStart = max(found.location - 1, 0)
                let window = text.substring(
                    with: NSRange(location: windowStart, length: min(windowLength, text.length - windowStart)))
                if rule.regex.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)) != nil {
                    return true
                }
                searchStart = found.location + found.length
            }
        }
        return false
    }
}
