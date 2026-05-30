import Foundation

public enum StatusLevel: Sendable, Equatable {
    case normal
    case warning
    case danger
}

public enum StatusFormatter {
    public static func statusText(summary: UsageSummary, settings: MeterSettings) -> String {
        if summary.sessionCount == 0 && summary.parseErrors.isEmpty {
            return "--"
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
        guard let percent = summary.primaryUsedPercent else {
            return .normal
        }
        if percent >= settings.dangerThresholdPercent {
            return .danger
        }
        if percent >= settings.warningThresholdPercent {
            return .warning
        }
        return .normal
    }
}
