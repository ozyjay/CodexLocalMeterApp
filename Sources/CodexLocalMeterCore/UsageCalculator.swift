import Foundation

public struct UsageCalculator: Sendable {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func calculate(events: [RawEvent], codexPath: String, parseErrors: [String]) -> UsageSummary {
        guard !events.isEmpty else {
            return UsageSummary(
                isEstimated: true,
                codexPath: codexPath,
                sessionCount: 0,
                modelNames: [],
                parseErrors: parseErrors
            )
        }

        let current = now()
        let fiveHourCutoff = current.addingTimeInterval(-5 * 60 * 60)
        let sevenDayCutoff = current.addingTimeInterval(-7 * 24 * 60 * 60)

        var fiveHourInputTokens = 0
        var fiveHourOutputTokens = 0
        var fiveHourMessages = 0
        var sevenDayInputTokens = 0
        var sevenDayOutputTokens = 0
        var sevenDayMessages = 0
        var hasTokens = false
        var lastActivity: Date?
        var sessionIds = Set<String>()
        var modelNames = Set<String>()
        var latestRateLimitTimestamp: Date?
        var latestPrimaryUsedPercent: Double?
        var latestSecondaryUsedPercent: Double?

        for event in events {
            if lastActivity == nil || event.timestamp > lastActivity! {
                lastActivity = event.timestamp
            }

            if let model = event.model {
                modelNames.insert(model)
            }

            if event.inputTokens != nil || event.outputTokens != nil {
                hasTokens = true
            }

            if event.timestamp >= fiveHourCutoff,
               event.primaryUsedPercent != nil || event.secondaryUsedPercent != nil {
                if latestRateLimitTimestamp == nil || event.timestamp > latestRateLimitTimestamp! {
                    latestRateLimitTimestamp = event.timestamp
                    if let primary = event.primaryUsedPercent {
                        latestPrimaryUsedPercent = primary
                    }
                    if let secondary = event.secondaryUsedPercent {
                        latestSecondaryUsedPercent = secondary
                    }
                }
            }

            if event.timestamp >= sevenDayCutoff {
                sessionIds.insert(event.sessionId)
                sevenDayInputTokens += event.inputTokens ?? 0
                sevenDayOutputTokens += event.outputTokens ?? 0
                sevenDayMessages += event.messageCount ?? 1
            }

            if event.timestamp >= fiveHourCutoff {
                fiveHourInputTokens += event.inputTokens ?? 0
                fiveHourOutputTokens += event.outputTokens ?? 0
                fiveHourMessages += event.messageCount ?? 1
            }
        }

        var summary = UsageSummary(
            isEstimated: !hasTokens,
            lastActivity: lastActivity,
            codexPath: codexPath,
            sessionCount: sessionIds.count,
            modelNames: modelNames.sorted(),
            parseErrors: parseErrors,
            primaryUsedPercent: latestPrimaryUsedPercent,
            secondaryUsedPercent: latestSecondaryUsedPercent
        )

        if hasTokens {
            summary.fiveHourTokens = fiveHourInputTokens + fiveHourOutputTokens
            summary.sevenDayTokens = sevenDayInputTokens + sevenDayOutputTokens
        } else {
            summary.fiveHourMessages = fiveHourMessages
            summary.sevenDayMessages = sevenDayMessages
        }

        return summary
    }
}

public enum UsageFormatting {
    public static func tokens(_ count: Int?) -> String? {
        guard let count else {
            return nil
        }
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            let rounded = (Double(count) / 100).rounded() / 10
            if rounded >= 1_000 {
                return String(format: "%.1fM", Double(count) / 1_000_000)
            }
            return String(format: "%.1fk", rounded)
        }
        return "\(count)"
    }

    public static func percent(_ percent: Double) -> String {
        "\(Int(percent.rounded()))"
    }

    public static func relativeTime(_ date: Date?, now: Date = Date()) -> String {
        guard let date else {
            return "never"
        }
        let diffMinutes = Int(now.timeIntervalSince(date) / 60)
        if diffMinutes < 1 {
            return "just now"
        }
        if diffMinutes < 60 {
            return "\(diffMinutes) min ago"
        }
        let diffHours = diffMinutes / 60
        if diffHours < 24 {
            return "\(diffHours) h ago"
        }
        return "\(diffHours / 24) d ago"
    }

    public static func windowRemaining(lastActivity: Date?, duration: TimeInterval, now: Date = Date()) -> String {
        guard let lastActivity else {
            return "No active window"
        }

        let remainingSeconds = lastActivity.addingTimeInterval(duration).timeIntervalSince(now)
        guard remainingSeconds > 0 else {
            return "No active window"
        }

        let remainingMinutes = max(1, Int((remainingSeconds / 60).rounded(.up)))
        let days = remainingMinutes / (24 * 60)
        let hours = (remainingMinutes % (24 * 60)) / 60
        let minutes = remainingMinutes % 60

        if days > 0 {
            return "Clears in \(days)d \(hours)h"
        }
        if hours > 0 {
            return "Clears in \(hours)h \(minutes)m"
        }
        return "Clears in \(minutes)m"
    }
}
