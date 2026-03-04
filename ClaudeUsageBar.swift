import SwiftUI
import Foundation

// MARK: - Data Models

struct UsageBucket: Codable {
    let utilization: Double
    let resets_at: String?
}

struct UsageResponse: Codable {
    let five_hour: UsageBucket
    let seven_day: UsageBucket
    let seven_day_sonnet: UsageBucket?
}

struct CodexRateLimitWindow: Codable {
    let usedPercent: Int
    let resetsAt: Int?
    let windowDurationMins: Int?
}

struct CodexCreditsSnapshot: Codable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool
}

struct CodexRateLimitSnapshot: Codable {
    let limitId: String?
    let limitName: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let credits: CodexCreditsSnapshot?
    let planType: String?
}

struct CodexRateLimitsResponse: Codable {
    let rateLimits: CodexRateLimitSnapshot
    let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
}

struct CodexRPCError: Codable {
    let code: Int
    let message: String
}

struct CodexRPCEnvelope<T: Decodable>: Decodable {
    let id: Int?
    let result: T?
    let error: CodexRPCError?
}

// MARK: - ViewModel

@MainActor
class UsageViewModel: ObservableObject {
    @Published var fiveHour: UsageBucket?
    @Published var sevenDay: UsageBucket?
    @Published var sevenDaySonnet: UsageBucket?
    @Published var codexLimits: CodexRateLimitSnapshot?
    @Published var codexNeedsLogin = false
    @Published var codexErrorMessage: String?
    @Published var errorMessage: String?
    @Published var isLoading = false

    private var timer: Timer?

    init() {
        startPolling()
    }

    var menuBarTitle: String {
        let claudePart = sevenDay.map { "C:\(Int($0.utilization))%" } ?? "C:?"
        let codexPart: String
        if let weekly = codexLimits?.secondary?.usedPercent {
            codexPart = "O:\(weekly)%"
        } else if codexNeedsLogin {
            codexPart = "O:login"
        } else {
            codexPart = "O:?"
        }
        return "\(claudePart) \(codexPart)"
    }

    func startPolling() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetch()
            }
        }
    }

    func fetch() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        codexErrorMessage = nil

        Task {
            do {
                let token = try getOAuthToken()
                let usage = try await fetchUsage(token: token)
                self.fiveHour = usage.five_hour
                self.sevenDay = usage.seven_day
                self.sevenDaySonnet = usage.seven_day_sonnet
            } catch {
                self.errorMessage = "Claude: \(error.localizedDescription)"
            }

            do {
                let codex = try await fetchCodexRateLimits()
                self.codexLimits = preferredCodexSnapshot(from: codex)
                self.codexNeedsLogin = false
            } catch {
                self.codexLimits = nil
                let message = error.localizedDescription
                if isCodexLoginError(message) {
                    self.codexNeedsLogin = true
                } else {
                    self.codexNeedsLogin = false
                    self.codexErrorMessage = "Codex: \(message)"
                }
            }
            self.isLoading = false
        }
    }

    private func getOAuthToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw URLError(.userAuthenticationRequired)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }

        // Parse JSON to extract OAuth token
        guard let jsonData = raw.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauthObj = json["claudeAiOauth"] as? [String: Any],
              let token = oauthObj["accessToken"] as? String else {
            throw URLError(.userAuthenticationRequired)
        }

        return token
    }

    private func fetchUsage(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(code)"
            ])
        }

        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    private func fetchCodexRateLimits() async throws -> CodexRateLimitsResponse {
        guard let codexPath = resolveCodexExecutable() else {
            throw URLError(.fileDoesNotExist, userInfo: [
                NSLocalizedDescriptionKey: "codex CLI not found"
            ])
        }

        // Run blocking I/O on a background thread so it never stalls the main actor.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: codexPath)
                process.arguments = ["app-server"]

                let inputPipe = Pipe()
                let outputPipe = Pipe()
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = Pipe()

                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let initMsg = Data("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"ClaudeUsageBar\",\"version\":\"1.0\"},\"capabilities\":{}}}\n".utf8)
                let rateMsg = Data("{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":null}\n".utf8)
                inputPipe.fileHandleForWriting.write(initMsg)
                inputPipe.fileHandleForWriting.write(rateMsg)

                // Kill process if no response within 15 seconds.
                let killWork = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: killWork)

                // Read byte-by-byte to build lines (blocking, safe on background thread).
                let handle = outputPipe.fileHandleForReading
                let decoder = JSONDecoder()
                var lineData = Data()
                var resumed = false

                while !resumed {
                    let byte = handle.readData(ofLength: 1)
                    if byte.isEmpty { break } // EOF — process terminated
                    if byte == Data([UInt8(ascii: "\n")]) {
                        defer { lineData = Data() }
                        guard !lineData.isEmpty,
                              let env = try? decoder.decode(CodexRPCEnvelope<CodexRateLimitsResponse>.self, from: lineData),
                              env.id == 2 else { continue }

                        killWork.cancel()
                        process.terminate()
                        resumed = true

                        if let result = env.result {
                            continuation.resume(returning: result)
                        } else if let rpcError = env.error {
                            continuation.resume(throwing: URLError(.cannotParseResponse, userInfo: [
                                NSLocalizedDescriptionKey: "Codex RPC \(rpcError.code): \(rpcError.message)"
                            ]))
                        } else {
                            continuation.resume(throwing: URLError(.badServerResponse))
                        }
                    } else {
                        lineData.append(byte)
                    }
                }

                if !resumed {
                    continuation.resume(throwing: URLError(.timedOut, userInfo: [
                        NSLocalizedDescriptionKey: "No response from codex app-server"
                    ]))
                }
            }
        }
    }

    private func preferredCodexSnapshot(from response: CodexRateLimitsResponse) -> CodexRateLimitSnapshot {
        if let codex = response.rateLimitsByLimitId?["codex"] {
            return codex
        }
        if let any = response.rateLimitsByLimitId?.values.first {
            return any
        }
        return response.rateLimits
    }

    private func resolveCodexExecutable() -> String? {
        let candidates = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/bin/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func isCodexLoginError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("not signed in")
            || lowered.contains("run 'codex login'")
            || lowered.contains("run `codex login`")
    }
}

// MARK: - Helpers

func parseISO(_ iso: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: iso) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)
}

func formatResetTime(_ iso: String?) -> String {
    guard let iso = iso, let date = parseISO(iso) else { return "unknown" }
    return formatResetTime(date)
}

func formatResetTime(epochSeconds: Int?) -> String {
    guard let epochSeconds else { return "unknown" }
    let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    return formatResetTime(date)
}

func formatResetTime(_ date: Date) -> String {
    let rel = RelativeDateTimeFormatter()
    rel.unitsStyle = .abbreviated
    let relative = rel.localizedString(for: date, relativeTo: Date())

    let abs = DateFormatter()
    abs.dateFormat = "MMM d, HH:mm"
    let absolute = abs.string(from: date)

    return "\(relative) (\(absolute))"
}

func pct(_ value: Double) -> String {
    "\(Int(value))%"
}

func pct(_ value: Int?) -> String {
    guard let value else { return "?" }
    return "\(value)%"
}

// MARK: - App

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var vm = UsageViewModel()

    var body: some Scene {
        MenuBarExtra {
            if let err = vm.errorMessage {
                Text("Error: \(err)")
                    .foregroundColor(.red)
            }

            if let fh = vm.fiveHour {
                Text("Claude 5-Hour Session: \(pct(fh.utilization))")
                Text("  resets \(formatResetTime(fh.resets_at))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let sd = vm.sevenDay {
                Text("Claude 7-Day Week: \(pct(sd.utilization))")
                Text("  resets \(formatResetTime(sd.resets_at))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let ss = vm.sevenDaySonnet {
                Text("Claude 7-Day Sonnet: \(pct(ss.utilization))")
                Text("  resets \(formatResetTime(ss.resets_at))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let codex = vm.codexLimits {
                Divider()

                Text("Codex 5-Hour Session: \(pct(codex.primary?.usedPercent))")
                Text("  resets \(formatResetTime(epochSeconds: codex.primary?.resetsAt))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Codex 7-Day Week: \(pct(codex.secondary?.usedPercent))")
                Text("  resets \(formatResetTime(epochSeconds: codex.secondary?.resetsAt))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let plan = codex.planType {
                    Text("Codex Plan: \(plan)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if vm.codexNeedsLogin {
                Divider()
                Text("Codex: not logged in")
                Text("  run `codex login` in Terminal")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let codexErr = vm.codexErrorMessage {
                Divider()
                Text(codexErr)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Button(vm.isLoading ? "Refreshing..." : "Refresh") {
                vm.fetch()
            }
            .disabled(vm.isLoading)
            .keyboardShortcut("r")

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Text(vm.menuBarTitle)
        }
    }
}
