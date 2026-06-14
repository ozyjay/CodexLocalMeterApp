import Foundation

public struct RawEvent: Sendable {
    public var sessionId: String
    public var timestamp: Date
    public var model: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var messageCount: Int?
    public var primaryUsedPercent: Double?
    public var secondaryUsedPercent: Double?
    public var primaryResetsAt: Date?
    public var secondaryResetsAt: Date?

    public init(
        sessionId: String,
        timestamp: Date,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        messageCount: Int? = nil,
        primaryUsedPercent: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        primaryResetsAt: Date? = nil,
        secondaryResetsAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.messageCount = messageCount
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.primaryResetsAt = primaryResetsAt
        self.secondaryResetsAt = secondaryResetsAt
    }
}

public struct ReadResult: Sendable {
    public var events: [RawEvent]
    public var parseErrors: [String]

    public init(events: [RawEvent], parseErrors: [String]) {
        self.events = events
        self.parseErrors = parseErrors
    }
}

public struct UsageSummary: Sendable {
    public var fiveHourTokens: Int?
    public var fiveHourMessages: Int?
    public var sevenDayTokens: Int?
    public var sevenDayMessages: Int?
    public var isEstimated: Bool
    public var lastActivity: Date?
    public var codexPath: String
    public var sessionCount: Int
    public var modelNames: [String]
    public var parseErrors: [String]
    public var primaryUsedPercent: Double?
    public var secondaryUsedPercent: Double?
    public var primaryResetsAt: Date?
    public var secondaryResetsAt: Date?

    public init(
        fiveHourTokens: Int? = nil,
        fiveHourMessages: Int? = nil,
        sevenDayTokens: Int? = nil,
        sevenDayMessages: Int? = nil,
        isEstimated: Bool,
        lastActivity: Date? = nil,
        codexPath: String,
        sessionCount: Int,
        modelNames: [String],
        parseErrors: [String],
        primaryUsedPercent: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        primaryResetsAt: Date? = nil,
        secondaryResetsAt: Date? = nil
    ) {
        self.fiveHourTokens = fiveHourTokens
        self.fiveHourMessages = fiveHourMessages
        self.sevenDayTokens = sevenDayTokens
        self.sevenDayMessages = sevenDayMessages
        self.isEstimated = isEstimated
        self.lastActivity = lastActivity
        self.codexPath = codexPath
        self.sessionCount = sessionCount
        self.modelNames = modelNames
        self.parseErrors = parseErrors
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.primaryResetsAt = primaryResetsAt
        self.secondaryResetsAt = secondaryResetsAt
    }
}

public struct MeterSettings: Sendable, Equatable {
    public var codexPath: String
    public var refreshIntervalSeconds: Double
    public var showFiveHourUsage: Bool
    public var showWeeklyUsage: Bool
    public var warningThresholdPercent: Double
    public var dangerThresholdPercent: Double
    public var compactMode: Bool

    public init(
        codexPath: String,
        refreshIntervalSeconds: Double,
        showFiveHourUsage: Bool,
        showWeeklyUsage: Bool,
        warningThresholdPercent: Double,
        dangerThresholdPercent: Double,
        compactMode: Bool
    ) {
        self.codexPath = codexPath
        self.refreshIntervalSeconds = max(30, refreshIntervalSeconds)
        self.showFiveHourUsage = showFiveHourUsage
        self.showWeeklyUsage = showWeeklyUsage
        self.warningThresholdPercent = min(max(warningThresholdPercent, 0), 100)
        self.dangerThresholdPercent = max(min(max(dangerThresholdPercent, 0), 100), self.warningThresholdPercent)
        self.compactMode = compactMode
    }

    public static var defaults: MeterSettings {
        MeterSettings(
            codexPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex").path,
            refreshIntervalSeconds: 300,
            showFiveHourUsage: true,
            showWeeklyUsage: true,
            warningThresholdPercent: 70,
            dangerThresholdPercent: 90,
            compactMode: false
        )
    }
}
