import SwiftUI
import AppKit
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
    @Published var codexSparkLimits: CodexRateLimitSnapshot?
    @Published var codexNeedsLogin = false
    @Published var codexErrorMessage: String?
    @Published var errorMessage: String?
    @Published var isLoading = false

    var onUpdate: (() -> Void)?

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
                self.codexSparkLimits = sparkSnapshot(from: codex)
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
            self.onUpdate?()
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
                process.environment = ProcessInfo.processInfo.environment

                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let initMsg = Data("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"ClaudeUsageBar\",\"version\":\"1.0\"},\"capabilities\":{}}}\n".utf8)
                let rateMsg = Data("{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":null}\n".utf8)
                inputPipe.fileHandleForWriting.write(initMsg)
                inputPipe.fileHandleForWriting.write(rateMsg)

                let killWork = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: killWork)

                let handle = outputPipe.fileHandleForReading
                let decoder = JSONDecoder()
                var lineData = Data()
                var resumed = false

                while !resumed {
                    let byte = handle.readData(ofLength: 1)
                    if byte.isEmpty { break }
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
        if let codex = response.rateLimitsByLimitId?["codex"] { return codex }
        if let any = response.rateLimitsByLimitId?.values.first(where: { $0.limitName == nil }) { return any }
        return response.rateLimits
    }

    private func sparkSnapshot(from response: CodexRateLimitsResponse) -> CodexRateLimitSnapshot? {
        return response.rateLimitsByLimitId?.values.first(where: { $0.limitName != nil })
    }

    private func resolveCodexExecutable() -> String? {
        ["/usr/local/bin/codex", "/opt/homebrew/bin/codex", "/usr/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func isCodexLoginError(_ message: String) -> Bool {
        let l = message.lowercased()
        return l.contains("not signed in") || l.contains("run 'codex login'") || l.contains("run `codex login`")
    }
}

// MARK: - Helpers

func parseISO(_ iso: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)
}

func formatResetTime(_ iso: String?) -> String {
    guard let iso = iso, let date = parseISO(iso) else { return "unknown" }
    return formatResetTime(date)
}

func formatResetTime(epochSeconds: Int?) -> String {
    guard let s = epochSeconds else { return "unknown" }
    return formatResetTime(Date(timeIntervalSince1970: TimeInterval(s)))
}

func formatResetTime(_ date: Date) -> String {
    let rel = RelativeDateTimeFormatter()
    rel.unitsStyle = .abbreviated
    let relative = rel.localizedString(for: date, relativeTo: Date())
    let abs = DateFormatter()
    abs.dateFormat = "MMM d, HH:mm"
    return "\(relative) (\(abs.string(from: date)))"
}

func pct(_ value: Double) -> String { "\(Int(value))%" }
func pct(_ value: Int?) -> String { value.map { "\($0)%" } ?? "?" }

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let vm = UsageViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSStatusItem is always visible — macOS never hides it for third-party apps
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "C:?"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        vm.onUpdate = { [weak self] in
            self?.statusItem.button?.title = self?.vm.menuBarTitle ?? "C:?"
        }
    }

    // Rebuild menu lazily each time it opens
    func menuWillOpen(_ menu: NSMenu) {
        statusItem.button?.title = vm.menuBarTitle
        menu.removeAllItems()

        if let err = vm.errorMessage {
            menu.addItem(err, red: true)
        }

        if let fh = vm.fiveHour {
            menu.addItem("Claude 5-Hour Session: \(pct(fh.utilization))")
            menu.addItem("  resets \(formatResetTime(fh.resets_at))", small: true)
        }
        if let sd = vm.sevenDay {
            menu.addItem("Claude 7-Day Week: \(pct(sd.utilization))")
            menu.addItem("  resets \(formatResetTime(sd.resets_at))", small: true)
        }
        if let ss = vm.sevenDaySonnet {
            menu.addItem("Claude 7-Day Sonnet: \(pct(ss.utilization))")
            menu.addItem("  resets \(formatResetTime(ss.resets_at))", small: true)
        }

        if let codex = vm.codexLimits {
            menu.addItem(.separator())
            menu.addItem("Codex 5-Hour Session: \(pct(codex.primary?.usedPercent))")
            menu.addItem("  resets \(formatResetTime(epochSeconds: codex.primary?.resetsAt))", small: true)
            menu.addItem("Codex 7-Day Week: \(pct(codex.secondary?.usedPercent))")
            menu.addItem("  resets \(formatResetTime(epochSeconds: codex.secondary?.resetsAt))", small: true)
            if let plan = codex.planType {
                menu.addItem("  Plan: \(plan)", small: true)
            }
        }

        if let spark = vm.codexSparkLimits {
            menu.addItem(.separator())
            let name = spark.limitName ?? "Codex Spark"
            menu.addItem("\(name) 5-Hour: \(pct(spark.primary?.usedPercent))")
            menu.addItem("  resets \(formatResetTime(epochSeconds: spark.primary?.resetsAt))", small: true)
            menu.addItem("\(name) 7-Day: \(pct(spark.secondary?.usedPercent))")
            menu.addItem("  resets \(formatResetTime(epochSeconds: spark.secondary?.resetsAt))", small: true)
        }

        if vm.codexLimits == nil {
            menu.addItem(.separator())
            if vm.codexNeedsLogin {
                menu.addItem("Codex: not logged in")
                menu.addItem("  run `codex login` in Terminal", small: true)
            } else if let err = vm.codexErrorMessage {
                menu.addItem(err, small: true)
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: vm.isLoading ? "Refreshing..." : "Refresh",
            action: vm.isLoading ? nil : #selector(refresh),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func refresh() { vm.fetch() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

private extension NSMenu {
    func addItem(_ title: String, small: Bool = false, red: Bool = false) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        var attrs: [NSAttributedString.Key: Any] = [:]
        if small { attrs[.font] = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize) }
        if red   { attrs[.foregroundColor] = NSColor.systemRed }
        item.attributedTitle = NSAttributedString(string: title, attributes: attrs.isEmpty ? [:] : attrs)
        addItem(item)
    }
}

// MARK: - Entry Point

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
