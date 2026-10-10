// swift-tools-version:5.9
import PackageDescription

// アプリ本体は CaptureSession.xcodeproj（App/）。ここには、画面にもAVFoundationにも依存しない部分と、そのテストを置く。
let package = Package(
    name: "CaptureSession",
    // TODO(未確認事項6): 対応OSの下限は未決定。現行READMEの macOS 13 を暫定値とする。
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .library(name: "CaptureObjC", targets: ["CaptureObjC"]),
    ],
    targets: [
        // 状態管理・ファイル出力・設定
        .target(name: "CaptureCore"),
        // NSException を Swift のエラーに変換する薄いラッパー
        .target(name: "CaptureObjC"),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
    ]
)
