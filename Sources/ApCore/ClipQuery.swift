import Foundation

/// A picker search: plain text plus `repo:` / `session:` / `kind:` / `pinned` filters
public struct ClipQuery: Sendable, Equatable {
    /// Matched against content, label and prompt (concealed content is never matched)
    public var text: String
    /// Substring of the clip's or its session's repository
    public var repository: String?
    /// Substring of the session title
    public var session: String?
    /// A ContentKind raw value (lowercased)
    public var kind: String?
    public var pinnedOnly: Bool

    public init(
        text: String = "", repository: String? = nil, session: String? = nil, kind: String? = nil,
        pinnedOnly: Bool = false
    ) {
        self.text = text
        self.repository = repository
        self.session = session
        self.kind = kind
        self.pinnedOnly = pinnedOnly
    }

    /// Whitespace separates terms and double quotes group them (`session:"api refactor"`).
    /// Filters with an empty value are dropped (the user is still typing); unknown prefixes stay text
    public static func parse(_ input: String) -> ClipQuery {
        var terms: [String] = []
        var current = ""
        var inQuotes = false
        var hasTerm = false
        for character in input {
            if character == "\"" {
                inQuotes.toggle()
                hasTerm = true
            } else if character.isWhitespace && !inQuotes {
                if hasTerm { terms.append(current) }
                current = ""
                hasTerm = false
            } else {
                current.append(character)
                hasTerm = true
            }
        }
        if hasTerm { terms.append(current) }

        var query = ClipQuery()
        var words: [String] = []
        for term in terms {
            if term.lowercased() == "pinned" {
                query.pinnedOnly = true
                continue
            }
            let parts = term.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, ["repo", "session", "kind"].contains(parts[0].lowercased()) else {
                if !term.isEmpty { words.append(term) }
                continue
            }
            let value = String(parts[1])
            guard !value.isEmpty else { continue }
            switch parts[0].lowercased() {
            case "repo": query.repository = value
            case "session": query.session = value
            default: query.kind = value.lowercased()
            }
        }
        query.text = words.joined(separator: " ")
        return query
    }
}
