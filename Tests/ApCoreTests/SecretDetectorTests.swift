import Testing
@testable import ApCore

@Suite struct SecretDetectorTests {
    @Test(arguments: [
        "token: ghp_" + String(repeating: "a", count: 36),
        "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz",
        "OPENAI_API_KEY=sk-" + String(repeating: "x", count: 40),
        "sk-ant-api03-" + String(repeating: "Z", count: 40),
        "AKIAIOSFODNN7EXAMPLE",
        "-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----",
        "SLACK=xoxb-1234-5678-abcdef",
    ])
    func detects(_ content: String) {
        #expect(SecretDetector.containsSecret(content))
    }

    @Test(arguments: [
        "hello world",
        "risk-free task-runner sk-",
        "AKIA is a prefix",
        "-----BEGIN PUBLIC KEY-----",
        "ghp_short",
    ])
    func ignores(_ content: String) {
        #expect(!SecretDetector.containsSecret(content))
    }
}

@Suite struct SecretDetectorLargeInputTests {
    @Test func detectsSecretDeepInLargeText() {
        let filler = String(repeating: "a risk-free task-runner line\n", count: 10_000)
        #expect(SecretDetector.containsSecret(filler + "key AKIAIOSFODNN7EXAMPLE\n" + filler))
        #expect(!SecretDetector.containsSecret(filler))
    }
}
