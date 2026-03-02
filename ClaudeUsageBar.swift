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

// MARK: - ViewModel

@MainActor
class UsageViewModel: ObservableObject {
    @Published var fiveHour: UsageBucket?
    @Published var sevenDay: UsageBucket?
    @Published var sevenDaySonnet: UsageBucket?
    @Published var errorMessage: String?
    @Published var isLoading = false

    private var timer: Timer?

    init() {
        startPolling()
    }

    var menuBarTitle: String {
        if let sevenDay = sevenDay {
            return "C: \(Int(sevenDay.utilization))%"
        }
        return "C: ?"
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

        Task {
            do {
                let token = try getOAuthToken()
                let usage = try await fetchUsage(token: token)
                self.fiveHour = usage.five_hour
                self.sevenDay = usage.seven_day
                self.sevenDaySonnet = usage.seven_day_sonnet
            } catch {
                self.errorMessage = error.localizedDescription
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
                Text("5-Hour Session: \(pct(fh.utilization))")
                Text("  resets \(formatResetTime(fh.resets_at))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let sd = vm.sevenDay {
                Text("7-Day Week: \(pct(sd.utilization))")
                Text("  resets \(formatResetTime(sd.resets_at))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let ss = vm.sevenDaySonnet {
                Text("7-Day Sonnet: \(pct(ss.utilization))")
                Text("  resets \(formatResetTime(ss.resets_at))")
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
