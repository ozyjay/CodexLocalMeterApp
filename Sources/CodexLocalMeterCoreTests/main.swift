import CodexLocalMeterCore
import Foundation

@main
@MainActor
enum CoreTestRunner {
    static func main() async {
        var failures: [String] = []

        await test("missing sessions directory returns no events and no errors", failures: &failures) {
            let root = try makeTemporaryDirectory()
            let result = await CodexReader().readEvents(codexPath: root.path)
            expect(result.events.isEmpty, "expected no events")
            expect(result.parseErrors.isEmpty, "expected no parse errors")
        }

        await test("reads Codex Desktop token_count and user_message events", failures: &failures) {
            let root = try makeTemporaryDirectory()
            let sessions = root.appendingPathComponent("sessions/2026")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let file = sessions.appendingPathComponent("abc.jsonl")
            let jsonl = """
            {"timestamp":"2026-05-30T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"output_tokens":30}},"rate_limits":{"primary":{"used_percent":42.4},"secondary":{"used_percent":18.2}}}}
            {"timestamp":"2026-05-30T01:01:00Z","type":"event_msg","payload":{"type":"user_message","message":"private prompt must not surface"}}
            {"timestamp":"2026-05-30T01:02:00Z","type":"response_item","payload":{"text":"private answer must not surface"}}
            """
            try jsonl.write(to: file, atomically: true, encoding: .utf8)

            let result = await CodexReader().readEvents(codexPath: root.path)

            expect(result.events.count == 2, "expected two usage-relevant events")
            expect(result.events[0].inputTokens == 120, "expected input tokens")
            expect(result.events[0].outputTokens == 30, "expected output tokens")
            expect(result.events[0].primaryUsedPercent == 42.4, "expected primary rate limit")
            expect(result.events[0].secondaryUsedPercent == 18.2, "expected secondary rate limit")
            expect(result.events[1].messageCount == 1, "expected user message fallback count")
            expect(result.parseErrors.isEmpty, "expected no parse errors")
        }

        await test("malformed JSONL line is a non-fatal parse error", failures: &failures) {
            let root = try makeTemporaryDirectory()
            let sessions = root.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let file = sessions.appendingPathComponent("bad.jsonl")
            try """
            {"timestamp":"2026-05-30T01:00:00Z","message_count":2}
            {this is not json}
            """.write(to: file, atomically: true, encoding: .utf8)

            let result = await CodexReader().readEvents(codexPath: root.path)

            expect(result.events.count == 1, "expected one valid event")
            expect(result.events[0].messageCount == 2, "expected flat message count")
            expect(result.parseErrors.count == 1, "expected one parse error")
            expect(result.parseErrors[0].contains("invalid JSON"), "expected invalid JSON error")
        }

        await test("usage calculator handles windows sessions models and latest rate limits", failures: &failures) {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let events = [
                RawEvent(sessionId: "a", timestamp: now.addingTimeInterval(-60), model: "gpt-5", inputTokens: 10, outputTokens: 5, primaryUsedPercent: 30),
                RawEvent(sessionId: "b", timestamp: now.addingTimeInterval(-4 * 60 * 60), model: "gpt-5-mini", inputTokens: 20, outputTokens: 10, secondaryUsedPercent: 44),
                RawEvent(sessionId: "old", timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60), inputTokens: 999, outputTokens: 999, primaryUsedPercent: 99)
            ]

            let summary = UsageCalculator(now: { now }).calculate(events: events, codexPath: "/tmp/codex", parseErrors: [])

            expect(!summary.isEstimated, "expected token summary")
            expect(summary.fiveHourTokens == 45, "expected five-hour tokens")
            expect(summary.sevenDayTokens == 45, "expected seven-day tokens")
            expect(summary.sessionCount == 2, "expected seven-day session count")
            expect(summary.modelNames == ["gpt-5", "gpt-5-mini"], "expected sorted model names")
            expect(summary.primaryUsedPercent == 30, "expected latest primary value from latest rate-limit event")
            expect(summary.secondaryUsedPercent == nil, "expected older secondary value after a newer primary not to replace latest rate-limit state")
        }

        await test("usage calculator falls back to message counts", failures: &failures) {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let events = [
                RawEvent(sessionId: "a", timestamp: now.addingTimeInterval(-60), messageCount: 1),
                RawEvent(sessionId: "a", timestamp: now.addingTimeInterval(-2 * 60 * 60), messageCount: 3),
                RawEvent(sessionId: "old", timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60), messageCount: 10)
            ]

            let summary = UsageCalculator(now: { now }).calculate(events: events, codexPath: "/tmp/codex", parseErrors: ["issue"])

            expect(summary.isEstimated, "expected estimated summary")
            expect(summary.fiveHourMessages == 4, "expected five-hour messages")
            expect(summary.sevenDayMessages == 4, "expected seven-day messages")
            expect(summary.sessionCount == 1, "expected one seven-day session")
            expect(summary.parseErrors == ["issue"], "expected parse errors to be preserved")
        }

        await test("usage calculator ignores stale five-hour rate limit values", failures: &failures) {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let events = [
                RawEvent(sessionId: "old", timestamp: now.addingTimeInterval((-5 * 60 * 60) - 1), inputTokens: 20, outputTokens: 10, primaryUsedPercent: 82),
                RawEvent(sessionId: "recent", timestamp: now.addingTimeInterval(-60), inputTokens: 1, outputTokens: 2)
            ]

            let summary = UsageCalculator(now: { now }).calculate(events: events, codexPath: "/tmp/codex", parseErrors: [])

            expect(summary.primaryUsedPercent == nil, "expected stale five-hour rate limit to be ignored")
            expect(summary.fiveHourTokens == 3, "expected fresh local tokens to remain available")
            expect(summary.sevenDayTokens == 33, "expected stale rate-limit event tokens to remain in seven-day total")
        }

        await test("status formatter shows rate limits tokens messages and empty state", failures: &failures) {
            let rateLimit = UsageSummary(
                isEstimated: false,
                codexPath: "/tmp/codex",
                sessionCount: 1,
                modelNames: [],
                parseErrors: [],
                primaryUsedPercent: 42.4
            )
            expect(StatusFormatter.statusText(summary: rateLimit, settings: .defaults) == "42% 5h", "expected rate-limit status text")

            var tokens = UsageSummary(isEstimated: false, codexPath: "/tmp/codex", sessionCount: 1, modelNames: [], parseErrors: [])
            tokens.fiveHourTokens = 12_400
            expect(StatusFormatter.statusText(summary: tokens, settings: .defaults) == "12.4k 5h", "expected token status text")

            var messages = UsageSummary(isEstimated: true, codexPath: "/tmp/codex", sessionCount: 1, modelNames: [], parseErrors: [])
            messages.fiveHourMessages = 12
            expect(StatusFormatter.statusText(summary: messages, settings: .defaults) == "~12 msgs 5h", "expected message status text")

            let empty = UsageSummary(isEstimated: true, codexPath: "/tmp/codex", sessionCount: 0, modelNames: [], parseErrors: [])
            expect(StatusFormatter.statusText(summary: empty, settings: .defaults) == "--", "expected empty status text")
        }

        await test("usage formatter describes remaining rolling-window time", failures: &failures) {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let recentActivity = now.addingTimeInterval(-(1 * 60 * 60) - (12 * 60))
            let staleActivity = now.addingTimeInterval((-5 * 60 * 60) - 1)

            expect(
                UsageFormatting.windowRemaining(lastActivity: recentActivity, duration: 5 * 60 * 60, now: now) == "Clears in 3h 48m",
                "expected hours and minutes remaining"
            )
            expect(
                UsageFormatting.windowRemaining(lastActivity: recentActivity, duration: 7 * 24 * 60 * 60, now: now) == "Clears in 6d 22h",
                "expected days and hours remaining"
            )
            expect(
                UsageFormatting.windowRemaining(lastActivity: staleActivity, duration: 5 * 60 * 60, now: now) == "No active window",
                "expected stale window to be inactive"
            )
            expect(
                UsageFormatting.windowRemaining(lastActivity: nil, duration: 5 * 60 * 60, now: now) == "No active window",
                "expected missing activity to be inactive"
            )
        }

        await test("status formatter chooses normal warning and danger levels from primary percent", failures: &failures) {
            let settings = MeterSettings(
                codexPath: "/tmp/codex",
                refreshIntervalSeconds: 300,
                showFiveHourUsage: true,
                showWeeklyUsage: true,
                warningThresholdPercent: 70,
                dangerThresholdPercent: 90,
                compactMode: false
            )

            var normal = UsageSummary(isEstimated: false, codexPath: "/tmp/codex", sessionCount: 1, modelNames: [], parseErrors: [])
            normal.primaryUsedPercent = 69.9
            expect(StatusFormatter.statusLevel(summary: normal, settings: settings) == .normal, "expected normal below warning threshold")

            var warning = normal
            warning.primaryUsedPercent = 70
            expect(StatusFormatter.statusLevel(summary: warning, settings: settings) == .warning, "expected warning at warning threshold")

            var danger = normal
            danger.primaryUsedPercent = 90
            expect(StatusFormatter.statusLevel(summary: danger, settings: settings) == .danger, "expected danger at danger threshold")

            var noPercent = normal
            noPercent.primaryUsedPercent = nil
            expect(StatusFormatter.statusLevel(summary: noPercent, settings: settings) == .normal, "expected normal when no percent is available")
        }

        await test("diagnostics exclude prompt and response content", failures: &failures) {
            var summary = UsageSummary(isEstimated: true, codexPath: "/tmp/codex", sessionCount: 1, modelNames: ["gpt-5"], parseErrors: [])
            summary.fiveHourMessages = 1
            summary.sevenDayMessages = 1

            let text = DiagnosticsReporter.report(
                summary: summary,
                pathStatus: .init(exists: true, sessionsExists: true, configExists: false, authExists: true),
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )

            expect(text.contains("Sessions (7 d)"), "expected diagnostics summary")
            expect(!text.contains("private prompt"), "must not include prompt content")
            expect(!text.contains("private answer"), "must not include response content")
        }

        await test("refresh scheduler coalesces overlapping requests into one follow-up", failures: &failures) {
            actor RefreshProbe {
                private var calls = 0
                private var firstRefreshStarted = false
                private var firstRefreshStartedWaiter: CheckedContinuation<Void, Never>?
                private var firstRefreshReleased = false
                private var releaseFirstRefresh: CheckedContinuation<Void, Never>?

                func nextCallNumber() -> Int {
                    calls += 1
                    return calls
                }

                func markFirstRefreshStarted() {
                    firstRefreshStarted = true
                    firstRefreshStartedWaiter?.resume()
                    firstRefreshStartedWaiter = nil
                }

                func waitForFirstRefreshStarted() async {
                    if firstRefreshStarted {
                        return
                    }
                    await withCheckedContinuation { continuation in
                        firstRefreshStartedWaiter = continuation
                    }
                }

                func waitUntilReleased() async {
                    if firstRefreshReleased {
                        return
                    }
                    await withCheckedContinuation { continuation in
                        releaseFirstRefresh = continuation
                    }
                }

                func releaseFirst() {
                    firstRefreshReleased = true
                    releaseFirstRefresh?.resume()
                    releaseFirstRefresh = nil
                }

                func callCount() -> Int {
                    calls
                }
            }

            let probe = RefreshProbe()
            let scheduler = RefreshScheduler<Int> {
                let callNumber = await probe.nextCallNumber()
                if callNumber == 1 {
                    await probe.markFirstRefreshStarted()
                    await probe.waitUntilReleased()
                }
                return callNumber
            }

            async let first = scheduler.requestRefresh()
            await probe.waitForFirstRefreshStarted()
            async let second = scheduler.requestRefresh()
            async let third = scheduler.requestRefresh()

            let callsBeforeRelease = await probe.callCount()
            expect(callsBeforeRelease == 1, "expected overlapping requests not to start parallel refreshes")
            await probe.releaseFirst()

            let results = await [first, second, third]
            expect(results == [1, 2, 2], "expected queued requests to share one follow-up refresh")
            let finalCalls = await probe.callCount()
            expect(finalCalls == 2, "expected one follow-up refresh after overlapping requests")
        }

        await test("refresh scheduler joins a running follow-up refresh", failures: &failures) {
            actor RefreshProbe {
                private var calls = 0
                private var firstRefreshStarted = false
                private var secondRefreshStarted = false
                private var firstRefreshStartedWaiter: CheckedContinuation<Void, Never>?
                private var secondRefreshStartedWaiter: CheckedContinuation<Void, Never>?
                private var firstRefreshReleased = false
                private var secondRefreshReleased = false
                private var releaseFirstRefresh: CheckedContinuation<Void, Never>?
                private var releaseSecondRefresh: CheckedContinuation<Void, Never>?

                func nextCallNumber() -> Int {
                    calls += 1
                    return calls
                }

                func markStarted(_ callNumber: Int) {
                    if callNumber == 1 {
                        firstRefreshStarted = true
                        firstRefreshStartedWaiter?.resume()
                        firstRefreshStartedWaiter = nil
                    } else if callNumber == 2 {
                        secondRefreshStarted = true
                        secondRefreshStartedWaiter?.resume()
                        secondRefreshStartedWaiter = nil
                    }
                }

                func waitForStarted(_ callNumber: Int) async {
                    if callNumber == 1 {
                        if firstRefreshStarted {
                            return
                        }
                        await withCheckedContinuation { continuation in
                            firstRefreshStartedWaiter = continuation
                        }
                    } else if callNumber == 2 {
                        if secondRefreshStarted {
                            return
                        }
                        await withCheckedContinuation { continuation in
                            secondRefreshStartedWaiter = continuation
                        }
                    }
                }

                func waitUntilReleased(_ callNumber: Int) async {
                    if callNumber == 1 {
                        if firstRefreshReleased {
                            return
                        }
                        await withCheckedContinuation { continuation in
                            releaseFirstRefresh = continuation
                        }
                    } else if callNumber == 2 {
                        if secondRefreshReleased {
                            return
                        }
                        await withCheckedContinuation { continuation in
                            releaseSecondRefresh = continuation
                        }
                    }
                }

                func release(_ callNumber: Int) {
                    if callNumber == 1 {
                        firstRefreshReleased = true
                        releaseFirstRefresh?.resume()
                        releaseFirstRefresh = nil
                    } else if callNumber == 2 {
                        secondRefreshReleased = true
                        releaseSecondRefresh?.resume()
                        releaseSecondRefresh = nil
                    }
                }

                func callCount() -> Int {
                    calls
                }
            }

            let probe = RefreshProbe()
            let scheduler = RefreshScheduler<Int> {
                let callNumber = await probe.nextCallNumber()
                await probe.markStarted(callNumber)
                if callNumber == 1 || callNumber == 2 {
                    await probe.waitUntilReleased(callNumber)
                }
                return callNumber
            }

            async let first = scheduler.requestRefresh()
            await probe.waitForStarted(1)
            async let second = scheduler.requestRefresh()
            await probe.release(1)
            await probe.waitForStarted(2)
            async let third = scheduler.requestRefresh()

            let callsBeforeSecondRelease = await probe.callCount()
            expect(callsBeforeSecondRelease == 2, "expected request during follow-up not to start a third refresh")
            await probe.release(2)

            let results = await [first, second, third]
            expect(results == [1, 2, 2], "expected request during follow-up to share follow-up result")
            let finalCalls = await probe.callCount()
            expect(finalCalls == 2, "expected no extra refresh after joining follow-up")
        }

        if failures.isEmpty {
            print("CodexLocalMeterCoreTests: all tests passed")
        } else {
            print("CodexLocalMeterCoreTests: \(failures.count) failure(s)")
            for failure in failures {
                print(" - \(failure)")
            }
            exit(1)
        }
    }

    private static func test(_ name: String, failures: inout [String], _ body: () async throws -> Void) async {
        do {
            try await body()
            print("PASS \(name)")
        } catch {
            failures.append("\(name): \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
