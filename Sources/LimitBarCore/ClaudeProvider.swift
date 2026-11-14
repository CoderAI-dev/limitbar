import Foundation

public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude
    public init() {}

    public func fetch() async throws -> ProviderSnapshot {
        let (token, plan) = try readCredentials()
        let data = try await HTTP.get(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"],
            cli: id.cliName
        )
        let snapshot = try Self.parse(data, now: Date())
        return ProviderSnapshot(windows: snapshot.windows, plan: plan, fetchedAt: snapshot.fetchedAt)
    }

    private func readCredentials() throws -> (token: String, plan: String?) {
        // Use the `security` CLI rather than SecItem: it is already on the item's ACL, so there is no
        // prompt, whereas an ad-hoc-signed app would be re-prompted after every rebuild.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UsageError.notSignedIn(cli: id.cliName) }
        // An unanswered keychain prompt would block forever; kill the process after 2 minutes, which
        // leaves time to type the keychain password. Other providers' states update meanwhile.
        let timeout = DispatchWorkItem { [process] in process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        // Read to EOF before waiting so a full pipe cannot deadlock; EOF arrives on exit or kill.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        if process.terminationReason == .uncaughtSignal { throw UsageError.keychainTimeout }

        struct Credentials: Decodable {
            struct OAuth: Decodable { let accessToken: String; let subscriptionType: String? }
            let claudeAiOauth: OAuth
        }
        guard process.terminationStatus == 0,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: output)
        else { throw UsageError.notSignedIn(cli: id.cliName) }
        return (credentials.claudeAiOauth.accessToken, credentials.claudeAiOauth.subscriptionType)
    }

    private struct Response: Decodable {
        struct Window: Decodable { let utilization: Double; let resets_at: String? }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let display_name: String? }
                let model: Model?
            }
            let group: String?
            let percent: Double
            let resets_at: String?
            let scope: Scope?
        }
        let five_hour: Window?
        let seven_day: Window?
        let limits: [Limit]?
    }

    public static func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        let response = try decode(Response.self, from: data)
        var windows: [LimitWindow] = []
        if let w = response.five_hour {
            windows.append(LimitWindow(label: "5h", usedPercent: w.utilization, resetsAt: w.resets_at.flatMap(parseISO8601), duration: 18_000))
        }
        if let w = response.seven_day {
            windows.append(LimitWindow(label: "Week", usedPercent: w.utilization, resetsAt: w.resets_at.flatMap(parseISO8601), duration: 604_800))
        }
        for limit in response.limits ?? [] {
            guard let model = limit.scope?.model?.display_name else { continue }
            let weekly = limit.group == "weekly"
            let label = weekly ? "Week" : limit.group ?? "Limit"
            // Only weekly limits have a known length; others get no pace tick.
            windows.append(LimitWindow(label: "\(label) · \(model)", usedPercent: limit.percent,
                                       resetsAt: limit.resets_at.flatMap(parseISO8601), duration: weekly ? 604_800 : nil))
        }
        return ProviderSnapshot(windows: windows, plan: nil, fetchedAt: now)
    }
}
