import Foundation

enum HTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    /// GETs `url` and returns the body. Never includes header values in errors.
    static func get(_ url: URL, headers: [String: String], cli: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("LimitBar", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw UsageError.network(error.code == .timedOut ? "Request timed out" : "Network error (\(error.code.rawValue))")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw UsageError.sessionExpired(cli: cli)
        default: throw UsageError.http(status: status)
        }
    }

    /// Reads a JSON credentials file from the home directory.
    static func readHomeFile(_ relativePath: String, cli: String) throws -> Data {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: relativePath)
        guard let data = try? Data(contentsOf: url) else { throw UsageError.notSignedIn(cli: cli) }
        return data
    }
}

func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) } catch { throw UsageError.badResponse }
}
