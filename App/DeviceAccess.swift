import AVFoundation
import AppKit

/// カメラ権限。Info.plist の NSCameraUsageDescription と entitlement com.apple.security.device.camera が先に必要。
enum DeviceAccess {
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// 未確定のときだけダイアログを出す。
    static func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct FormatOption: Identifiable, Hashable {
    let index: Int            // device.formats のインデックス
    let width: Int
    let height: Int
    let pixelFormat: String   // FourCC
    let fpsChoices: [Double]
    let rangeText: String
    var id: Int { index }
    var label: String { "\(width)x\(height) \(pixelFormat)" }
    static func fpsLabel(_ fps: Double) -> String { String(format: "%g", fps) }
}

struct DeviceInfo: Identifiable, Hashable {
    let id: String            // uniqueID
    let name: String
}

enum DeviceCatalog {
    static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        // 未確認事項1・6: HDMIキャプチャ機器がどの種別で出るかは実機で確認する。
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(.external) } else { types.append(.externalUnknown) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
    }

    static func devices() -> [DeviceInfo] {
        discoverySession().devices.map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func device(id: String) -> AVCaptureDevice? { AVCaptureDevice(uniqueID: id) }

    static func formats(of device: AVCaptureDevice) -> [FormatOption] {
        device.formats.enumerated().map { index, f in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let ranges = f.videoSupportedFrameRateRanges
            // 機器が実際に返した範囲の両端だけを選択肢にする（29.97 / 59.94 などの機器がある）
            let rates = Set(ranges.flatMap { [$0.minFrameRate, $0.maxFrameRate] }.map { ($0 * 100).rounded() / 100 })
            let text = ranges.map { "\($0.minFrameRate)-\($0.maxFrameRate)fps" }.joined(separator: ",")
            return FormatOption(index: index, width: Int(dim.width), height: Int(dim.height),
                                pixelFormat: fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription)),
                                fpsChoices: rates.sorted(), rangeText: text)
        }
    }

    /// 要求fpsに対するフレーム間隔。範囲の端なら機器が返した値をそのまま使う。範囲外なら nil。
    static func frameDuration(for fps: Double, format: AVCaptureDevice.Format) -> CMTime? {
        for r in format.videoSupportedFrameRateRanges {
            if abs(r.maxFrameRate - fps) < 0.01 { return r.minFrameDuration }
            if abs(r.minFrameRate - fps) < 0.01 { return r.maxFrameDuration }
        }
        for r in format.videoSupportedFrameRateRanges where fps >= r.minFrameRate && fps <= r.maxFrameRate {
            return CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        }
        return nil
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        let s = String(bytes: bytes, encoding: .ascii) ?? ""
        return s.allSatisfy { $0.isASCII && !$0.isWhitespace || $0 == " " } && !s.isEmpty ? s : String(code)
    }
}
