import XCTest
@testable import CaptureCore

final class SettingsTests: XCTestCase {
    func testDefaultsAndDuplicateRejected() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let s = SettingsStore(defaults: d)
        XCTAssertEqual(s.keyBindings, .defaults)
        s.keyBindings = KeyBindings(capture: "r", retake: "r", skip: "s")   // 重複は保存されない
        XCTAssertEqual(s.keyBindings, .defaults)
        s.keyBindings = KeyBindings(capture: "Return", retake: "x", skip: "y")
        XCTAssertEqual(s.keyBindings.capture, "return")
        XCTAssertEqual(s.keyBindings.action(for: "X"), .retake)
    }

    func testAlphaClamped() {
        let s = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        s.controllerAlpha = 0.0
        XCTAssertEqual(s.controllerAlpha, 0.2)
    }
}
