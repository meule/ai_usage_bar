import SwiftUI
import AppKit
import Foundation
import Security

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

struct ClaudeAccount {
    let name: String        // keychain account field
    var email: String?      // from /api/oauth/account
    var fiveHour: UsageBucket?
    var sevenDay: UsageBucket?
    var sevenDaySonnet: UsageBucket?
    var error: String?
    var needsRelogin: Bool = false

    var displayName: String { email ?? name }
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

enum ClaudeAuthError: Error {
    case tokenExpired
    case rateLimited
}

// MARK: - ViewModel

@MainActor
class UsageViewModel: ObservableObject {
    @Published var claudeAccounts: [ClaudeAccount] = []
    @Published var codexLimits: CodexRateLimitSnapshot?
    @Published var codexSparkLimits: CodexRateLimitSnapshot?
    @Published var codexNeedsLogin = false
    @Published var codexErrorMessage: String?
    @Published var isLoading = false

    var onUpdate: (() -> Void)?

    private var timer: Timer?

    init() {
        startPolling()
    }

    var menuBarAttributedTitle: NSAttributedString {
        let normal = NSFont.menuBarFont(ofSize: 0)
        let bold   = NSFont.boldSystemFont(ofSize: normal.pointSize)

        func segment(_ value: Double?) -> NSAttributedString {
            let n = value.map { Int($0) }
            let text = n.map { "\($0)" } ?? "?"
            let isHot = (n ?? 0) > 90
            return NSAttributedString(string: text, attributes: [.font: isHot ? bold : normal])
        }

        let result = NSMutableAttributedString()
        let sep    = NSAttributedString(string: "|", attributes: [.font: normal])
        let space  = NSAttributedString(string: " ", attributes: [.font: normal])

        for (i, a) in claudeAccounts.enumerated() {
            if i > 0 { result.append(space) }
            let limited = a.error == "Rate limited (100%)"
            result.append(segment(a.fiveHour?.utilization ?? (limited ? 100 : nil)))
            result.append(sep)
            result.append(segment(a.sevenDay?.utilization ?? (limited ? 100 : nil)))
        }
        if claudeAccounts.isEmpty {
            result.append(NSAttributedString(string: "?|?", attributes: [.font: normal]))
        }
        return result
    }

    func startPolling() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetch() }
        }
    }

    func fetch() {
        guard !isLoading else { return }
        isLoading = true
        codexErrorMessage = nil

        Task {
            let tokens = discoverTokens()
            var accounts: [ClaudeAccount] = []

            for token in tokens {
                var account = ClaudeAccount(name: "")
                do {
                    async let email = fetchAccountEmail(token: token)
                    async let usage = fetchUsage(token: token)
                    account.email = await email
                    let u = try await usage
                    account.fiveHour = u.five_hour
                    account.sevenDay = u.seven_day
                    account.sevenDaySonnet = u.seven_day_sonnet
                    account.needsRelogin = false
                } catch ClaudeAuthError.tokenExpired {
                    account.needsRelogin = true
                    account.error = "Token expired"
                } catch ClaudeAuthError.rateLimited {
                    // Keep stale data, just note it
                    account.error = "Rate limited (100%)"
                } catch {
                    account.error = error.localizedDescription
                }
                accounts.append(account)
            }
            self.claudeAccounts = accounts

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

    // Returns tokens: reads config file, but always syncs the current Keychain token
    // into whichever config entry matches (keeping it fresh after Claude Code refreshes it).
    private func discoverTokens() -> [String] {
        let configPath = NSHomeDirectory() + "/.claude_usage_accounts.json"

        // Always read the current live token from Keychain
        let keychainEntry = keychainOAuth()

        // Load config file
        var entries: [[String: Any]] = []
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accounts = json["accounts"] as? [[String: Any]] {
            entries = accounts
        }

        // If Keychain has a token, update the matching config entry (by refreshToken)
        // so it stays fresh, or add it if not present
        if let live = keychainEntry {
            let liveRefresh = live["refreshToken"] as? String ?? ""
            if let idx = entries.firstIndex(where: { ($0["refreshToken"] as? String) == liveRefresh && !liveRefresh.isEmpty }) {
                entries[idx]["accessToken"] = live["accessToken"]
            } else {
                // New account not yet in config — add it
                entries.append(live)
                let updated: [String: Any] = ["accounts": entries]
                if let data = try? JSONSerialization.data(withJSONObject: updated, options: .prettyPrinted) {
                    try? data.write(to: URL(fileURLWithPath: configPath))
                }
            }
        }

        return entries.compactMap { $0["accessToken"] as? String }.filter { !$0.isEmpty }
    }

    private func keychainOAuth() -> [String: Any]? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth
    }

    private func fetchAccountEmail(token: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/account")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email_address"] as? String
    }

    private func fetchUsage(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        if code == 401 { throw ClaudeAuthError.tokenExpired }
        if code == 429 { throw ClaudeAuthError.rateLimited }
        guard code == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }

        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    private func fetchCodexRateLimits() async throws -> CodexRateLimitsResponse {
        guard let codexPath = resolveCodexExecutable() else {
            throw URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: "codex CLI not found"])
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
                    continuation.resume(throwing: error); return
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
        response.rateLimitsByLimitId?.values.first(where: { $0.limitName != nil })
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.attributedTitle = NSAttributedString(string: "?|?")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        vm.onUpdate = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.attributedTitle = self.vm.menuBarAttributedTitle
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusItem.button?.attributedTitle = vm.menuBarAttributedTitle
        menu.removeAllItems()

        // Claude accounts
        let accounts = vm.claudeAccounts
        for (i, account) in accounts.enumerated() {
            // Always show email as a header line
            menu.addItem("Claude — \(account.displayName)", bold: true)

            if account.needsRelogin {
                let item = NSMenuItem(title: "  ⚠️ Token expired — Re-login", action: #selector(relogin), keyEquivalent: "")
                item.target = self
                item.representedObject = account.displayName
                menu.addItem(item)
            } else if let err = account.error {
                menu.addItem("  \(err)", small: true, red: true)
            } else {
                if let fh = account.fiveHour {
                    menu.addItem("  5-Hour: \(pct(fh.utilization))", small: true)
                    menu.addItem("    resets \(formatResetTime(fh.resets_at))", small: true)
                }
                if let sd = account.sevenDay {
                    menu.addItem("  7-Day: \(pct(sd.utilization))", small: true)
                    menu.addItem("    resets \(formatResetTime(sd.resets_at))", small: true)
                }
                if let ss = account.sevenDaySonnet {
                    menu.addItem("  7-Day Sonnet: \(pct(ss.utilization))", small: true)
                    menu.addItem("    resets \(formatResetTime(ss.resets_at))", small: true)
                }
            }
            if i < accounts.count - 1 {
                menu.addItem(.separator())
            }
        }

        if vm.claudeAccounts.isEmpty {
            menu.addItem("Claude: not logged in")
        }

        // Codex
        if let codex = vm.codexLimits {
            menu.addItem(.separator())
            menu.addItem("Codex 5-Hour: \(pct(codex.primary?.usedPercent))")
            menu.addItem("  resets \(formatResetTime(epochSeconds: codex.primary?.resetsAt))", small: true)
            menu.addItem("Codex 7-Day: \(pct(codex.secondary?.usedPercent))")
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

    @objc private func relogin(_ sender: NSMenuItem) {
        let script = """
        tell application "Terminal"
            activate
            do script "claude /login"
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

private extension NSMenu {
    func addItem(_ title: String, small: Bool = false, bold: Bool = false, red: Bool = false) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        var attrs: [NSAttributedString.Key: Any] = [:]
        let size = small ? NSFont.smallSystemFontSize : NSFont.systemFontSize
        attrs[.font] = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        if red { attrs[.foregroundColor] = NSColor.systemRed }
        item.attributedTitle = NSAttributedString(string: title, attributes: attrs)
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
