import Foundation

/// フレーム取得（実体は AVFoundation）。PNGデータを返す。
public protocol FrameCapturing: AnyObject {
    func capturePNG() async throws -> Data
}

public enum LogLevel: String, Sendable {
    case info = "INFO "
    case warn = "WARN "
    case error = "ERROR"
}

/// セッションのファイル出力。
public protocol SessionWriting: AnyObject {
    var sessionDirectory: URL? { get }
    var captureDirectory: URL? { get }
    func start(baseDirectory: URL, date: Date) throws
    func writeCapture(_ png: Data, seq: Int, date: Date) throws -> String
    func writeSkip(seq: Int) throws -> String
    func remove(fileName: String) throws
    func log(_ message: String, level: LogLevel, date: Date)
    func close()
}
