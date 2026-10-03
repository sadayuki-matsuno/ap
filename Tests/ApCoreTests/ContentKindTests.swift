import Testing
@testable import ApCore

@Suite struct ContentKindTests {
    @Test func url() {
        #expect(ContentKind.classify("https://example.com/path?q=1") == .url)
        #expect(ContentKind.classify("  http://localhost:8080 \n") == .url)
    }

    @Test func json() {
        #expect(ContentKind.classify(#"{"a": 1, "b": [1, 2]}"#) == .json)
        #expect(ContentKind.classify("[1, 2, 3]") == .json)
    }

    @Test func invalidJsonIsNotJson() {
        #expect(ContentKind.classify("{not json") != .json)
    }

    @Test func markdown() {
        #expect(ContentKind.classify("## Summary\n\nThis PR…\n\n- item 1\n- item 2") == .markdown)
        #expect(ContentKind.classify("Explanation\n\n```swift\nlet a = 1\n```\n") == .markdown)
    }

    @Test func code() {
        #expect(ContentKind.classify("SELECT id, status FROM orders WHERE id = 1;") == .code)
        #expect(ContentKind.classify("func main() {\n    print(\"hi\")\n}") == .code)
        #expect(ContentKind.classify("git worktree add ../x -b feat main && cd ../x") == .code)
    }

    @Test func text() {
        #expect(ContentKind.classify("Thanks. Re #1745, the root cause was a double launch.") == .text)
        // Japanese prose with the ideographic full stop (U+3002) and "&&"-like symbols stays text
        #expect(ContentKind.classify("\u{539F}\u{56E0}\u{306F} A && B \u{3067}\u{3057}\u{305F}\u{3002}") == .text)
        #expect(ContentKind.classify("hello") == .text)
    }
}
