# CaptureSession

HDMI キャプチャデバイスからスナップショットを順番に取得するための macOS GUI アプリ。  
Python / tkinter 1ファイル実装。`ffmpeg` (AVFoundation) でフレームを取得し、セッション単位で PNG を管理する。



## 機能

- AVFoundation 対応デバイスの自動検出（`ffmpeg -list_devices`）
- 1クリック / キーボードショートカットでフレームキャプチャ
- 再撮り（直前の PNG を破棄して連番を戻す）/ スキップ（プレースホルダー `.txt` を生成）
- セッションごとに `session_YYYYMMDD_HHMMSS/capture/` へ連番 PNG を保存
- リアルタイムプレビューウィンドウ（1 秒ごとに自動更新）
- 予定枚数に対する進捗バー
- セッションログ（`session_*/log/capture.log`）
- キーバインドのカスタマイズと永続化（`~/.capture_session_keys.json`）
- macOS TCC カメラ権限の自動要求（pyobjc 経由）



## 動作環境

| 要件 | バージョン |
|---|---|
| macOS | 13 Ventura 以降推奨（14 Sonoma / 15 Sequoia 確認済） |
| Python | 3.9 以上 |
| ffmpeg | 7.x / 8.x（AVFoundation 対応ビルド） |
| tkinter | macOS 付属 Python に含まれる、または `python-tk` |



## セットアップ

### 1. 前提ツールのインストール（Homebrew）

```zsh
# Homebrew 未導入の場合
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Python と ffmpeg
brew install python ffmpeg

# tkinter が使えない場合（エラーが出る場合のみ）
brew install python-tk
```

### 2. リポジトリのクローン

```zsh
git clone https://github.com/<your-username>/capture-session.git
cd capture-session
```

### 3. スクリプトとして直接実行する場合

```zsh
python3 capture_session_gui.py
```

> **注意**: この実行方法ではカメラ権限ダイアログが表示されない場合があります。  
> `.app` バンドルでの実行を推奨します。



## .app ビルド（推奨）

`build_app.sh` が依存関係の確認・venv 作成・py2app ビルド・コード署名をすべて自動実行します。

```zsh
zsh build_app.sh
```

ビルドが成功すると `dist/CaptureSession.app` が生成され、Finder が自動で開きます。

### ビルドの流れ（参考）

| ステップ | 内容 |
|---|---|
| 前提チェック | python3 / tkinter / ffmpeg の確認 |
| `entitlements.plist` 生成 | カメラ・マイクのエンタイトルメントを自動作成 |
| venv 作成 | `.venv_build/` に分離環境を構築 |
| py2app・pyobjc インストール | venv 内に必要パッケージを追加 |
| py2app ビルド | `setup_app.py` を使って `.app` を生成 |
| コード署名 | ad-hoc 署名 + エンタイトルメント付与 |
| Quarantine 解除 | `xattr -cr` で Gatekeeper 警告を抑制 |

### Applications フォルダへのコピー

```zsh
cp -r dist/CaptureSession.app /Applications/
```

### カメラ権限の付与

初回起動時に権限ダイアログが表示されます。ダイアログが出ない場合は手動で設定してください。

```zsh
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera'
```

システム設定 → **プライバシーとセキュリティ** → **カメラ** で **CaptureSession** を許可します。



## 使い方

1. アプリを起動し「**デバイス一覧を更新**」をクリックしてキャプチャデバイスを選択する
2. 解像度・ピクセル形式・フレームレート・出力先フォルダ・予定枚数を設定する
3. 「**▶ セッション開始**」をクリックする
4. キーボードショートカット（または各ボタン）で操作する

| 操作 | デフォルトキー | 説明 |
|---|---|---|
| キャプチャ | `Space` | 現在フレームを PNG 保存 |
| 再撮り | `r` | 直前の PNG を削除して連番を戻す |
| スキップ | `s` | 空コマを記録してプレースホルダーを生成 |

キーは「**⌨ キー設定…**」ダイアログから変更できます（`~/.capture_session_keys.json` に保存）。

### 出力ディレクトリ構造

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



## ファイル構成

```
.
├── capture_session_gui.py   # メインスクリプト（GUI + ロジック 1ファイル）
├── setup_app.py             # py2app ビルド設定
├── build_app.sh             # ビルド自動化スクリプト
└── entitlements.plist       # ビルド時に自動生成（カメラ権限エンタイトルメント）
```



## トラブルシューティング

**ffmpeg が見つからないと表示される**  
`brew install ffmpeg` を実行後、アプリを再起動してください。

**カメラ権限ダイアログが表示されない**  
`.app` バンドルから起動しているか確認し、システム設定から手動で権限を付与してください。

**デバイスが検出されない**  
HDMI キャプチャデバイスが接続されているか確認してください。`ffmpeg -f avfoundation -list_devices true -i ""` を Terminal で実行するとデバイス一覧を確認できます。

**ビルドエラー: `tkinter` が使えない**  
`brew install python-tk` を実行してから `zsh build_app.sh` を再実行してください。



## ライセンス

MIT
