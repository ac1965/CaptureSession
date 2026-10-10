import SwiftUI
import AVFoundation
import ImageIO
import CaptureCore

// MARK: ライブプレビュー

struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        v.layer = layer
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: 操作結果の表示（フラッシュ・バッジ・音）

struct FeedbackOverlay: ViewModifier {
    @EnvironmentObject var store: SessionStore
    @State private var flash = 0.0
    @State private var shown: SessionStore.Feedback?

    func body(content: Content) -> some View {
        content
            .overlay(Color.white.opacity(flash).allowsHitTesting(false))
            .overlay(alignment: .top) {
                if let f = shown {
                    Text(f.text)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(color(f.kind).opacity(0.9), in: Capsule())
                        .padding(.top, 10)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: store.feedback) { f in
                guard let f else { return }
                if f.kind == .captured { flash = 0.85; withAnimation(.easeOut(duration: 0.35)) { flash = 0 } }
                withAnimation { shown = f }
                let id = f.id
                DispatchQueue.main.asyncAfter(deadline: .now() + (f.kind == .failed ? 4 : 1.4)) {
                    if shown?.id == id { withAnimation { shown = nil } }
                }
            }
    }

    private func color(_ k: SessionStore.Feedback.Kind) -> Color {
        switch k { case .captured: return .green; case .skipped: return .orange; case .retaken: return .gray; case .failed: return .red }
    }
}

extension View { func feedbackOverlay() -> some View { modifier(FeedbackOverlay()) } }

// MARK: サムネイル

struct Thumbnail: View {
    let url: URL?
    let entry: Entry
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Rectangle().fill(isSkip ? Color.orange.opacity(0.8) : Color.gray.opacity(0.3))
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: isSkip ? "forward.fill" : "camera").font(.title) }
            }
            .frame(width: 160, height: 90)
            Text("#\(SessionState.seqString(entry.seq))\(isSkip ? " SKIP" : "")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isSkip ? .orange : .secondary)
        }
        .task(id: url) { image = url.flatMap { Self.load($0) } }
    }

    private var isSkip: Bool { if case .skip = entry { return true } else { return false } }

    static func load(_ url: URL, maxPixel: Int = 320) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

// MARK: メイン画面

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow
    @State private var showKeys = false

    var body: some View {
        HSplitView {
            settingsPanel.frame(minWidth: 290, idealWidth: 300, maxWidth: 340)
            VStack(spacing: 0) {
                PreviewView(session: model.service.session)
                    .feedbackOverlay()
                    .frame(minHeight: 180, idealHeight: 260)
                thumbnails
                logView
            }.frame(minWidth: 480)
        }
        .frame(minWidth: 820, minHeight: 580)
        .safeAreaInset(edge: .bottom) {
            HStack { Text(model.statusText).lineLimit(1); Spacer() }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.bar)
        }
        .sheet(isPresented: $showKeys) { KeyBindingSheet().environmentObject(model) }
        .alert("カメラ権限が必要です", isPresented: $model.cameraDenied) {
            Button("システム設定を開く") { DeviceAccess.openSystemSettings() }
            Button("閉じる", role: .cancel) {}
        } message: { Text("システム設定 → プライバシーとセキュリティ → カメラ で許可してから再起動してください。") }
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("入力デバイス") {
                    VStack(alignment: .leading) {
                        Picker("", selection: $model.deviceID) {
                            ForEach(model.devices) { Text($0.name).tag($0.id) }
                        }.labelsHidden().disabled(store.isActive)
                        Button("デバイス一覧を更新") { model.refreshDevices() }.disabled(store.isActive)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("キャプチャ設定") {
                    VStack(alignment: .leading) {
                        Picker("形式", selection: $model.formatIndex) {
                            ForEach(model.formats) { Text($0.label).tag(Optional($0.index)) }
                        }
                        Picker("fps", selection: $model.fps) {
                            ForEach(model.fpsChoices, id: \.self) { Text(FormatOption.fpsLabel($0)).tag($0) }
                        }
                        Stepper("予定枚数: \(store.expected == 0 ? "無制限" : "\(store.expected)")",
                                value: Binding(get: { store.expected }, set: { model.setExpected($0) }), in: 0...999)
                    }.disabled(store.isActive)
                }
                GroupBox("出力先") {
                    VStack(alignment: .leading) {
                        Text(model.baseDirectory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("フォルダを選択…") { model.chooseDirectory() }.disabled(store.isActive)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("セッション") {
                    VStack(alignment: .leading) {
                        HStack {
                            Button("▶ 開始") { model.startSession() }.disabled(store.isActive)
                            Button("■ 終了") { store.end() }.disabled(!store.isActive)
                        }
                        Button("コントローラを開く") { openWindow(id: "controller") }
                        ProgressSection()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("キャプチャ操作") {
                    VStack(alignment: .leading) {
                        ActionButtons()
                        Button("キー設定…") { showKeys = true }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(10)
        }
        .onChange(of: model.deviceID) { _ in Task { await model.deviceChanged() } }
        .onChange(of: model.formatIndex) { _ in Task { await model.applyConfiguration() } }
        .onChange(of: model.fps) { _ in Task { await model.applyConfiguration() } }
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 164))], alignment: .leading) {
                    ForEach(store.state.entries, id: \.seq) { entry in
                        Thumbnail(url: store.url(for: entry), entry: entry).id(entry.seq)
                    }
                }.padding(6)
            }
            .onChange(of: store.state.entries.count) { _ in
                if let last = store.state.entries.last { proxy.scrollTo(last.seq) }
            }
        }
        .frame(minHeight: 120)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.logLines) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(line.level))
                            .id(line.id)
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.logLines.count) { _ in
                if let last = store.logLines.last { proxy.scrollTo(last.id) }
            }
        }
        .frame(height: 110)
        .background(Color.black.opacity(0.85))
    }

    private func color(_ level: LogLevel) -> Color {
        switch level { case .error: return .red; case .warn: return .orange; case .info: return Color(white: 0.75) }
    }
}

struct ProgressSection: View {
    @EnvironmentObject var store: SessionStore
    var emphasized = false
    var body: some View {
        let font: Font = emphasized ? .system(size: 13, weight: .medium) : .caption
        let style: HierarchicalShapeStyle = emphasized ? .primary : .secondary
        if let p = store.progress {
            ProgressView(value: p)
            Text("\(store.state.captureCount) / \(store.expected)  (\(Int(p * 100))%)").font(font).foregroundStyle(style)
        } else {
            Text("\(store.state.captureCount) PNG").font(font).foregroundStyle(style)
        }
    }
}

struct ActionButtons: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SessionStore

    var body: some View {
        let kb = model.keyBindings
        Button { model.perform(.capture) } label: {
            Label("キャプチャ [\(KeyName.display(kb.capture))]", systemImage: "camera").frame(maxWidth: .infinity)
        }.disabled(!store.canCapture)
        HStack {
            Button { model.perform(.retake) } label: {
                Label("再撮り [\(KeyName.display(kb.retake))]", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
            }.disabled(!store.canRetake)
            Button { model.perform(.skip) } label: {
                Label("スキップ [\(KeyName.display(kb.skip))]", systemImage: "forward").frame(maxWidth: .infinity)
            }.disabled(!store.canSkip)
        }
    }
}

struct KeyBindingSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kb = KeyBindings.defaults
    @State private var error = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("キー設定").font(.headline)
            Grid(alignment: .leading) {
                GridRow { Text("キャプチャ"); TextField("", text: $kb.capture).frame(width: 110) }
                GridRow { Text("再撮り"); TextField("", text: $kb.retake).frame(width: 110) }
                GridRow { Text("スキップ"); TextField("", text: $kb.skip).frame(width: 110) }
            }
            Text("例: space / return / r / s / f1〜f8").font(.caption).foregroundStyle(.secondary)
            if error { Text("空欄や同じキーの重複は設定できません").foregroundStyle(.red).font(.caption) }
            HStack {
                Button("リセット") { kb = .defaults }
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("適用") { if model.updateKeyBindings(kb) { dismiss() } else { error = true } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 300)
        .onAppear { kb = model.keyBindings }
    }
}

// MARK: コントローラ小窓

struct ControllerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SessionStore
    @State private var topmost = true
    @State private var alpha = 1.0
    var body: some View {
        VStack(spacing: 8) {
            // ライブ映像（窓を広げると大きくなる）
            PreviewView(session: model.service.session)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .feedbackOverlay()
                .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack {
                Button("▶ 開始") { model.startSession() }.disabled(store.isActive)
                Button("■ 終了") { store.end() }.disabled(!store.isActive)
                Spacer()
                Toggle("最前面", isOn: $topmost)
                Slider(value: $alpha, in: 0.2...1.0) { Text("透明度") }.frame(width: 90)
            }
            ActionButtons()
            // 状況は1行にまとめる（直前の連番・枚数・ステータス）
            HStack(spacing: 10) {
                Text(store.state.entries.last.map { "直前 #" + SessionState.seqString($0.seq) } ?? "直前 —")
                    .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.primary)
                ProgressSection(emphasized: true)
                Spacer(minLength: 0)
                Text(model.statusText).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
            }
        }
        .padding(12)
        .frame(minWidth: 360, idealWidth: 560, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .background(WindowConfigurator(topmost: topmost, alpha: alpha))
        .onAppear { topmost = model.settings.controllerTopmost; alpha = model.settings.controllerAlpha }
        .onChange(of: topmost) { model.settings.controllerTopmost = $0 }
        .onChange(of: alpha) { model.settings.controllerAlpha = $0 }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    let topmost: Bool
    let alpha: Double

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.level = topmost ? .floating : .normal
            view.window?.alphaValue = alpha
        }
    }
}
