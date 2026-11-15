import Foundation
import Testing
@testable import LimitBarCore

@Suite struct CredentialsFileTests {
    private func tempFile(_ data: Data?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "limitbar-test-\(UUID().uuidString).json")
        if let data { try data.write(to: url) }
        return url
    }

    @Test func readsFile() throws {
        let url = try tempFile(Data(#"{"a":1}"#.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try HTTP.readCredentialsFile(at: url, cli: "codex") == Data(#"{"a":1}"#.utf8))
    }

    @Test func missingFileIsNotSignedIn() throws {
        let url = try tempFile(nil)
        #expect(throws: UsageError.notSignedIn(cli: "codex")) { try HTTP.readCredentialsFile(at: url, cli: "codex") }
    }

    @Test func oversizedFileIsUnreadable() throws {
        let url = try tempFile(Data(count: HTTP.maxSize + 1))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: UsageError.credentialsUnreadable(cli: "grok")) { try HTTP.readCredentialsFile(at: url, cli: "grok") }
    }

    @Test func directoryIsUnreadable() throws {
        let url = FileManager.default.temporaryDirectory
        #expect(throws: UsageError.credentialsUnreadable(cli: "grok")) { try HTTP.readCredentialsFile(at: url, cli: "grok") }
    }
}
