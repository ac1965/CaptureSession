import XCTest
@testable import CaptureCore

private final class FakeCapturer: FrameCapturing {
    var fail = false
    func capturePNG() async throws -> Data {
        if fail { throw NSError(domain: "t", code: 1) }
        return Data([1, 2, 3])
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func files(_ store: SessionStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.captureDirectory!.path)) ?? []).sorted()
    }

    func testFourStepScenarioOnDisk() async {
        let cap = FakeCapturer()
        let store = SessionStore(capturer: cap, writer: SessionWriter())
        store.start(baseDirectory: base, deviceName: "fake")
        await store.capture()
        store.skip()
        XCTAssertFalse(store.canRetake)
        store.retake()                       // 無視される
        await store.capture()
        let names = files(store)
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names[0].hasPrefix("0001_") && names[0].hasSuffix(".png"))
        XCTAssertEqual(names[1], "0002_SKIPPED.txt")
        XCTAssertTrue(names[2].hasPrefix("0003_"))
        store.end()
    }

    func testRetakeRemovesFileAndFailureKeepsSeq() async {
        let cap = FakeCapturer()
        let store = SessionStore(capturer: cap, writer: SessionWriter())
        store.start(baseDirectory: base, deviceName: "fake")
        await store.capture()
        store.retake()
        XCTAssertEqual(files(store), [])
        cap.fail = true
        await store.capture()
        XCTAssertEqual(store.state.nextSeq, 1)
        XCTAssertEqual(store.logLines.last?.level, .error)
        store.end()
    }

    func testLogFormatAndLayout() {
        let d = Date(timeIntervalSince1970: 0)
        let line = SessionWriter.logLine("hello", level: .warn, date: d)
        XCTAssertTrue(line.contains(" [WARN ]  hello\n"))
        let w = SessionWriter()
        try? w.start(baseDirectory: base, date: d)
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.sessionDirectory!.appendingPathComponent("log/capture.log").path))
        XCTAssertTrue(w.sessionDirectory!.lastPathComponent.hasPrefix("session_"))
    }
}
