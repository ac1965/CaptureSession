import Foundation

/// `session_YYYYMMDD_HHMMSS/capture` と `log/capture.log` への出力。現行Python版と互換。
public final class SessionWriter: SessionWriting {
    public private(set) var sessionDirectory: URL?
    public private(set) var captureDirectory: URL?
    private var logHandle: FileHandle?

    public init() {}

    public static func stamp(_ date: Date) -> String { format(date, "yyyyMMdd_HHmmss") }

    public static func logLine(_ message: String, level: LogLevel, date: Date) -> String {
        // 現行: f"{ts} [{severity}]  {message}"（severity は5桁、後ろに空白2つ）
        "\(format(date, "yyyy-MM-dd'T'HH:mm:ss")) [\(level.rawValue)]  \(message)\n"
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }

    public func start(baseDirectory: URL, date: Date) throws {
        close()
        let session = baseDirectory.appendingPathComponent("session_\(Self.stamp(date))", isDirectory: true)
        let capture = session.appendingPathComponent("capture", isDirectory: true)
        let logDir = session.appendingPathComponent("log", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: capture, withIntermediateDirectories: true)
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("capture.log")
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle?.seekToEnd()
        sessionDirectory = session
        captureDirectory = capture
    }

    public func writeCapture(_ png: Data, seq: Int, date: Date) throws -> String {
        guard let dir = captureDirectory else { throw CocoaError(.fileNoSuchFile) }
        let name = "\(SessionState.seqString(seq))_\(Self.stamp(date)).png"
        try png.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }

    public func writeSkip(seq: Int) throws -> String {
        guard let dir = captureDirectory else { throw CocoaError(.fileNoSuchFile) }
        let name = "\(SessionState.seqString(seq))_SKIPPED.txt"
        try Data().write(to: dir.appendingPathComponent(name))
        return name
    }

    public func remove(fileName: String) throws {
        guard let dir = captureDirectory else { return }
        let url = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func log(_ message: String, level: LogLevel, date: Date) {
        guard let data = Self.logLine(message, level: level, date: date).data(using: .utf8) else { return }
        try? logHandle?.write(contentsOf: data)
    }

    public func close() {
        try? logHandle?.close()
        logHandle = nil
    }

    deinit { close() }
}
