import Foundation

public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> MeterSettings {
        let override = defaults.string(forKey: "codexPathOverride")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let codexPath = override.isEmpty ? MeterSettings.defaults.codexPath : override
        let refresh = defaults.object(forKey: "refreshIntervalSeconds") as? Double ?? MeterSettings.defaults.refreshIntervalSeconds
        let warning = defaults.object(forKey: "warningThresholdPercent") as? Double ?? MeterSettings.defaults.warningThresholdPercent
        let danger = defaults.object(forKey: "dangerThresholdPercent") as? Double ?? MeterSettings.defaults.dangerThresholdPercent

        return MeterSettings(
            codexPath: codexPath,
            refreshIntervalSeconds: refresh,
            showFiveHourUsage: defaults.object(forKey: "showFiveHourUsage") as? Bool ?? true,
            showWeeklyUsage: defaults.object(forKey: "showWeeklyUsage") as? Bool ?? true,
            warningThresholdPercent: warning,
            dangerThresholdPercent: danger,
            compactMode: defaults.object(forKey: "compactMode") as? Bool ?? false
        )
    }

    public func saveCodexPath(_ path: String) {
        defaults.set(path, forKey: "codexPathOverride")
    }

    public func saveRefreshIntervalSeconds(_ seconds: Double) {
        defaults.set(max(30, seconds), forKey: "refreshIntervalSeconds")
    }

    public func saveCompactMode(_ compactMode: Bool) {
        defaults.set(compactMode, forKey: "compactMode")
    }
}
