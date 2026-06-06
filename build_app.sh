#!/bin/zsh
#
# build_app.sh
# capture_session_gui.py を CaptureSession.app にビルドする
# 実行: zsh build_app.sh
#
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"
APP_NAME="CaptureSession"
PY_SCRIPT="capture_session_gui.py"
SETUP_SCRIPT="setup_app.py"
DIST_DIR="dist"
VENV_DIR=".venv_build"
ENTITLEMENTS="entitlements.plist"
BUNDLE_ID="net.ty07.capture-session"

# ── 色付き出力 ──────────────────────────────────────────────────
ok()   { print -P "%F{green}✔%f $*" }
info() { print -P "%F{cyan}➜%f $*" }
warn() { print -P "%F{yellow}⚠%f $*" }
err()  { print -P "%F{red}✘%f $*" >&2; exit 1 }

info "=== $APP_NAME .app ビルド開始 ==="

# ── 前提チェック ────────────────────────────────────────────────
# Python3
if ! command -v python3 &>/dev/null; then
    err "python3 が見つかりません。'brew install python' でインストールしてください。"
fi
PY=$(command -v python3)
PY_VER=$($PY --version 2>&1)
ok "Python: $PY_VER ($PY)"

# tkinter
if ! $PY -c "import tkinter" 2>/dev/null; then
    err "tkinter が使えません。'brew install python-tk' を試してください。"
fi
ok "tkinter: OK"

# ffmpeg（警告のみ）
if ! command -v ffmpeg &>/dev/null; then
    warn "ffmpeg が見つかりません。.app 内には同梱されません。"
    print "  実行環境でも 'brew install ffmpeg' が必要です。"
fi

# ソースファイル確認
[[ -f "$PY_SCRIPT"   ]] || err "$PY_SCRIPT が見つかりません"
[[ -f "$SETUP_SCRIPT" ]] || err "$SETUP_SCRIPT が見つかりません"

# ── entitlements.plist 生成（なければ自動作成） ─────────────────
if [[ ! -f "$ENTITLEMENTS" ]]; then
    info "entitlements.plist を生成中…"
    cat > "$ENTITLEMENTS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- AVFoundation / HDMI キャプチャデバイスへのアクセス -->
    <key>com.apple.security.device.camera</key>
    <true/>
    <!-- ffmpeg が audio デバイス列挙時に要求する場合がある -->
    <key>com.apple.security.device.microphone</key>
    <true/>
</dict>
</plist>
EOF
    ok "entitlements.plist を生成しました"
else
    ok "entitlements.plist: 既存を使用"
fi

# ── venv 作成 ───────────────────────────────────────────────────
if [[ ! -d "$VENV_DIR" ]]; then
    info "venv を作成中: $VENV_DIR"
    $PY -m venv "$VENV_DIR"
    ok "venv 作成完了"
else
    ok "venv: 既存を再利用 ($VENV_DIR)"
fi
VENV_PY="$VENV_DIR/bin/python"

# ── py2app インストール ─────────────────────────────────────────
if ! "$VENV_PY" -c "import py2app" 2>/dev/null; then
    info "py2app をインストール中…"
    "$VENV_PY" -m pip install --quiet py2app
    ok "py2app インストール完了"
else
    ok "py2app: 既インストール"
fi

# pyobjc: Python から AVCaptureDevice を呼び出すために必要
# TCC にカメラ権限エントリを登録する（システム設定に表示させる）
if ! "$VENV_PY" -c "import objc" 2>/dev/null; then
    info "pyobjc-framework-AVFoundation をインストール中…"
    "$VENV_PY" -m pip install --quiet pyobjc-framework-AVFoundation
    ok "pyobjc インストール完了"
else
    ok "pyobjc: 既インストール"
fi

# ── クリーンビルド ──────────────────────────────────────────────
if [[ -d "$DIST_DIR" ]]; then
    info "dist/ を削除中…"
    rm -rf "$DIST_DIR"
fi
[[ -d "build" ]] && rm -rf build

# ── ビルド実行 ──────────────────────────────────────────────────
info "py2app ビルド中（数分かかる場合があります）…"
"$VENV_PY" "$SETUP_SCRIPT" py2app --quiet 2>&1 | tail -20

APP_PATH="$DIST_DIR/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || err "ビルド失敗: $APP_PATH が生成されませんでした"
ok "ビルド成功: $APP_PATH"

# ── コード署名 + entitlements 付与 ─────────────────────────────
#
#   "-" = ad-hoc 署名（Apple Developer 証明書不要）
#   --deep = フレームワーク・ヘルパー等を再帰的に署名
#   --force = 既存署名を上書き
#
info "コード署名中（ad-hoc + entitlements）…"
codesign \
    --force \
    --deep \
    --sign - \
    --entitlements "$ENTITLEMENTS" \
    --identifier  "$BUNDLE_ID" \
    "$APP_PATH"
ok "コード署名完了"

# ── 署名検証 ────────────────────────────────────────────────────
info "署名を検証中…"
if codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
    ok "署名検証: OK"
else
    warn "署名検証に失敗しました（ad-hoc のため警告扱い）"
fi

# entitlements が埋め込まれているか確認
if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q "com.apple.security.device.camera"; then
    ok "カメラ entitlement: 確認済"
else
    warn "カメラ entitlement が見つかりません — entitlements.plist を確認してください"
fi

# ── Quarantine 解除 ─────────────────────────────────────────────
xattr -cr "$APP_PATH" 2>/dev/null && ok "quarantine 解除済"

# ── アプリサイズ確認 ────────────────────────────────────────────
SIZE=$(du -sh "$APP_PATH" 2>/dev/null | cut -f1)
info ".app サイズ: $SIZE"

# ── カメラ権限の案内 ────────────────────────────────────────────
#
#   macOS 14+ では tccutil reset がユーザー権限で実行できないため
#   システム設定を直接開いて手動許可を案内する
#
info "カメラ権限を確認中…"
if ! osascript -e 'tell application "System Events" to get name of every process' \
    2>/dev/null | grep -q "CaptureSession"; then
    warn "初回起動時: カメラ許可ダイアログが表示されます"
    warn "ダイアログが出ない場合はシステム設定から手動で許可してください"
    print "  → システム設定を開く:"
    print "    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera'"
fi

# ── 完了 ────────────────────────────────────────────────────────
print ""
print "================================================"
print "  ビルド完了"
print "  場所: $SCRIPT_DIR/$APP_PATH"
print ""
print "  起動方法:"
print "    open $APP_PATH"
print ""
print "  Applications へコピー:"
print "    sudo rm -rf /Applications/$APP_NAME.app"
print "    ditto $APP_PATH /Applications/$APP_NAME.app"
print ""
print "  カメラ権限（初回・コピー後）:"
print "    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera'"
print "================================================"

# Finder で開く
open "$DIST_DIR"
