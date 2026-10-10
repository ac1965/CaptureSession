import Foundation

public struct KeyBindings: Equatable, Codable, Sendable {
    public var capture: String
    public var retake: String
    public var skip: String

    public static let defaults = KeyBindings(capture: "space", retake: "r", skip: "s")

    public init(capture: String, retake: String, skip: String) {
        self.capture = capture; self.retake = retake; self.skip = skip
    }

    public var normalized: KeyBindings {
        func n(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        return KeyBindings(capture: n(capture), retake: n(retake), skip: n(skip))
    }

    /// 空欄・重複は不可。
    public var isValid: Bool {
        let v = normalized
        let all = [v.capture, v.retake, v.skip]
        return !all.contains("") && Set(all).count == all.count
    }

    public enum Action { case capture, retake, skip }

    public func action(for key: String) -> Action? {
        let v = normalized, k = key.lowercased()
        if k == v.capture { return .capture }
        if k == v.retake { return .retake }
        if k == v.skip { return .skip }
        return nil
    }
}

public final class SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var keyBindings: KeyBindings {
        get {
            guard let data = defaults.data(forKey: "keyBindings"),
                  let kb = try? JSONDecoder().decode(KeyBindings.self, from: data), kb.isValid
            else { return .defaults }
            return kb
        }
        set {
            guard newValue.isValid, let data = try? JSONEncoder().encode(newValue.normalized) else { return }
            defaults.set(data, forKey: "keyBindings")
        }
    }

    public var baseDirectory: URL {
        get {
            if let p = defaults.string(forKey: "baseDirectory") { return URL(fileURLWithPath: p, isDirectory: true) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("capture_session", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: "baseDirectory") }
    }

    public var expectedCount: Int {
        get { defaults.integer(forKey: "expectedCount") }
        set { defaults.set(max(0, newValue), forKey: "expectedCount") }
    }

    public var controllerTopmost: Bool {
        get { defaults.object(forKey: "controllerTopmost") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "controllerTopmost") }
    }

    /// 0.2...1.0
    public var controllerAlpha: Double {
        get { min(1, max(0.2, defaults.object(forKey: "controllerAlpha") as? Double ?? 1.0)) }
        set { defaults.set(min(1, max(0.2, newValue)), forKey: "controllerAlpha") }
    }
}
