import CodexLocalMeterCore
import Testing

@Test func defaultStatusIsEmptyState() {
    let summary = UsageSummary(
        isEstimated: true,
        codexPath: "/tmp/codex",
        sessionCount: 0,
        modelNames: [],
        parseErrors: []
    )

    #expect(StatusFormatter.statusText(summary: summary, settings: .defaults) == "--")
}
