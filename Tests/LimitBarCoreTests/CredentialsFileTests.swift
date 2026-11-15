import Darwin
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

    @Test func symlinkIsUnreadable() throws {
        let target = try tempFile(Data(#"{"a":1}"#.utf8))
        defer { try? FileManager.default.removeItem(at: target) }
        let link = try tempFile(nil)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(throws: UsageError.credentialsUnreadable(cli: "codex")) {
            try HTTP.readCredentialsFile(at: link, cli: "codex")
        }
    }

    @Test func fifoIsRejectedWithoutBlocking() throws {
        let url = try tempFile(nil)
        try #require(mkfifo(url.path, 0o600) == 0)
        defer { try? FileManager.default.removeItem(at: url) }
        // A future blocking-open regression is released after two seconds instead of hanging
        // the test runner forever. No real credential paths are involved.
        let unblock = DispatchWorkItem {
            let writer = open(url.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 { close(writer) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: unblock)
        defer { unblock.cancel() }
        let start = ContinuousClock.now
        #expect(throws: UsageError.credentialsUnreadable(cli: "grok")) {
            try HTTP.readCredentialsFile(at: url, cli: "grok")
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }
}
