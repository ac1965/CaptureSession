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
| tkinter | macOS 付属、または `brew install python-tk` |

---

## セットアップ

```zsh
# 前提ツールのインストール
brew install python ffmpeg

# tkinter が使えない場合のみ
brew install python-tk
```

---

## ビルドと起動

`build_app.sh` が依存関係の確認・venv 構築・py2app ビルド・ad-hoc コード署名をすべて自動実行する。

```zsh
cd ~/Projects/CaptureSession
zsh build_app.sh

# Applications へコピー（ditto を使うこと。cp -r は不可）
sudo rm -rf /Applications/CaptureSession.app
ditto dist/CaptureSession.app /Applications/CaptureSession.app

open /Applications/CaptureSession.app
```

> **直接実行（デバッグ用）**  
> `python3 capture_session_gui.py` でも起動できるが、この方法ではカメラ権限ダイアログが表示されない。`.app` バンドルからの起動を推奨。

### ビルドステップ

| ステップ | 内容 |
|---|---|
| 前提チェック | python3 / tkinter / ffmpeg の確認 |
| `entitlements.plist` 自動生成 | カメラ・マイクのエンタイトルメントを作成 |
| `.venv_build/` 作成 | py2app・pyobjc をシステムと分離してインストール |
| py2app ビルド | `setup_app.py` を使って `.app` を生成 |
| ad-hoc コード署名 | entitlements 付きで署名（Apple Developer 証明書不要） |
| Quarantine 解除 | `xattr -cr` で Gatekeeper 警告を抑制 |

### カメラ権限

初回起動時に許可ダイアログが表示される。表示されない場合は手動で付与する。

```zsh
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera'
```

システム設定 → **プライバシーとセキュリティ** → **カメラ** で CaptureSession をオンにする。

---

## 使い方

### 基本フロー

1. アプリを起動する（デバイス一覧は自動取得される）
2. 取得されない場合は「**🔄 デバイス一覧を更新**」をクリックしてデバイスを選択する
3. 解像度・ピクセル形式・フレームレート・出力先・予定枚数を設定する
4. 「**▶ セッション開始**」をクリックする
5. キーボードショートカット（またはボタン）で操作する

### キャプチャ操作

| 操作 | デフォルトキー | 内容 |
|---|---|---|
| キャプチャ | `Space` | 現在フレームを PNG 保存 |
| 再撮り | `r` | 直前の PNG を削除して連番を戻す |
| スキップ | `s` | 連番を消費してプレースホルダー `.txt` を生成 |

キーは「**⌨ キー設定…**」から変更できる（`~/.capture_session_keys.json` に保存）。

### コントローラウィンドウ

「**🎮 Controller を開く**」でコンパクトなサブウィンドウを起動する。  
メインウィンドウは自動で非表示になり、コントローラだけで操作できる。

コントローラには以下が含まれる：

- セッション開始 / 終了
- 直前キャプチャ画像のプレビュー（再撮り判断用）
- 進捗バー
- キャプチャ・再撮り・スキップボタン（キーバインドも有効）
- ステータス表示
- 「最前面に固定」トグル（チェックを外すと他のウィンドウの後ろに回せる）

コントローラを閉じるとメインウィンドウが復元される。

### QuickTime 連携

「**📺 QuickTime で確認**」でリアルタイム映像を確認しながらキャプチャできる。  
ボタンを押すと QuickTime Player がムービー収録モードで起動する。  
デバイスの選択は QuickTime 側で行う。

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

## トラブルシューティング

**デバイスが検出されない**  
ターミナルで以下を実行してデバイスが表示されるか確認する。

```zsh
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "video devices"
```

表示される場合はアプリのカメラ権限が未許可の可能性がある。上記「カメラ権限」の手順を参照。

**デバイスが意図しないカメラに切り替わる**  
「デバイス一覧を更新」後に目的のデバイスを選択し直す。アプリ起動直後の自動取得では選択状態が維持されるが、手動で確認することを推奨。

**ビルドエラー: `externally-managed-environment`**  
システム Python への直接インストールを防ぐエラー。`build_app.sh` が `.venv_build/` を自動作成するため、スクリプト経由でビルドすること。

**ビルドエラー: `tkinter` が使えない**  
`brew install python-tk` を実行してから再ビルドする。

**`cp -r` でコピーするとシンボリックリンクエラーが出る**  
`.app` バンドルのコピーは必ず `ditto` を使う。

```zsh
sudo rm -rf /Applications/CaptureSession.app
ditto dist/CaptureSession.app /Applications/CaptureSession.app
```

---

## ライセンス

MIT
