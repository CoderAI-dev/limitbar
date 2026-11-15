import Foundation

enum HTTP {
    /// Upper bound for response bodies and credential data; real payloads are a few KB.
    static let maxSize = 1 << 20

    /// None of the endpoints redirect. Refusing redirects keeps every header (tokens, account
    /// IDs) on the provider's own host; the 3xx response then surfaces as an HTTP error.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// GETs `url` and returns the body. Never includes header values in errors.
    static func get(_ url: URL, headers: [String: String], cli: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("LimitBar", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: break
            case 401, 403: throw UsageError.sessionExpired(cli: cli)
            default: throw UsageError.http(status: status)
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxSize { throw UsageError.badResponse }
            }
            return data
        } catch let error as URLError {
            throw UsageError.network(error.code == .timedOut ? "Request timed out" : "Network error (\(error.code.rawValue))")
        }
    }

    /// Reads a JSON credentials file from the home directory.
    static func readHomeFile(_ relativePath: String, cli: String) throws -> Data {
        try readCredentialsFile(at: FileManager.default.homeDirectoryForCurrentUser.appending(path: relativePath), cli: cli)
    }

    /// Reads at most `maxSize` bytes. Only a missing file means not signed in; any other failure,
    /// including an oversized file, is an unreadable login.
    static func readCredentialsFile(at url: URL, cli: String) throws -> Data {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxSize + 1) ?? Data()
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            throw UsageError.notSignedIn(cli: cli)
        } catch {
            throw UsageError.credentialsUnreadable(cli: cli)
        }
        guard data.count <= maxSize else { throw UsageError.credentialsUnreadable(cli: cli) }
        return data
    }
}

func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) } catch { throw UsageError.badResponse }
}
