import Foundation

/// セッション内の1件（キャプチャまたはスキップ）。
public enum Entry: Equatable, Sendable {
    case capture(seq: Int, fileName: String)
    case skip(seq: Int)

    public var seq: Int {
        switch self {
        case .capture(let seq, _), .skip(let seq): return seq
        }
    }
}

/// 連番・再撮り・スキップの規則。状態は `entries` の1本だけで持つ。
public struct SessionState: Equatable, Sendable {
    public private(set) var entries: [Entry] = []

    public init() {}

    /// 次の連番は「末尾の連番 + 1」。
    public var nextSeq: Int { (entries.last?.seq ?? 0) + 1 }

    public var captureCount: Int {
        entries.reduce(0) { if case .capture = $1 { return $0 + 1 } else { return $0 } }
    }

    public var skipCount: Int { entries.count - captureCount }

    /// 再撮りできるのは、末尾のエントリがキャプチャのときだけ。
    public var canRetake: Bool {
        if case .capture = entries.last { return true }
        return false
    }

    public var lastCapture: Entry? {
        if case .capture = entries.last { return entries.last }
        return entries.last(where: { if case .capture = $0 { return true } else { return false } })
    }

    @discardableResult
    public mutating func appendCapture(fileName: String) -> Entry {
        let entry = Entry.capture(seq: nextSeq, fileName: fileName)
        entries.append(entry)
        return entry
    }

    @discardableResult
    public mutating func appendSkip() -> Entry {
        let entry = Entry.skip(seq: nextSeq)
        entries.append(entry)
        return entry
    }

    /// 末尾がキャプチャのときだけ取り除く。それ以外は何もしない。
    @discardableResult
    public mutating func removeLastCapture() -> Entry? {
        guard canRetake else { return nil }
        return entries.removeLast()
    }

    /// 進捗（0...1）。予定枚数が0（無制限）のときは nil。スキップは分母にも分子にも含めない。
    public func progress(expected: Int) -> Double? {
        guard expected > 0 else { return nil }
        return min(1, Double(captureCount) / Double(expected))
    }

    public static func seqString(_ seq: Int) -> String { String(format: "%04d", seq) }
}
