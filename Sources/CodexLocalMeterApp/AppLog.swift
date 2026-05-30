import Foundation

enum AppLog {
    private static let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexLocalMeterApp.log")

    static func write(_ message: String) {
        let line = "[\(Date().ISO8601Format())] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    static var path: String {
        logURL.path
    }
}
