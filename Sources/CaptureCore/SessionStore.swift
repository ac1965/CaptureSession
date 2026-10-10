import Foundation

/// 画面が呼ぶ唯一の入口。AVFoundation にもファイルにも直接は依存しない（プロトコル越し）。
@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var state = SessionState()
    @Published public private(set) var isActive = false
    @Published public private(set) var isCapturing = false
    @Published public private(set) var status = "待機中"
    @Published public private(set) var logLines: [LogLine] = []
    /// 予定枚数（0 = 無制限）
    @Published public var expected = 0

    /// 操作の結果。画面がフラッシュ・バッジ・音で知らせるために使う（id が変わるたびに通知）。
    public struct Feedback: Equatable {
        public enum Kind { case captured, skipped, retaken, failed }
        public let id: Int
        public let kind: Kind
        public let text: String
    }
    @Published public private(set) var feedback: Feedback?
    private var feedbackCount = 0

    public struct LogLine: Identifiable, Equatable {
        public let id = UUID()
        public let text: String
        public let level: LogLevel
    }

    private let capturer: FrameCapturing
    private let writer: SessionWriting
    private let now: () -> Date

    public init(capturer: FrameCapturing, writer: SessionWriting, now: @escaping () -> Date = Date.init) {
        self.capturer = capturer
        self.writer = writer
        self.now = now
    }

    public var captureDirectory: URL? { writer.captureDirectory }
    public var sessionDirectory: URL? { writer.sessionDirectory }
    public var canCapture: Bool { isActive && !isCapturing }
    public var canRetake: Bool { isActive && !isCapturing && state.canRetake }
    public var canSkip: Bool { isActive && !isCapturing }
    public var progress: Double? { state.progress(expected: expected) }

    public func url(for entry: Entry) -> URL? {
        guard case .capture(_, let name) = entry else { return nil }
        return captureDirectory?.appendingPathComponent(name)
    }

    /// 直前のキャプチャ画像（プレビュー用）。末尾がスキップのときは表示しない。
    public var lastCaptureURL: URL? {
        guard let last = state.entries.last else { return nil }
        return url(for: last)
    }

    // MARK: セッション

    public func start(baseDirectory: URL, deviceName: String, extraLog: [String] = []) {
        guard !isActive else { return }
        do {
            try writer.start(baseDirectory: baseDirectory, date: now())
        } catch {
            record("セッションを開始できません: \(error.localizedDescription)", .error)
            status = "セッション開始失敗"
            return
        }
        state = SessionState()
        logLines = []
        isActive = true
        record("START device='\(deviceName)' session=\(SessionWriter.stamp(now()))")
        extraLog.forEach { record($0) }
        status = "セッション開始"
    }

    public func end() {
        guard isActive else { return }
        record("END captures=\(state.captureCount) skipped=\(state.skipCount)")
        writer.close()
        isActive = false
        status = "セッション終了 — \(state.captureCount) PNG / \(state.skipCount) スキップ"
    }

    // MARK: 操作

    public func capture() async {
        guard canCapture else { return }
        isCapturing = true
        defer { isCapturing = false }
        let seq = state.nextSeq
        let tag = SessionState.seqString(seq)
        status = "キャプチャ中… #\(tag)"
        do {
            let png = try await capturer.capturePNG()
            guard isActive else { return }   // 取得中にセッションが終了した
            let name = try writer.writeCapture(png, seq: seq, date: now())
            state.appendCapture(fileName: name)
            record("Captured #\(tag) → \(name)")
            notify(.captured, "#\(tag) 保存")
            status = "#\(tag) キャプチャ完了"
            if let expected = Optional(expected), expected > 0, state.captureCount >= expected {
                status = "予定枚数 \(expected) 枚に到達 — 継続または終了してください"
            }
        } catch {
            record("Capture failed #\(tag): \(error.localizedDescription)", .error)
            notify(.failed, "#\(tag) 失敗: \(error.localizedDescription)")
            status = "キャプチャ失敗 #\(tag)"
        }
    }

    public func retake() {
        guard canRetake, case .capture(let seq, let name)? = state.entries.last else { return }
        do { try writer.remove(fileName: name) } catch {
            record("Retake failed #\(SessionState.seqString(seq)): \(error.localizedDescription)", .error)
            return
        }
        state.removeLastCapture()
        record("Retake: discarded #\(SessionState.seqString(seq))")
        notify(.retaken, "#\(SessionState.seqString(seq)) を破棄")
        status = "#\(SessionState.seqString(seq)) を破棄 — 再撮りしてください"
    }

    public func skip() {
        guard canSkip else { return }
        let seq = state.nextSeq
        do { _ = try writer.writeSkip(seq: seq) } catch {
            record("Skip failed #\(SessionState.seqString(seq)): \(error.localizedDescription)", .error)
            return
        }
        state.appendSkip()
        record("Skipped #\(SessionState.seqString(seq))")
        notify(.skipped, "#\(SessionState.seqString(seq)) スキップ")
        status = "#\(SessionState.seqString(seq)) スキップ"
    }

    public func note(_ message: String, level: LogLevel = .info) { record(message, level) }

    private func notify(_ kind: Feedback.Kind, _ text: String) {
        feedbackCount += 1
        feedback = Feedback(id: feedbackCount, kind: kind, text: text)
    }

    private func record(_ message: String, _ level: LogLevel = .info) {
        let date = now()
        writer.log(message, level: level, date: date)
        logLines.append(LogLine(text: SessionWriter.logLine(message, level: level, date: date).trimmingCharacters(in: .newlines), level: level))
    }
}
