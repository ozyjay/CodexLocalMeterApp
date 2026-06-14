import Foundation

public enum StatusLevel: Sendable, Equatable {
    case normal
    case warning
    case danger
}

public enum RateLimitWindow: Sendable, Equatable {
    case primary
    case secondary

    public var menuSuffix: String {
        switch self {
        case .primary:
            return "5h"
        case .secondary:
            return "7d"
        }
    }
}

public enum StatusFormatter {
    public static func statusText(summary: UsageSummary, settings: MeterSettings) -> String {
        if summary.sessionCount == 0 && summary.parseErrors.isEmpty {
            return "--"
        }

        if let activeWindow = activeRateLimitWindow(summary: summary, settings: settings),
           let percent = percent(for: activeWindow, summary: summary) {
            if settings.compactMode, activeWindow == .primary {
                return "\(UsageFormatting.percent(percent))%"
            }
            return "\(UsageFormatting.percent(percent))% \(activeWindow.menuSuffix)"
        }

        if settings.compactMode {
            return compactText(summary: summary)
        }

        guard settings.showFiveHourUsage else {
            return ""
        }

        if let percent = summary.primaryUsedPercent {
            return "\(UsageFormatting.percent(percent))% 5h"
        }
        if summary.isEstimated {
            return "~\(summary.fiveHourMessages ?? 0) msgs 5h"
        }
        return "\(UsageFormatting.tokens(summary.fiveHourTokens ?? 0) ?? "0") 5h"
    }

    public static func compactText(summary: UsageSummary) -> String {
        if let percent = summary.primaryUsedPercent {
            return "\(UsageFormatting.percent(percent))%"
        }
        if summary.isEstimated {
            return "~\(summary.fiveHourMessages ?? 0)"
        }
        return UsageFormatting.tokens(summary.fiveHourTokens ?? 0) ?? "0"
    }

    public static func activeRateLimitWindow(summary: UsageSummary, settings: MeterSettings) -> RateLimitWindow? {
        let primary = candidate(for: .primary, summary: summary, settings: settings)
        let secondary = candidate(for: .secondary, summary: summary, settings: settings)

        switch (primary, secondary) {
        case let (primary?, secondary?):
            if severityRank(secondary.level) > severityRank(primary.level) {
                return .secondary
            }
            return .primary
        case (.some, .none):
            return .primary
        case (.none, .some):
            return .secondary
        case (.none, .none):
            return nil
        }
    }

    public static func fiveHourDetail(summary: UsageSummary) -> String {
        if let percent = summary.primaryUsedPercent {
            return "\(UsageFormatting.percent(percent))% of 5-hour rate limit"
        }
        if summary.isEstimated {
            return "~\(summary.fiveHourMessages ?? 0) messages"
        }
        return "\(UsageFormatting.tokens(summary.fiveHourTokens) ?? "0") tokens"
    }

    public static func sevenDayDetail(summary: UsageSummary) -> String {
        if let percent = summary.secondaryUsedPercent {
            return "\(UsageFormatting.percent(percent))% of 7-day rate limit"
        }
        if summary.isEstimated {
            return "~\(summary.sevenDayMessages ?? 0) messages"
        }
        return "\(UsageFormatting.tokens(summary.sevenDayTokens) ?? "0") tokens"
    }

    public static func statusLevel(summary: UsageSummary, settings: MeterSettings) -> StatusLevel {
        guard let activeWindow = activeRateLimitWindow(summary: summary, settings: settings),
              let percent = percent(for: activeWindow, summary: summary) else {
            return .normal
        }
        return level(for: percent, settings: settings)
    }

    private static func candidate(for window: RateLimitWindow, summary: UsageSummary, settings: MeterSettings) -> (window: RateLimitWindow, level: StatusLevel)? {
        guard isEnabled(window, settings: settings),
              let percent = percent(for: window, summary: summary) else {
            return nil
        }
        return (window, level(for: percent, settings: settings))
    }

    private static func isEnabled(_ window: RateLimitWindow, settings: MeterSettings) -> Bool {
        switch window {
        case .primary:
            return settings.showFiveHourUsage
        case .secondary:
            return settings.showWeeklyUsage
        }
    }

    private static func percent(for window: RateLimitWindow, summary: UsageSummary) -> Double? {
        switch window {
        case .primary:
            return summary.primaryUsedPercent
        case .secondary:
            return summary.secondaryUsedPercent
        }
    }

    private static func level(for percent: Double, settings: MeterSettings) -> StatusLevel {
        if percent >= settings.dangerThresholdPercent {
            return .danger
        }
        if percent >= settings.warningThresholdPercent {
            return .warning
        }
        return .normal
    }

    private static func severityRank(_ level: StatusLevel) -> Int {
        switch level {
        case .normal:
            return 0
        case .warning:
            return 1
        case .danger:
            return 2
        }
    }
}
