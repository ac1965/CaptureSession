# AGENTS.md

CaptureSession（HDMIキャプチャ映像から連番スナップショットを取得するmacOSアプリ）を、Python/tkinter から Swift に移行する作業の指針です。

## 設計の正本

- [CaptureSession Swift版 設計案](https://claude.ai/code/artifact/b076ba41-d466-4b53-8921-331319e3abcc)（2026-10-10 作成）
- 実装・レビューの前に必ず読むこと。このファイルと設計案が食い違う場合は、設計案を優先する。
- リンク先が開けない場合（共有設定が必要）は、作業を止めて作成者に確認する。推測で補わない。
- 現行のPython実装（`capture_session_gui.py`）は、仕様の参照元だった。色味の確認が済んだ2026-10-10に削除した（GitHub の main に残っている）。

## 設計案の要点

- **置き換え**
  - ffmpeg → AVFoundation（`AVCaptureSession` と `AVCaptureVideoDataOutput`）
  - pyobjc での権限要求 → `AVCaptureDevice.authorizationStatus(for:)` と `requestAccess(for:)`
  - py2app + ad-hoc署名 → Xcodeプロジェクト + ad-hoc署名（Developer ID署名と公証は行わない。無料のDeveloper Programのため。2026-10-10 決定）
- **構成**：画面 → `SessionStore` → `CaptureService` / `DeviceAccess` / `SessionWriter` / `SettingsStore`
  - 画面は `SessionStore` だけを呼ぶ。
  - `SessionStore` は AVFoundation にもファイルにも依存しない純粋なSwiftにする。
- **現行との互換を保つもの**
  - 出力先：`session_YYYYMMDD_HHMMSS/capture` と `log`
  - ファイル名：`0001_YYYYMMDD_HHMMSS.png`、スキップは `0003_SKIPPED.txt`
  - ログ書式：`日時 [INFO/WARN/ERROR] 内容`（`log/capture.log`）
  - キーの既定値：キャプチャ=Space、再撮り=r、スキップ=s
- **状態管理**
  - 状態は `entries: [Entry]`（キャプチャまたはスキップ）の1本だけで持つ。別のカウンタは持たない。
  - 再撮りできるのは、末尾のエントリがキャプチャのときだけ。
  - 次の連番は「末尾の連番 + 1」で求める。
  - 現行コードは、スキップの直後に再撮りすると連番が崩れる（設計案「状態管理の設計」の4手順）。この4手順をそのままテストケースにする。
- **権限・配布**
  - Info.plist に `NSCameraUsageDescription`、entitlement に `com.apple.security.device.camera` が必要。どちらも、使い始める前に設定されていること。
  - マイクの entitlement は付けない案。ただし実機での確認が必要。
  - Hardened Runtime は有効（ad-hoc署名）。Developer ID署名と公証は、有料のDeveloper Program に加入するまで行わない。

## 未確認事項（推測で実装しない）

設計案の「未確認事項と検証計画」に記載の6点。実機で確かめるまで、結論を決め打ちしない。

1. HDMIキャプチャ機器が出す解像度・fps・ピクセル形式（`device.formats` を列挙して確認）
2. PNGの色味がffmpeg版と一致するか（同じ入力で画素値を比較）
3. QuickTime収録中に、同じ機器からフレームを取得できるか
4. `AVCapturePhotoOutput` が外部機器で使えるか（確認できる情報なし。まずは `AVCaptureVideoDataOutput` のフレームから作る）
5. ~~QuickTime連携（osascript）に必要な権限~~ → 2026-10-10 に連携の廃止を決定。対象外
6. 対応OSの下限（現行はmacOS 13以降。`.external` は macOS 14.0以降）

## 作業ルール

- 確認できない事項は、推測で埋めず、TODO として明記する。
- 実機で確かめた結果は、PRまたはコミットメッセージに記録する。
- 設計案から外れる変更をする場合は、先に設計案を更新するか、作成者に確認する。

## 進捗（2026-10-10）

- 実装済み：`CaptureCore`（状態管理・出力・設定。テストあり）、AVFoundation版 `CaptureService`、SwiftUI画面、`CaptureSession.xcodeproj`（画面とAVFoundation部分は `App/`）、`scripts/build_app.sh`（xcodebuild でビルド、ad-hoc署名）。
- 削除済み：`build_app.sh`、`setup_app.py`（`scripts/build_app.sh` と `Package.swift` に置き換え）。
- QuickTime連携（F14）は廃止（2026-10-10 決定。設計案も更新済み）。Swift版は自前のライブプレビューで代替する。
- `capture_session_gui.py`：削除済み（2026-10-10）。
- 構成：コア部分（`CaptureCore`、`CaptureObjC`、テスト）は Swift Package、アプリ本体は Xcodeプロジェクト（ローカルパッケージとして参照）。Developer ID署名と公証はスキップ（無料のDeveloper Programのため）。他のMacへ渡すと、受け取った側で初回だけ「右クリック → 開く」か `xattr -cr` が要る。
- 実機で確認した結果（2026-10-10、I-O DATA GV-HUVC 4KV、macOS 27.0.1）：
  - 未確認事項1：機器は `.external`（macOS 14以降の経路）の `DiscoverySession` で検出できた。macOS 13 の `.externalUnknown` 経路は未検証。形式は 640x480 から 3840x2160 まで複数（yuvs / 420v）。fps は 30.00003 や 60.00024 のような半端な値で返る。この値をそのまま設定しないと、`activeVideoMinFrameDuration` が例外で落ちる。
  - 未確認事項2：PNGの色味は、ffmpeg版と見比べて問題なしと判断した。画素値の数値比較は行っていない。
  - 未確認事項3：アプリ起動中（AVCaptureSession 稼働中）に、別プロセスのffmpegが同じ機器から取得できた。QuickTime収録中の挙動は未確認だが、連携を廃止したため優先度は低い。
  - 未確認事項4：`AVCapturePhotoOutput` は試していない。`AVCaptureVideoDataOutput` のフレームから作る方式で動いている。
  - 未確認事項5：QuickTime連携の廃止により対象外。
  - 未確認事項6：対応OSの下限は未決定（macOS 13 を暫定）。実機は macOS 27.0.1 のみ。
  - 未確認事項のうちマイクの entitlement：付けない構成で動作した。

## コミットルール

- 動作を確認してからコミットする（`swift test` と `zsh scripts/build_app.sh` が通ること）。
- 公開済みのコミットを書き換えない。`--no-verify` を使わない。
- 鍵・証明書・個人情報をコミットしない。

### コミットメッセージ規約

- 日本語で記述する
- 1行目は Conventional Commits 風に `type(scope): 要約` の形式にする
  - 例:
    - `feat(scripts): rbac_audit.py にトークン昇格チェーン検出を追加`
    - `fix(kind): calico rollout の CRD 競合状態を修正`
    - `docs(agents): 攻撃チェーン検出の設計方針を追記`
    - `chore(gitignore): __pycache__ を除外`
  - `type` は `feat`（機能追加）/ `fix`（不具合修正）/ `docs`（ドキュメント）/
    `chore`（雑務・設定変更）/ `refactor`（挙動を変えないコード整理）などから選ぶ
  - `scope` はディレクトリ名や機能名を使う（例は上記だが、実際のリポジトリの
    構成に合わせて選ぶ: `core`, `app`, `scripts`, `tests` など）
- 本文（任意）は `- ` の箇条書きで変更点を列挙する。詳細な経緯や検証結果を
  書く場合もこの形式に合わせる
- 破壊的変更や既存のデータ形式・証跡フォーマットに影響する変更は、本文の
  箇条書きにその旨を明記する
