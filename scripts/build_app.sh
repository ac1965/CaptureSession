#!/bin/zsh
#
# CaptureSession.app をビルドして dist/ に置く（Xcodeプロジェクトを xcodebuild で呼ぶ）。
#
#   zsh scripts/build_app.sh
#
# 署名は既定で ad-hoc（Sign to Run Locally）。Developer ID署名と公証は行わない（無料のDeveloper Program のため）。
# ad-hoc署名は、コードを変えてビルドするたびに署名の識別子が変わり、カメラ権限の許可ダイアログが再び出る。
# 変わらない署名にするには、証明書の名前を渡す（`security find-identity -v -p codesigning` で確認）:
#
#   SIGN_IDENTITY="Apple Development: NAME (TEAMID)" zsh scripts/build_app.sh
#
# 他のMacへ渡す場合、受け取った側で初回だけ「右クリック → 開く」か、`xattr -cr CaptureSession.app` が要る。
set -euo pipefail
cd "${0:A:h:h}"

IDENTITY=${SIGN_IDENTITY:--}
if [[ $IDENTITY == "-" ]]; then
    print "⚠ ad-hoc署名です。コードを変えるたびに、カメラ権限の許可が再び必要になります。"
elif ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    print "✘ 署名の証明書が見つかりません: $IDENTITY" >&2
    print "  利用できる証明書:" >&2
    security find-identity -v -p codesigning >&2
    print "  （0件なら、先に Xcode の Settings → Accounts で Apple Development 証明書を作る）" >&2
    exit 1
fi

# xcodebuild の警告（Xcode と macOS の組み合わせ由来）が多いので、ログはファイルに残し、失敗時だけ要点を出す
mkdir -p build
if ! xcodebuild -project CaptureSession.xcodeproj -scheme CaptureSession -configuration Release \
        -derivedDataPath build CODE_SIGN_IDENTITY="$IDENTITY" build > build/xcodebuild.log 2>&1; then
    grep -E "error:" build/xcodebuild.log | sort -u >&2
    print "✘ ビルド失敗（詳細: build/xcodebuild.log）" >&2
    exit 1
fi

APP=build/Build/Products/Release/CaptureSession.app
rm -rf dist && mkdir dist
ditto "$APP" dist/CaptureSession.app

codesign --verify --strict --verbose=2 dist/CaptureSession.app
codesign -d --entitlements :- dist/CaptureSession.app 2>/dev/null | grep -q com.apple.security.device.camera \
    || { print "camera entitlement がありません" >&2; exit 1 }
print "完了: $PWD/dist/CaptureSession.app"
