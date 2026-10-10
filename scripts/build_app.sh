#!/bin/zsh
#
# CaptureSession.app をビルドして dist/ に置く（Xcodeプロジェクトを xcodebuild で呼ぶ）。
#
#   zsh scripts/build_app.sh
#
# 署名は ad-hoc（Sign to Run Locally）。Developer ID署名と公証は行わない（無料のDeveloper Program のため）。
# 他のMacへ渡す場合、受け取った側で初回だけ「右クリック → 開く」か、`xattr -cr CaptureSession.app` が要る。
set -euo pipefail
cd "${0:A:h:h}"

xcodebuild -project CaptureSession.xcodeproj -scheme CaptureSession -configuration Release \
    -derivedDataPath build build | tail -3

APP=build/Build/Products/Release/CaptureSession.app
rm -rf dist && mkdir dist
ditto "$APP" dist/CaptureSession.app

codesign --verify --strict --verbose=2 dist/CaptureSession.app
codesign -d --entitlements :- dist/CaptureSession.app 2>/dev/null | grep -q com.apple.security.device.camera \
    || { print "camera entitlement がありません" >&2; exit 1 }
print "完了: $PWD/dist/CaptureSession.app"
