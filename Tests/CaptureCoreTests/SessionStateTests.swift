import XCTest
@testable import CaptureCore

final class SessionStateTests: XCTestCase {
    /// 設計案「状態管理の設計」の4手順。現行Pythonでは連番が崩れる。
    func testSkipThenRetakeKeepsNumbering() {
        var s = SessionState()
        // 1. 1枚目をキャプチャ
        s.appendCapture(fileName: "0001_x.png")
        XCTAssertEqual(s.entries.map(\.seq), [1])
        // 2. スキップ
        s.appendSkip()
        XCTAssertEqual(s.entries.map(\.seq), [1, 2])
        // 3. 再撮り → 末尾がスキップなので何もしない
        XCTAssertFalse(s.canRetake)
        XCTAssertNil(s.removeLastCapture())
        XCTAssertEqual(s.entries.map(\.seq), [1, 2])
        // 4. 次のキャプチャは連番3（現行は2になり 0002 が衝突する）
        let e = s.appendCapture(fileName: "0003_x.png")
        XCTAssertEqual(e.seq, 3)
        XCTAssertEqual(s.entries.map(\.seq), [1, 2, 3])
    }

    func testRetakeReusesSeq() {
        var s = SessionState()
        s.appendCapture(fileName: "0001_a.png")
        XCTAssertTrue(s.canRetake)
        XCTAssertNotNil(s.removeLastCapture())
        XCTAssertEqual(s.nextSeq, 1)
        XCTAssertEqual(s.appendCapture(fileName: "0001_b.png").seq, 1)
    }

    func testProgressExcludesSkips() {
        var s = SessionState()
        s.appendCapture(fileName: "a"); s.appendSkip(); s.appendCapture(fileName: "b")
        XCTAssertEqual(s.captureCount, 2)
        XCTAssertEqual(s.skipCount, 1)
        XCTAssertEqual(s.progress(expected: 4), 0.5)
        XCTAssertNil(s.progress(expected: 0))
        XCTAssertEqual(s.progress(expected: 1), 1)
    }
}
