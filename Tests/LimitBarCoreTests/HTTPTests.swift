import Foundation
import Network
import Testing
@testable import LimitBarCore

/// A loopback-only HTTP server with an ephemeral port and a fixed response. Each accepted
/// connection is counted, so redirect tests can detect requests even without reading headers.
private final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LimitBar.HTTPTests.\(UUID().uuidString)")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var count = 0
    private let response: Data
    private var port: NWEndpoint.Port { listener.port! }

    var requestCount: Int { lock.withLock { count } }
    var url: URL { URL(string: "http://127.0.0.1:\(port.rawValue)/")! }

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        var header = "HTTP/1.1 \(status) Test\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { header += "\(name): \(value)\r\n" }
        response = Data((header + "\r\n").utf8) + body
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock {
                self.count += 1
                self.connections.append(connection)
            }
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection, data: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    private func receiveRequest(on connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            let request = data + (chunk ?? Data())
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                connection.send(content: self.response, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil || request.count > 16_384 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, data: request)
            }
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }
}

@Suite struct HTTPTests {
    @Test func refusesRedirectWithCredentialHeaders() async throws {
        let target = try LocalHTTPServer()
        defer { target.stop() }
        let origin = try LocalHTTPServer(status: 302, headers: ["Location": target.url.absoluteString])
        defer { origin.stop() }
        do {
            _ = try await HTTP.get(origin.url, headers: [
                "Authorization": "Bearer TOKEN-SENTINEL",
                "chatgpt-account-id": "ACCOUNT-SENTINEL",
            ], cli: "codex")
            Issue.record("Expected HTTP 302 instead of a followed redirect")
        } catch let error as UsageError {
            #expect(error == .http(status: 302))
        }
        #expect(origin.requestCount == 1)
        #expect(target.requestCount == 0)
    }

    @Test func acceptsResponseAtSizeLimit() async throws {
        let body = Data(repeating: 0x61, count: HTTP.maxSize)
        let server = try LocalHTTPServer(body: body)
        defer { server.stop() }
        #expect(try await HTTP.get(server.url, headers: [:], cli: "test") == body)
    }

    @Test func rejectsResponseAboveSizeLimit() async throws {
        let server = try LocalHTTPServer(body: Data(repeating: 0x61, count: HTTP.maxSize + 1))
        defer { server.stop() }
        do {
            _ = try await HTTP.get(server.url, headers: [:], cli: "test")
            Issue.record("Expected an oversized response to be rejected")
        } catch let error as UsageError {
            #expect(error == .badResponse)
        }
    }

    @Test(arguments: [401, 403])
    func authFailureMeansSessionExpired(status: Int) async throws {
        let server = try LocalHTTPServer(status: status)
        defer { server.stop() }
        await #expect(throws: UsageError.sessionExpired(cli: "codex")) {
            try await HTTP.get(server.url, headers: [:], cli: "codex")
        }
    }

    @Test func serverErrorKeepsStatus() async throws {
        let server = try LocalHTTPServer(status: 500)
        defer { server.stop() }
        await #expect(throws: UsageError.http(status: 500)) {
            try await HTTP.get(server.url, headers: [:], cli: "codex")
        }
    }
}
