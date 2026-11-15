import Darwin
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
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw UsageError.network(error.code == .timedOut ? "Request timed out" : "Network error (\(error.code.rawValue))")
        }
    }

    /// Reads a JSON credentials file from the home directory.
    static func readHomeFile(_ relativePath: String, cli: String) throws -> Data {
        try readCredentialsFile(at: FileManager.default.homeDirectoryForCurrentUser.appending(path: relativePath), cli: cli)
    }

    /// Opens only regular files, without following symlinks or blocking on FIFOs. Only a missing
    /// file means not signed in; all other failures, including oversized files, are unreadable.
    static func readCredentialsFile(at url: URL, cli: String) throws -> Data {
        let (descriptor, openError) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            return (descriptor, errno)
        }
        guard descriptor >= 0 else {
            if openError == ENOENT { throw UsageError.notSignedIn(cli: cli) }
            throw UsageError.credentialsUnreadable(cli: cli)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw UsageError.credentialsUnreadable(cli: cli)
        }
        let data: Data
        do {
            data = try handle.read(upToCount: maxSize + 1) ?? Data()
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
