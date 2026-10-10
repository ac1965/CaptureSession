import AVFoundation
import CoreImage
import CaptureCore
import CaptureObjC

enum CaptureError: LocalizedError {
    case deviceNotFound, avException(String), cannotAddInput, cannotAddOutput, busy, timeout, encodeFailed, notRunning

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "デバイスが見つかりません"
        case .avException(let reason): return "AVFoundation: \(reason)"
        case .cannotAddInput: return "入力を追加できません"
        case .cannotAddOutput: return "出力を追加できません"
        case .busy: return "キャプチャ処理中です"
        case .timeout: return "フレームが届きません（タイムアウト）"
        case .encodeFailed: return "PNGへの変換に失敗しました"
        case .notRunning: return "デバイスが選択されていません"
        }
    }
}

/// AVCaptureSession を常時起動し、キャプチャ要求後の最初の1フレームをPNGにする。
final class CaptureService: NSObject, FrameCapturing, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "capture.session")
    private let frameQueue = DispatchQueue(label: "capture.frames")
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var pending: CheckedContinuation<Data, Error>?
    private var running = false

    override init() {
        super.init()
        // フレームが溜まって遅れないよう、遅いフレームは捨てる
        output.alwaysDiscardsLateVideoFrames = true
        // TODO(未確認事項2): videoSettings（受け取るピクセル形式）は、ffmpeg版と色味が一致するか実機で確認してから決める。
        output.setSampleBufferDelegate(self, queue: frameQueue)
    }

    /// デバイス・フォーマット・fps を設定して開始する。戻り値は適用できなかった設定の警告。
    func configure(deviceID: String, formatIndex: Int?, fps: Double?) async throws -> [String] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String], Error>) in
            sessionQueue.async {
                do { c.resume(returning: try self.configureSync(deviceID: deviceID, formatIndex: formatIndex, fps: fps)) }
                catch { c.resume(throwing: error) }
            }
        }
    }

    private func configureSync(deviceID: String, formatIndex: Int?, fps: Double?) throws -> [String] {
        guard let device = DeviceCatalog.device(id: deviceID) else { throw CaptureError.deviceNotFound }
        var warnings: [String] = []
        // beginConfiguration〜commitConfiguration の間では startRunning() を呼べないので、確定してから開始する
        try reconfigure(device: device, formatIndex: formatIndex, fps: fps, warnings: &warnings)
        if !session.isRunning { try guarded { self.session.startRunning() } }
        running = true
        return warnings
    }

    private func reconfigure(device: AVCaptureDevice, formatIndex: Int?, fps: Double?, warnings: inout [String]) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
            session.addOutput(output)
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // 機器が対応しない設定は NSException になる。落とさず、警告にして機器の既定のまま使う。
        if let i = formatIndex, device.formats.indices.contains(i) {
            do { try guarded { device.activeFormat = device.formats[i] } }
            catch { warnings.append("形式を設定できません: \(error.localizedDescription)") }
        }
        if let fps, fps > 0 {
            if let d = DeviceCatalog.frameDuration(for: fps, format: device.activeFormat) {
                do {
                    try guarded {
                        device.activeVideoMinFrameDuration = d
                        device.activeVideoMaxFrameDuration = d
                    }
                } catch { warnings.append("fps \(FormatOption.fpsLabel(fps)) を設定できません: \(error.localizedDescription)") }
            } else {
                warnings.append("fps \(FormatOption.fpsLabel(fps)) はこの形式の対応範囲外です")
            }
        }
    }

    private func guarded(_ block: () -> Void) throws {
        var error: NSError?
        if !CSObjCTry(block, &error) { throw CaptureError.avException(error?.localizedDescription ?? "不明") }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.running = false
        }
    }

    // MARK: FrameCapturing

    func capturePNG() async throws -> Data {
        guard running else { throw CaptureError.notRunning }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            lock.lock()
            if pending != nil { lock.unlock(); c.resume(throwing: CaptureError.busy); return }
            pending = c
            lock.unlock()
            frameQueue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.fail(with: CaptureError.timeout) }
        }
    }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock(); defer { lock.unlock() }
        let c = pending; pending = nil; return c
    }

    private func fail(with error: Error) { take()?.resume(throwing: error) }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 要求が無いときは何もしない（バッファを長く持たない）
        guard let c = take() else { return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { c.resume(throwing: CaptureError.encodeFailed); return }
        let image = CIImage(cvPixelBuffer: pixels)
        // TODO(未確認事項2): 色空間は暫定で sRGB。ffmpeg版との画素値比較で確定する。
        if let data = ciContext.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
            c.resume(returning: data)
        } else {
            c.resume(throwing: CaptureError.encodeFailed)
        }
    }
}
