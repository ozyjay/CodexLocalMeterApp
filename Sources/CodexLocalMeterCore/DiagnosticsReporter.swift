import Foundation

public struct PathStatus: Sendable {
    public var exists: Bool
    public var sessionsExists: Bool
    public var configExists: Bool
    public var authExists: Bool

    public init(exists: Bool, sessionsExists: Bool, configExists: Bool, authExists: Bool) {
        self.exists = exists
        self.sessionsExists = sessionsExists
        self.configExists = configExists
        self.authExists = authExists
    }
}

public enum DiagnosticsReporter {
    public static func checkPath(_ codexPath: String, fileManager: FileManager = .default) -> PathStatus {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: codexPath, isDirectory: &isDirectory) && isDirectory.boolValue
        guard exists else {
            return PathStatus(exists: false, sessionsExists: false, configExists: false, authExists: false)
        }

        return PathStatus(
            exists: true,
            sessionsExists: fileManager.fileExists(atPath: URL(fileURLWithPath: codexPath).appendingPathComponent("sessions").path),
            configExists: fileManager.fileExists(atPath: URL(fileURLWithPath: codexPath).appendingPathComponent("config.toml").path),
            authExists: fileManager.fileExists(atPath: URL(fileURLWithPath: codexPath).appendingPathComponent("auth.json").path)
        )
    }

    public static func report(summary: UsageSummary, pathStatus: PathStatus? = nil, now: Date = Date()) -> String {
        let status = pathStatus ?? checkPath(summary.codexPath)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        var lines: [String] = []
        let hr = String(repeating: "-", count: 52)

        lines.append(hr)
        lines.append("  Codex Local Meter - Diagnostics")
        lines.append("  \(formatter.string(from: now))")
        lines.append(hr)
        lines.append("")
        lines.append("PATH")
        lines.append("  Codex folder : \(summary.codexPath)")
        lines.append("  Folder exists: \(status.exists ? "yes" : "NO - folder not found")")
        if status.exists {
            lines.append("  sessions/    : \(status.sessionsExists ? "found" : "not found")")
            lines.append("  config.toml  : \(status.configExists ? "found" : "not found")")
            lines.append("  auth.json    : \(status.authExists ? "found (not read)" : "not found")")
        }
        lines.append("")
        lines.append("USAGE (estimates)")
        lines.append("  Sessions (7 d)  : \(summary.sessionCount)")
        lines.append("  Token counts    : \(summary.isEstimated ? "NOT FOUND - using message counts" : "found")")
        if summary.isEstimated {
            lines.append("  5-hour messages : ~\(summary.fiveHourMessages ?? 0)")
            lines.append("  7-day messages  : ~\(summary.sevenDayMessages ?? 0)")
        } else {
            lines.append("  5-hour tokens   : \(summary.fiveHourTokens ?? 0)")
            lines.append("  7-day tokens    : \(summary.sevenDayTokens ?? 0)")
        }
        lines.append("  Last activity   : \(UsageFormatting.relativeTime(summary.lastActivity, now: now))")
        lines.append("  Models detected : \(summary.modelNames.isEmpty ? "(none)" : summary.modelNames.joined(separator: ", "))")
        lines.append("")
        lines.append("PARSE ISSUES (\(summary.parseErrors.count))")
        if summary.parseErrors.isEmpty {
            lines.append("  None.")
        } else {
            lines.append(contentsOf: summary.parseErrors.map { "  - \($0)" })
        }
        lines.append("")
        lines.append("PRIVACY")
        lines.append("  Network calls  : none")
        lines.append("  Telemetry      : none")
        lines.append("  File writes    : none (read-only)")
        lines.append("  Content shown  : paths, counts, timestamps only")
        lines.append("")
        lines.append(hr)
        return lines.joined(separator: "\n")
    }
}
