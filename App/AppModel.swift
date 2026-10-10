import AppKit
import SwiftUI
import CaptureCore
import Combine

/// 画面側の状態（デバイス・設定）。セッションの規則は SessionStore に任せる。
@MainActor
final class AppModel: ObservableObject {
    let settings = SettingsStore()
    let service = CaptureService()
    let store: SessionStore

    @Published var devices: [DeviceInfo] = []
    @Published var deviceID: String = ""
    @Published var formats: [FormatOption] = []
    @Published var formatIndex: Int?
    @Published var fps: Double = 30
    @Published var baseDirectory: URL
    @Published var keyBindings: KeyBindings
    @Published var cameraDenied = false
    @Published var statusOverride: String?

    private var monitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init() {
        store = SessionStore(capturer: service, writer: SessionWriter())
        baseDirectory = settings.baseDirectory
        keyBindings = settings.keyBindings
        store.expected = settings.expectedCount
        installKeyMonitor()
        // 操作結果を音でも知らせる（ウィンドウが隠れていても分かる）
        store.$feedback.compactMap { $0 }.sink { f in
            switch f.kind {
            case .captured: NSSound(named: "Tink")?.play()
            case .failed: NSSound(named: "Basso")?.play()
            default: break
            }
        }.store(in: &cancellables)
        Task { await prepare() }
    }

    var selectedFormat: FormatOption? { formats.first { $0.index == formatIndex } }
    var fpsChoices: [Double] { selectedFormat?.fpsChoices ?? [] }
    var deviceName: String { devices.first { $0.id == deviceID }?.name ?? "" }
    var statusText: String { statusOverride ?? store.status }

    func prepare() async {
        guard await DeviceAccess.ensureAuthorized() else {
            cameraDenied = true
            statusOverride = "カメラ権限: 未許可 — システム設定で許可してください"
            return
        }
        cameraDenied = false
        statusOverride = nil
        refreshDevices()
    }

    func refreshDevices() {
        devices = DeviceCatalog.devices()
        if !devices.contains(where: { $0.id == deviceID }) { deviceID = devices.first?.id ?? "" }
        statusOverride = devices.isEmpty ? "デバイスが見つかりません" : nil
        Task { await deviceChanged() }
    }

    func deviceChanged() async {
        guard let dev = DeviceCatalog.device(id: deviceID) else { formats = []; formatIndex = nil; return }
        formats = DeviceCatalog.formats(of: dev)
        // 未確認事項1: 機器が実際に出せる組み合わせを一覧にするため、選択肢は device.formats から作る。
        if !formats.contains(where: { $0.index == formatIndex }) {
            formatIndex = (formats.first { $0.width == 1920 && $0.height == 1080 } ?? formats.max { $0.width * $0.height < $1.width * $1.height })?.index
        }
        await applyConfiguration()
    }

    func applyConfiguration() async {
        if let choices = selectedFormat?.fpsChoices, !choices.isEmpty, !choices.contains(fps) {
            // 30に最も近い値を既定にする
            fps = choices.min(by: { abs($0 - 30) < abs($1 - 30) }) ?? choices[0]
        }
        guard !deviceID.isEmpty else { return }
        do {
            let warnings = try await service.configure(deviceID: deviceID, formatIndex: formatIndex, fps: fps)
            statusOverride = warnings.isEmpty ? nil : warnings.joined(separator: " / ")
        } catch {
            statusOverride = "デバイス設定エラー: \(error.localizedDescription)"
        }
    }

    // MARK: セッション

    func startSession() {
        guard !deviceID.isEmpty else { statusOverride = "先にデバイスを選択してください"; return }
        statusOverride = nil
        settings.baseDirectory = baseDirectory
        let lines = formats.map { "Format[\($0.index)] \($0.label) fps:\($0.rangeText)" }
        let active = selectedFormat.map { "Active \($0.label) \(FormatOption.fpsLabel(fps))fps" }
        store.start(baseDirectory: baseDirectory, deviceName: deviceName, extraLog: lines + [active].compactMap { $0 })
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = baseDirectory
        if panel.runModal() == .OK, let url = panel.url {
            baseDirectory = url
            settings.baseDirectory = url
        }
    }

    func setExpected(_ n: Int) {
        store.expected = max(0, n)
        settings.expectedCount = store.expected
    }

    func updateKeyBindings(_ kb: KeyBindings) -> Bool {
        guard kb.isValid else { return false }
        settings.keyBindings = kb
        keyBindings = settings.keyBindings
        return true
    }

    // MARK: キー操作

    func perform(_ action: KeyBindings.Action) {
        switch action {
        case .capture: Task { await store.capture() }
        case .retake: store.retake()
        case .skip: store.skip()
        }
    }

    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.store.isActive,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText),
                  let key = KeyName.name(for: event),
                  let action = self.keyBindings.action(for: key) else { return event }
            self.perform(action)
            return nil
        }
    }
}

enum KeyName {
    private static let special: [UInt16: String] = [
        49: "space", 36: "return", 76: "return", 48: "tab", 53: "escape",
        126: "up", 125: "down", 123: "left", 124: "right",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
    ]

    static func name(for event: NSEvent) -> String? {
        if let s = special[event.keyCode] { return s }
        return event.charactersIgnoringModifiers?.lowercased()
    }

    static func display(_ key: String) -> String { key == "space" ? "Space" : key.capitalized }
}
