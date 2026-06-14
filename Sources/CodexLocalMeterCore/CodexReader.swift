import Foundation

public struct CodexReader {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func readEvents(codexPath: String) async -> ReadResult {
        var events: [RawEvent] = []
        var parseErrors: [String] = []
        let sessionsURL = URL(fileURLWithPath: codexPath).appendingPathComponent("sessions", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionsURL.path, isDirectory: &isDirectory) else {
            return ReadResult(events: events, parseErrors: parseErrors)
        }
        guard isDirectory.boolValue else {
            return ReadResult(events: events, parseErrors: ["Expected a directory at: \(sessionsURL.path)"])
        }

        let files = collectJsonlFiles(from: sessionsURL, parseErrors: &parseErrors)
        for file in files {
            parseJsonlFile(file, events: &events, parseErrors: &parseErrors)
        }

        return ReadResult(events: events, parseErrors: parseErrors)
    }

    private func collectJsonlFiles(from directory: URL, parseErrors: inout [String]) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            parseErrors.append("Cannot read directory \(directory.path)")
            return []
        }

        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func parseJsonlFile(_ file: URL, events: inout [RawEvent], parseErrors: inout [String]) {
        let content: String
        do {
            content = try String(contentsOf: file, encoding: .utf8)
        } catch {
            parseErrors.append("Cannot read file \(file.path): \(error.localizedDescription)")
            return
        }

        let parts = file.pathComponents
        let sessionId = parts.suffix(2).joined(separator: "/")

        for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }

            let record: Any
            do {
                record = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
            } catch {
                parseErrors.append("\(file.path):\(index + 1): invalid JSON - skipped")
                continue
            }

            if let event = extractEvent(record, sessionId: sessionId) {
                events.append(event)
            }
        }
    }

    private func extractEvent(_ record: Any, sessionId: String) -> RawEvent? {
        guard let object = record as? [String: Any], let timestamp = resolveTimestamp(object) else {
            return nil
        }

        if let eventType = object["type"] as? String,
           let payload = object["payload"] as? [String: Any] {
            return extractCodexDesktopEvent(eventType: eventType, payload: payload, timestamp: timestamp, sessionId: sessionId)
        }

        let model = object["model"] as? String
        let inputTokens =
            resolveInt(object, "input_tokens") ??
            resolveInt(object, "inputTokens") ??
            resolveInt(object, "prompt_tokens") ??
            resolveNestedInt(object, "usage", "input_tokens") ??
            resolveNestedInt(object, "usage", "prompt_tokens")
        let outputTokens =
            resolveInt(object, "output_tokens") ??
            resolveInt(object, "outputTokens") ??
            resolveInt(object, "completion_tokens") ??
            resolveNestedInt(object, "usage", "output_tokens") ??
            resolveNestedInt(object, "usage", "completion_tokens")
        let messageCount = resolveInt(object, "message_count") ?? resolveInt(object, "messageCount")

        return RawEvent(
            sessionId: sessionId,
            timestamp: timestamp,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            messageCount: messageCount
        )
    }

    private func extractCodexDesktopEvent(eventType: String, payload: [String: Any], timestamp: Date, sessionId: String) -> RawEvent? {
        let payloadType = payload["type"] as? String

        if eventType == "event_msg", payloadType == "token_count" {
            var inputTokens: Int?
            var outputTokens: Int?
            if let info = payload["info"] as? [String: Any],
               let usage = info["last_token_usage"] as? [String: Any] {
                inputTokens = resolveInt(usage, "input_tokens")
                outputTokens = resolveInt(usage, "output_tokens")
            }

            var primaryUsedPercent: Double?
            var secondaryUsedPercent: Double?
            var primaryResetsAt: Date?
            var secondaryResetsAt: Date?
            if let rateLimits = payload["rate_limits"] as? [String: Any] {
                if let primary = rateLimits["primary"] as? [String: Any] {
                    primaryUsedPercent = resolveDouble(primary, "used_percent")
                    primaryResetsAt = resolveEpochSeconds(primary, "resets_at")
                }
                if let secondary = rateLimits["secondary"] as? [String: Any] {
                    secondaryUsedPercent = resolveDouble(secondary, "used_percent")
                    secondaryResetsAt = resolveEpochSeconds(secondary, "resets_at")
                }
            }

            return RawEvent(
                sessionId: sessionId,
                timestamp: timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                primaryUsedPercent: primaryUsedPercent,
                secondaryUsedPercent: secondaryUsedPercent,
                primaryResetsAt: primaryResetsAt,
                secondaryResetsAt: secondaryResetsAt
            )
        }

        if eventType == "event_msg", payloadType == "user_message" {
            return RawEvent(sessionId: sessionId, timestamp: timestamp, messageCount: 1)
        }

        return nil
    }
}

private func resolveTimestamp(_ object: [String: Any]) -> Date? {
    for key in ["timestamp", "ts", "created_at", "time", "date"] {
        if let text = object[key] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) ?? fallbackFormatter.date(from: text) {
                return date
            }
        } else if let number = object[key] as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1000.0)
        }
    }
    return nil
}

private func resolveInt(_ object: [String: Any], _ key: String) -> Int? {
    if let value = object[key] as? Int {
        return value
    }
    if let value = object[key] as? NSNumber {
        return value.intValue
    }
    return nil
}

private func resolveDouble(_ object: [String: Any], _ key: String) -> Double? {
    if let value = object[key] as? Double {
        return value
    }
    if let value = object[key] as? NSNumber {
        return value.doubleValue
    }
    return nil
}

private func resolveEpochSeconds(_ object: [String: Any], _ key: String) -> Date? {
    if let value = object[key] as? NSNumber {
        return Date(timeIntervalSince1970: value.doubleValue)
    }
    return nil
}

private func resolveNestedInt(_ object: [String: Any], _ parentKey: String, _ childKey: String) -> Int? {
    guard let parent = object[parentKey] as? [String: Any] else {
        return nil
    }
    return resolveInt(parent, childKey)
}
