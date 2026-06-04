"""
setup_app.py — py2app で .app バンドルを生成する設定ファイル
使い方:
  pip3 install py2app
  python3 setup_app.py py2app
成果物: dist/CaptureSession.app
"""
from setuptools import setup

APP     = ["capture_session_gui.py"]
OPTIONS = {
    "argv_emulation": False,          # macOS 14+ では False 推奨
    "iconfile": None,                 # .icns があれば "AppIcon.icns" に変更
    "plist": {
        "CFBundleName":               "CaptureSession",
        "CFBundleDisplayName":        "Capture Session",
        "CFBundleIdentifier":         "net.ty07.capture-session",
        "CFBundleVersion":            "1.0.0",
        "CFBundleShortVersionString": "1.0",
        # カメラ使用許可 (avfoundation / ffmpeg が必要)
        "NSCameraUsageDescription":   "HDMIキャプチャデバイスからスナップショットを取得します",
        "NSMicrophoneUsageDescription": "使用しません",
        # Dock アイコンを表示
        "LSUIElement": False,
    },
    "packages": [
        # pyobjc: Python から AVFoundation を呼び出すために必要
        # TCC にカメラ権限エントリを登録する（システム設定に表示させる）
        "objc",
        "AVFoundation",
    ],
    "includes": ["tkinter"],
    "excludes": ["numpy", "PIL", "scipy"],
}

setup(
    name    = "CaptureSession",
    app     = APP,
    options = {"py2app": OPTIONS},
)
