import Foundation

public struct LiveTelemetryResult: Sendable {
    public var primaryUsedPercent: Double?
    public var secondaryUsedPercent: Double?
    public var primaryResetsAt: Date?
    public var secondaryResetsAt: Date?
    public var observedAt: Date
}

public enum LiveTelemetryError: LocalizedError {
    case couldNotStart
    case timedOut
    case connectionClosed
    case initialisationRejected
    case unavailable
    case unrecognisedResponse

    public var errorDescription: String? {
        switch self {
        case .couldNotStart: "Codex App Server could not be started."
        case .timedOut: "Codex App Server did not return rate limits in time."
        case .connectionClosed: "Codex App Server connection closed unexpectedly."
        case .initialisationRejected: "Codex App Server rejected initialisation."
        case .unavailable: "Codex account rate limits are unavailable."
        case .unrecognisedResponse: "Codex returned an unrecognised rate-limit response."
        }
    }
}

public struct LiveTelemetryReader: Sendable {
    public init() {}

    public func read(clientVersion: String = "macos", timeoutSeconds: Double = 10) async throws -> LiveTelemetryResult {
        try await withCheckedThrowingContinuation { continuation in
            let operation = TelemetryOperation(continuation: continuation)
            operation.start(clientVersion: clientVersion, timeoutSeconds: timeoutSeconds)
        }
    }

    public static func parseAccountRateLimitsResult(_ value: Any, observedAt: Date = Date()) -> LiveTelemetryResult? {
        guard let result = value as? [String: Any] else { return nil }
        let byLimitID = result["rateLimitsByLimitId"] as? [String: Any]
        let codexBucket = byLimitID?["codex"] as? [String: Any]
        guard let bucket = codexBucket ?? result["rateLimits"] as? [String: Any] else { return nil }
        let primary = parseWindow(bucket["primary"])
        let secondary = parseWindow(bucket["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return LiveTelemetryResult(
            primaryUsedPercent: primary?.percent,
            secondaryUsedPercent: secondary?.percent,
            primaryResetsAt: primary?.reset,
            secondaryResetsAt: secondary?.reset,
            observedAt: observedAt
        )
    }

    private static func parseWindow(_ value: Any?) -> (percent: Double?, reset: Date?)? {
        guard let record = value as? [String: Any] else { return nil }
        let rawPercent = (record["usedPercent"] as? NSNumber)?.doubleValue
        let percent = rawPercent.flatMap { (0...100).contains($0) ? $0 : nil }
        let resetSeconds = (record["resetsAt"] as? NSNumber)?.doubleValue
        let reset = resetSeconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        let duration = (record["windowDurationMins"] as? NSNumber)?.doubleValue
        return percent != nil || reset != nil || (duration ?? 0) > 0 ? (percent, reset) : nil
    }
}

private final class TelemetryOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LiveTelemetryResult, Error>?
    private var process: Process?
    private var buffer = Data()

    init(continuation: CheckedContinuation<LiveTelemetryResult, Error>) {
        self.continuation = continuation
    }

    func start(clientVersion: String, timeoutSeconds: Double) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        guard let executable = Self.codexExecutable() else {
            finish(.failure(LiveTelemetryError.couldNotStart))
            return
        }
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.process = process

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData, input: input)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish(.failure(LiveTelemetryError.connectionClosed))
        }

        do {
            try process.run()
            send([
                "method": "initialize",
                "id": 1,
                "params": ["clientInfo": ["name": "codex_local_meter", "title": "Codex Local Meter", "version": clientVersion]]
            ], to: input)
        } catch {
            finish(.failure(LiveTelemetryError.couldNotStart))
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
            self?.finish(.failure(LiveTelemetryError.timedOut))
        }
    }

    private static func codexExecutable() -> URL? {
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ])
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }

    private func receive(_ data: Data, input: Pipe) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        let bytes = buffer
        lock.unlock()
        guard let text = String(data: bytes, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return }
        lock.lock()
        buffer = Data(lines.last!.utf8)
        lock.unlock()

        for line in lines.dropLast() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let message = object as? [String: Any],
                  let id = (message["id"] as? NSNumber)?.intValue else { continue }
            if id == 1 {
                guard message["error"] == nil else {
                    finish(.failure(LiveTelemetryError.initialisationRejected)); return
                }
                send(["method": "initialized", "params": [:]], to: input)
                send(["method": "account/rateLimits/read", "id": 2], to: input)
            } else if id == 2 {
                guard message["error"] == nil else {
                    finish(.failure(LiveTelemetryError.unavailable)); return
                }
                guard let result = message["result"],
                      let parsed = LiveTelemetryReader.parseAccountRateLimitsResult(result) else {
                    finish(.failure(LiveTelemetryError.unrecognisedResponse)); return
                }
                finish(.success(parsed)); return
            }
        }
    }

    private func send(_ message: [String: Any], to pipe: Pipe) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        var line = data
        line.append(0x0A)
        try? pipe.fileHandleForWriting.write(contentsOf: line)
    }

    private func finish(_ result: Result<LiveTelemetryResult, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let process = self.process
        self.process = nil
        lock.unlock()
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        continuation.resume(with: result)
    }
}
