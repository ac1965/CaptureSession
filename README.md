# CaptureSession

HDMI キャプチャデバイスからスナップショットを順番に取得する macOS GUI アプリ。  
Python / tkinter 1ファイル実装。`ffmpeg`（AVFoundation）でフレームを取得し、セッション単位で PNG を連番管理する。

---

## 動作環境

| 要件 | バージョン |
|---|---|
| macOS | 13 Ventura 以降（14 Sonoma / 15 Sequoia 確認済） |
| Python | 3.9 以上 |
| ffmpeg | 7.x / 8.x（AVFoundation 対応ビルド） |
| tkinter | macOS 付属、または `brew install python-tk@3.11` |

---

## セットアップ

```zsh
brew install python ffmpeg
# tkinter が使えない場合のみ
brew install python-tk@3.11
```

---

## ビルドと起動

```zsh
cd ~/Projects/CaptureSession
zsh build_app.sh

# Applications へコピー（ditto を使うこと。cp -r は不可）
sudo rm -rf /Applications/CaptureSession.app
ditto dist/CaptureSession.app /Applications/CaptureSession.app
open /Applications/CaptureSession.app
```

> **直接実行（デバッグ用）**  
> `python3 capture_session_gui.py` でも起動できるが、この方法ではカメラ権限ダイアログが表示されない。

### ビルドステップ（build_app.sh）

| ステップ | 内容 |
|---|---|
| 前提チェック | python3 / tkinter / ffmpeg の確認 |
| `entitlements.plist` 自動生成 | カメラ・マイクのエンタイトルメントを作成（なければ） |
| `.venv_build/` 作成 | py2app・pyobjc をシステムと分離してインストール |
| py2app ビルド | `setup_app.py` を使って `.app` を生成 |
| ad-hoc コード署名 | entitlements 付きで署名（Apple Developer 証明書不要） |
| Quarantine 解除 | `xattr -cr` で Gatekeeper 警告を抑制 |

### カメラ権限

初回起動時に許可ダイアログが表示される。表示されない場合は手動で付与する。

```zsh
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera'
```

---

## 使い方

### 基本フロー

1. アプリを起動（デバイス一覧は自動取得）
2. 取得されない場合は「🔄 デバイス一覧を更新」でデバイスを選択
3. 解像度・ピクセル形式・フレームレート・出力先・予定枚数を設定
4. 「▶ セッション開始」をクリック
5. キーボードショートカットまたはボタンで操作

### キャプチャ操作

| 操作 | デフォルトキー | 内容 |
|---|---|---|
| キャプチャ | `Space` | 現在フレームを PNG 保存 |
| 再撮り | `r` | 直前の PNG を削除して連番を戻す |
| スキップ | `s` | 連番を消費してプレースホルダー `.txt` を生成 |

キーは「⌨ キー設定…」から変更できる（`~/.capture_session_keys.json` に保存）。

### コントローラウィンドウ

「🎮 Controller を開く」でコンパクトなサブウィンドウを起動する。  
メインウィンドウは自動で非表示になり、コントローラだけで操作できる。

| 要素 | 内容 |
|---|---|
| ▶ 開始 / ■ 終了 | セッション制御（メインと状態同期） |
| 📺 QT 起動/前面 / ⏹ QT 録画停止 | QuickTime の起動・前面表示・録画強制停止 |
| 最前面に固定 / 透明度スライダー | 最前面固定トグルと 0.2〜1.0 の透明度調整 |
| 📷 キャプチャ | 操作ボタン（キーバインドも有効） |
| 画像プレビュー | 直前キャプチャの PNG（再撮り判断用） |
| ↩ 再撮り / ⏭ スキップ | 操作ボタン（キーバインドも有効） |
| 進捗バー | メインと同期 |
| ステータス | メインと共有 |

コントローラを閉じるとメインウィンドウが復元される。

### QuickTime 連携

「**📺 QuickTime で確認**」でリアルタイム映像を確認しながらキャプチャできる。

| ボタン | 動作 |
|---|---|
| 📺 QuickTime で確認（メイン） | 起動、または既存ウィンドウを前面に表示 |
| 📺 QT 起動/前面（コントローラ） | 同上。収録ウィンドウが既にあれば前面に出すだけ |
| ⏹ QT 録画停止（コントローラ） | 全ての収録ドキュメントの録画を強制停止 |

録画を誤って停止しても QuickTime を閉じる必要はない。「⏹ QT 録画停止」で停止後、QuickTime 側で録画を再開できる。デバイスの選択は QuickTime 側で行う。

---

## 出力ディレクトリ構造

```
~/capture_session/
└── session_20250603_143022/
    ├── capture/
    │   ├── 0001_20250603_143025.png
    │   ├── 0002_20250603_143030.png
    │   ├── 0003_SKIPPED.txt
    │   └── ...
    └── log/
        └── capture.log
```

ファイル名の先頭4桁が連番。PNG とスキップで連番を共有するため抜け番がない。

---

## ファイル構成

```
.
├── capture_session_gui.py   # メインスクリプト（GUI + ロジック 1ファイル）
├── setup_app.py             # py2app ビルド設定
├── build_app.sh             # ビルド自動化スクリプト
└── entitlements.plist       # ビルド時に自動生成（カメラ権限エンタイトルメント）
```

---

## ロジックフロー

### 起動シーケンス

```
App.__init__()
  ├─ find_ffmpeg()              # 候補パスを順番に探索
  ├─ _load_keys()               # ~/.capture_session_keys.json を読み込み
  ├─ _build_ui()                # メインウィンドウ・ウィジェットを構築
  ├─ _apply_keybinds()          # キーバインドを登録
  └─ after(500ms)
       └─ _request_camera_permission_async()   # TCC 権限要求（スレッド）
            └─ [granted] → _refresh_devices_async()  # デバイス一覧を自動取得
```

### デバイス取得フロー

```
_refresh_devices()
  └─ _refresh_devices_async()
       └─ Thread: list_avfoundation_devices()
            └─ ffmpeg -f avfoundation -list_devices true -i ""
                 └─ stderr をパース（ffmpeg 7.x / 8.x 両対応）
       └─ after(0): _refresh_devices_done(raw)
            ├─ ERR エントリ → ステータスバーに表示
            ├─ 選択済みデバイスを維持（再取得時に選択がリセットされない）
            └─ 初回 or 消失時のみ [0] にフォールバック
```

### キャプチャフロー

```
_do_capture()
  ├─ session_active / _capture_in_flight チェック（二重発火防止）
  ├─ 連番 (_seq) を払い出し → ファイルパスを確定
  ├─ メインスレッドで tkinter 変数を取得（スレッド安全）
  └─ Thread: capture_frame()
       └─ ffmpeg -f avfoundation -i {device}:none -frames:v 1 output.png
  └─ after(0): _capture_done(seq_str, out, err)
       ├─ 失敗 → _seq を戻す、ログに ERROR
       └─ 成功 → png_count++、サムネイル追加、コントローラプレビュー更新
```

### 再撮り / スキップフロー

```
_do_retake()
  ├─ last_png_path の PNG を削除
  ├─ png_count-- / _seq--（連番を再利用）
  └─ コントローラプレビューをクリア

_do_skip()
  ├─ _seq++ / skip_count++
  ├─ {seq}_SKIPPED.txt を生成
  └─ サムネイルにスキップカードを追加
```

### コントローラウィンドウ同期

```
_sync_ctrl_win()   # セッション状態変化・進捗更新のたびに呼ばれる
  ├─ セッション開始/終了ボタンの state を同期
  ├─ キャプチャ/再撮り/スキップボタンの state と text を同期
  └─ 進捗バー・進捗ラベルを同期

_ctrl_update_preview(path, seq)   # キャプチャ成功・再撮り・セッション開始時
  └─ PhotoImage をロードして subsample（_subsample_for ヘルパー使用）
```

---

## 主要関数・メソッド一覧

### モジュールレベル関数

| 関数 | 説明 |
|---|---|
| `_subsample_for(img_w, img_h, max_w, max_h)` | PhotoImage の縮小倍率を計算（ceil 除算）。`_load_thumbnail` と `_ctrl_update_preview` で共用 |
| `find_ffmpeg()` | 候補パスと `shutil.which` で ffmpeg を探索 |
| `request_camera_permission()` | pyobjc 経由で AVCaptureDevice.requestAccessForMediaType_ を呼び出し TCC に登録。pyobjc 未使用環境では即 True を返す |
| `list_avfoundation_devices()` | ffmpeg stderr をパースして `[(index, label), ...]` を返す。ERR タプルでエラーを通知 |
| `capture_frame(...)` | ffmpeg で1フレームを PNG 保存。stderr が空文字なら成功 |

### App クラス — 初期化・UI

| メソッド | 説明 |
|---|---|
| `__init__` | 状態変数・tkinter 変数・UI を初期化。カメラ権限要求を 500ms 後にスケジュール |
| `_build_ui` | PanedWindow（左:設定、右:サムネイル+ログ）とステータスバーを構築 |
| `_build_left` | デバイス選択・キャプチャ設定・出力先・セッション制御・キャプチャ操作パネルを構築 |
| `_build_right` | サムネイルキャンバス（スクロール付き）とログパネルを構築 |

### App クラス — キーバインド

| メソッド | 説明 |
|---|---|
| `_apply_keybinds` | 古いバインドを解除して `self._keys` に従い再登録。大文字も自動バインド |
| `_tk_key(key)` | キー名を tkinter イベント文字列に変換（`"space"` → `"<space>"` 等） |
| `_update_btn_labels` | ボタンラベルのショートカット表示を更新しコントローラに同期 |
| `_load_keys / _save_keys` | `~/.capture_session_keys.json` との読み書き |
| `_open_keybind_dialog` | キーバインド設定ダイアログを表示。重複チェック付き |

### App クラス — デバイス・権限

| メソッド | 説明 |
|---|---|
| `_refresh_devices` | ボタン押下のエントリ。status 更新後に `_refresh_devices_async` を呼ぶ |
| `_refresh_devices_async` | バックグラウンドで `list_avfoundation_devices` を実行 |
| `_refresh_devices_done` | 選択済みデバイスを維持しながら Combobox を更新 |
| `_request_camera_permission_async` | pyobjc でカメラ権限を要求。デバイス未取得時のみ自動取得を起動 |
| `_warn_camera_permission` | 権限拒否時の警告ダイアログとシステム設定への誘導 |

### App クラス — セッション制御

| メソッド | 説明 |
|---|---|
| `_start_session` | ディレクトリ作成・カウンタリセット・ログファイルオープン・UI 更新 |
| `_end_session` | ログクローズ・UI 更新 |
| `_set_session_ui(active)` | 全ボタンの有効/無効を切り替えコントローラに同期 |
| `_on_close` | コントローラを閉じ、セッション終了処理後に `destroy` |
| `_close_log` | ログファイルを安全にクローズ |

### App クラス — QuickTime 連携

| メソッド | 説明 |
|---|---|
| `_open_quicktime` | QuickTime をムービー収録モードで起動。収録ウィンドウが既にあれば前面に出すだけ |
| `_stop_quicktime_recording` | 全ムービー収録ドキュメントの録画を osascript で強制停止 |

### App クラス — キャプチャ操作

| メソッド | 説明 |
|---|---|
| `_do_capture` | 二重発火防止・連番払い出し・バックグラウンドで ffmpeg 実行 |
| `_capture_done` | 結果を受け取りサムネイル追加・コントローラ同期・ボタン復帰 |
| `_do_retake` | 直前 PNG を削除し連番を戻す |
| `_do_skip` | プレースホルダー `.txt` を生成し連番を消費 |
| `_update_progress` | 進捗バー・ラベルを更新しコントローラに同期 |

### App クラス — コントローラウィンドウ

| メソッド | 説明 |
|---|---|
| `_toggle_ctrl_win` | コントローラの開閉を切り替え |
| `_open_ctrl_win` | サブウィンドウを構築しメインを非表示にする |
| `_close_ctrl_win` | サブウィンドウを破棄しメインを復元する |
| `_toggle_topmost` | `-topmost` 属性を切り替え |
| `_on_alpha_change` | スライダー値を `-alpha` 属性に即時反映 |
| `_apply_ctrl_win_keybinds` | コントローラウィンドウにキーバインドを適用 |
| `_sync_ctrl_win` | ボタン状態・進捗をコントローラに同期 |
| `_ctrl_update_preview` | 直前キャプチャ画像をコントローラプレビューに表示 |

### App クラス — サムネイル・ログ

| メソッド | 説明 |
|---|---|
| `_add_thumbnail` | キャプチャ/スキップカードをグリッドに追加しスクロールを末尾に移動 |
| `_load_thumbnail` | `_subsample_for` で枠に収まる倍率を計算して縮小 |
| `_remove_last_thumbnail` | 直前のカードを削除（再撮り時） |
| `_append_log` | タイムスタンプ付きでログウィジェットとファイルに書き込み |

---

## トラブルシューティング

**デバイスが検出されない**

```zsh
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "video devices"
```

表示される場合はカメラ権限が未許可の可能性がある。

**デバイスが意図しないカメラに切り替わる**  
「デバイス一覧を更新」後に目的のデバイスを選択し直す。

**`cp -r` でコピーするとシンボリックリンクエラーが出る**  
`.app` バンドルのコピーは必ず `ditto` を使う。

```zsh
sudo rm -rf /Applications/CaptureSession.app
ditto dist/CaptureSession.app /Applications/CaptureSession.app
```

**ビルドエラー: `externally-managed-environment`**  
`build_app.sh` が `.venv_build/` を自動作成するため、スクリプト経由でビルドすること。

**ビルドエラー: `tkinter` が使えない**  
`brew install python-tk@3.11` を実行してから再ビルドする。

---

## ChangeLog

### v1.0 — 初期実装（2026-05）
- Python / tkinter 1ファイル GUI として実装
- SwiftUI 案から Python + tkinter に切り替え（インストール・配布の簡便さを優先）
- `ffmpeg -f avfoundation` でフレーム取得
- キャプチャ・再撮り・スキップの基本操作
- セッション単位で `session_YYYYMMDD_HHMMSS/capture/` に連番 PNG を保存
- `build_app.sh` で py2app ビルドを自動化

### v1.1 — バグ修正（2026-06-04 前半）
- **FIX #1**: `_do_retake` の連番重複バグを修正。`_seq`・`png_count`・`skip_count` を完全に独立管理
- **FIX #2**: `_do_skip` のカウント設計を整理。進捗計算を `png_count / expected` に統一
- **FIX #3**: `_append_log` の `level` 引数が無視されていたバグを修正
- **FIX #4**: `_load_thumbnail` のアスペクト比計算を ceil 除算に修正
- **FIX #5**: `_capture_in_flight` フラグを追加してキャプチャとセッション終了の競合を防止
- **FIX #6**: `WM_DELETE_WINDOW` フックを追加してログファイルを確実にクローズ

### v1.2 — .app 署名・権限対応（2026-06-04 中盤）
- `build_app.sh` に venv 対応を追加（`--break-system-packages` 問題の解消）
- `entitlements.plist` の自動生成と ad-hoc コード署名ステップを追加
- ffmpeg 8.x の `[AVFoundation indev @ 0x...]` プレフィックスに対応した正規表現修正
- pyobjc 経由の `AVCaptureDevice.requestAccessForMediaType_` でカメラ権限を Python 側から要求
- `subprocess.run` に `encoding="utf-8", errors="replace"` を追加（日本語デバイス名のデコードエラー解消）
- デバイス取得を `_refresh_devices_async` でバックグラウンド化（メインスレッドブロック解消）
- `_refresh_devices_done` で選択済みデバイスを維持（再取得時のリセット防止）
- `_request_camera_permission_async` の自動取得をデバイス未取得時のみに制限

### v1.3 — キーバインドカスタマイズ（2026-06-04 後半）
- キャプチャキーを `Enter` → `Space` に変更
- `~/.capture_session_keys.json` にキーバインドを永続化する設定ダイアログを追加
- `_apply_keybinds` で古いバインドを解除してから再設定する方式に変更

### v1.4 — QuickTime 連携・デバイス切り替えバグ修正（2026-06-05）
- プレビュー機能（1秒ポーリング）を削除し QuickTime Player 連携に切り替え
- `_open_quicktime`: osascript の `-e` を1行ずつ渡す形式に修正
- デバイスが交互にキャプチャされるバグを修正（`_refresh_devices_done` が常に `[0]` にリセットしていた）
- `.app` コピーを `cp -r` から `ditto` に変更（シンボリックリンク問題の解消）

### v1.5 — コントローラウィンドウ（2026-06-05）
- 「🎮 Controller を開く」でコンパクトなサブウィンドウを起動
- コントローラ表示中はメインウィンドウを非表示
- コントローラにセッション開始/終了、直前キャプチャプレビュー、進捗バーを追加
- `-topmost` 属性による最前面固定トグルを追加
- `-alpha` 属性によるウィンドウ透明度スライダーを追加（0.2〜1.0）
- `_sync_ctrl_win` でボタン状態・進捗をメインと同期

### v1.6 — コード効率化（2026-06-05）
- `_bind_keys` ラッパーを廃止し `_apply_keybinds` を直接呼び出し
- `_refresh_devices_async` 冒頭の重複 `status.set` / `update_idletasks` を除去
- `_on_close` にコントローラウィンドウのクローズ処理を追加
- `_open_quicktime` 内のコントローラセクションコメントのインデントバグを修正
- `_warn_camera_permission` 内の二重 `import subprocess` を除去
- `_subsample_for` ヘルパーを追加し `_load_thumbnail` と `_ctrl_update_preview` の重複計算を統一
- `_do_capture` でスレッド起動前に tkinter 変数をローカルに束縛（スレッド安全性の向上）

### v1.7 — QuickTime 連携強化（2026-06-05）
- `_open_quicktime`: 収録ウィンドウが既に存在する場合は前面に出すだけに変更（重複起動を防止）
- `_stop_quicktime_recording` を追加。osascript で全ムービー収録ドキュメントの録画を強制停止
- コントローラに「📺 QT 起動/前面」「⏹ QT 録画停止」ボタンを追加

---

## ライセンス

MIT
