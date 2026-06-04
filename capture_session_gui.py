#!/usr/bin/env python3
"""
capture_session_gui.py
HDMI キャプチャセッション GUI — Python / tkinter 1ファイル実装
macOS (avfoundation + ffmpeg) 専用

依存: Python 3.9+, tkinter (macOS 付属), ffmpeg (brew install ffmpeg)

使い方:
  python3 capture_session_gui.py

.app 化:
  pip3 install py2app
  python3 setup_app.py py2app
"""

import tkinter as tk
from tkinter import ttk, filedialog, messagebox, scrolledtext
import subprocess
import threading
import os
import shutil
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Optional

# ── 定数 ─────────────────────────────────────────────────────────
APP_TITLE   = "Capture Session"
FFMPEG_CANDIDATES = [
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/usr/bin/ffmpeg",
]
RESOLUTIONS   = ["1920x1080", "1280x720", "3840x2160"]
PIXEL_FORMATS = ["uyvy422", "nv12", "yuv420p"]
FRAMERATES    = [30, 25, 60, 15]
THUMB_W, THUMB_H = 160, 90   # サムネイルサイズ (px)
PREVIEW_INTERVAL_MS = 1000   # プレビュー更新間隔 (ms)
PREVIEW_TMPFILE     = "/tmp/capture_session_preview.png"  # プレビュー用一時ファイル

# ── キーバインドのデフォルト値と設定ファイルパス ─────────────────
KEYBIND_FILE = Path.home() / ".capture_session_keys.json"
DEFAULT_KEYS = {
    "capture": "space",   # キャプチャ
    "retake":  "r",       # 再撮り
    "skip":    "s",       # スキップ
}

# ── ffmpeg ヘルパー ───────────────────────────────────────────────

def find_ffmpeg() -> Optional[str]:
    for p in FFMPEG_CANDIDATES:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return shutil.which("ffmpeg")


def request_camera_permission() -> bool:
    """
    AVCaptureDevice を Python から直接呼び出し、macOS TCC にカメラ要求を登録する。
    .app バンドル内の Python が要求元になるため、システム設定のカメラ一覧に表示される。
    戻り値: 許可済みなら True、拒否 / 未確定なら False
    """
    try:
        import objc
        from AVFoundation import (
            AVCaptureDevice,
            AVMediaTypeVideo,
            AVAuthorizationStatusAuthorized,
        )

        status = AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeVideo)
        if status == AVAuthorizationStatusAuthorized:
            return True

        # 未確定の場合はダイアログを表示して結果を待つ
        result = {"granted": False}
        event  = threading.Event()

        def handler(granted):
            result["granted"] = granted
            event.set()

        AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AVMediaTypeVideo, handler
        )
        event.wait(timeout=30)
        return result["granted"]

    except Exception:
        # pyobjc が使えない環境（直接 python3 実行時など）はスキップ
        return True


def list_avfoundation_devices() -> list[tuple[str, str]]:
    """[(index_or_name, label), ...] を返す"""
    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        return []
    try:
        result = subprocess.run(
            [ffmpeg, "-f", "avfoundation", "-list_devices", "true", "-i", ""],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=15
        )
        output = result.stderr  # ffmpeg はデバイス一覧を stderr に出す
        devices = []
        in_video = False
        for line in output.splitlines():
            if "AVFoundation video devices" in line:
                in_video = True
                continue
            if "AVFoundation audio devices" in line:
                break
            if in_video:
                # ffmpeg 8.x: "[AVFoundation indev @ 0x...] [0] Device Name"
                # ffmpeg 7.x: "[0] Device Name"
                # 末尾の \[(\d+)\] (.+) にマッチさせることで両バージョンに対応
                m = re.search(r'\[(\d+)\] ([^\[].+)', line)
                if m:
                    devices.append((m.group(1), m.group(2).strip()))
        return devices
    except subprocess.TimeoutExpired:
        return [("ERR", "ffmpeg タイムアウト — 再試行してください")]
    except Exception as e:
        return [("ERR", f"デバイス取得エラー: {e}")]


def capture_frame(ffmpeg: str, device_index: str, resolution: str,
                  pixel_format: str, framerate: int, output_path: str) -> str:
    """ffmpeg を呼び出して1フレームを PNG 保存。エラー時は stderr を返す"""
    input_spec = f"{device_index}:none"
    cmd = [
        ffmpeg,
        "-f", "avfoundation",
        "-pixel_format", pixel_format,
        "-framerate", str(framerate),
        "-video_size", resolution,
        "-i", input_spec,
        "-frames:v", "1",
        "-y", "-loglevel", "error",
        output_path,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=15)
    return result.stderr  # 空文字 = 成功


# ── GUI アプリ ────────────────────────────────────────────────────

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_TITLE)
        self.resizable(True, True)
        self.minsize(820, 580)

        # ── 状態変数 ──
        self.ffmpeg          = find_ffmpeg()
        self.session_active  = False
        # FIX #5: キャプチャ中フラグを別管理（セッション終了との競合防止）
        self._capture_in_flight = False
        # FIX #1/#2: PNG枚数とスキップ枚数を完全に独立管理
        #   png_count  : 実際に保存成功した PNG の枚数
        #   skip_count : スキップした枚数
        #   seq        : 次に払い出す連番（PNG + SKIP の合算; ファイル名用）
        self.png_count       = 0
        self.skip_count      = 0
        self._seq            = 0   # 次払い出し連番（1-indexed、払い出し時にインクリメント）
        self.last_png_path   : Optional[str] = None
        self.last_png_seq    : Optional[str] = None   # FIX #1: 再撮り時の連番追跡
        self.session_dir     : Optional[Path] = None
        self.capture_dir     : Optional[Path] = None
        self.log_fh          = None

        # プレビューウィンドウ関連
        self._preview_win    : Optional[tk.Toplevel] = None
        self._preview_label  : Optional[tk.Label]    = None
        self._preview_active = False
        self._preview_job    = None   # after() のジョブID
        self._preview_in_flight = False  # プレビュー取得中フラグ

        # ── tkinter 変数 ──
        self.var_device_label = tk.StringVar(value="（リスト更新してください）")
        self.var_device_index = tk.StringVar(value="")
        self.var_resolution   = tk.StringVar(value=RESOLUTIONS[0])
        self.var_pixel_format = tk.StringVar(value=PIXEL_FORMATS[0])
        self.var_framerate    = tk.IntVar(value=30)
        self.var_base_dir     = tk.StringVar(value=str(Path.home() / "capture_session"))
        self.var_expected     = tk.IntVar(value=0)
        self.var_status       = tk.StringVar(value="待機中")

        self._devices: list[tuple[str, str]] = []  # [(index, label)]

        # キーバインド（設定ファイルから読み込み、なければデフォルト）
        self._keys = self._load_keys()

        self._build_ui()
        self._bind_keys()

        # FIX #6: ウィンドウ閉じるボタンでもログを確実にクローズ
        self.protocol("WM_DELETE_WINDOW", self._on_close)

        # カメラ権限を Python 側から要求（TCC にエントリを登録するため）
        # UIが描画されてから 500ms 後に非同期で実行
        self.after(500, self._request_camera_permission_async)

        # ffmpeg チェック
        if not self.ffmpeg:
            messagebox.showwarning(
                "ffmpeg が見つかりません",
                "ffmpeg がインストールされていません。\n\nbrew install ffmpeg\n\nでインストールしてください。"
            )

    # ── UI 構築 ──────────────────────────────────────────────────

    def _build_ui(self):
        # メインフレーム: 左 (設定) + 右 (サムネイル + ログ)
        paned = ttk.PanedWindow(self, orient=tk.HORIZONTAL)
        paned.pack(fill=tk.BOTH, expand=True, padx=6, pady=6)

        left = ttk.Frame(paned, width=280)
        left.pack_propagate(False)
        paned.add(left, weight=0)

        right = ttk.Frame(paned)
        paned.add(right, weight=1)

        self._build_left(left)
        self._build_right(right)

        # ステータスバー
        bar = ttk.Frame(self, relief=tk.SUNKEN)
        bar.pack(fill=tk.X, side=tk.BOTTOM)
        ttk.Label(bar, textvariable=self.var_status,
                  anchor=tk.W, padding=(6, 2)).pack(side=tk.LEFT, fill=tk.X, expand=True)

    def _build_left(self, parent):
        # デバイス
        dev_frame = ttk.LabelFrame(parent, text="入力デバイス", padding=8)
        dev_frame.pack(fill=tk.X, padx=6, pady=(6, 4))

        self._device_combo = ttk.Combobox(
            dev_frame, textvariable=self.var_device_label,
            state="readonly", width=28
        )
        self._device_combo.pack(fill=tk.X)
        self._device_combo.bind("<<ComboboxSelected>>", self._on_device_selected)

        ttk.Button(dev_frame, text="🔄 デバイス一覧を更新",
                   command=self._refresh_devices).pack(fill=tk.X, pady=(4, 0))

        # 設定
        cfg_frame = ttk.LabelFrame(parent, text="キャプチャ設定", padding=8)
        cfg_frame.pack(fill=tk.X, padx=6, pady=4)

        for label, var, values in [
            ("解像度",       self.var_resolution,   RESOLUTIONS),
            ("ピクセル形式", self.var_pixel_format, PIXEL_FORMATS),
        ]:
            r = ttk.Frame(cfg_frame)
            r.pack(fill=tk.X, pady=2)
            ttk.Label(r, text=label, width=11, anchor=tk.W).pack(side=tk.LEFT)
            ttk.Combobox(r, textvariable=var, values=values,
                         state="readonly", width=14).pack(side=tk.LEFT)

        r = ttk.Frame(cfg_frame)
        r.pack(fill=tk.X, pady=2)
        ttk.Label(r, text="フレームレート", width=11, anchor=tk.W).pack(side=tk.LEFT)
        ttk.Combobox(r, textvariable=self.var_framerate,
                     values=FRAMERATES, state="readonly", width=6).pack(side=tk.LEFT)
        ttk.Label(r, text="fps").pack(side=tk.LEFT, padx=2)

        r = ttk.Frame(cfg_frame)
        r.pack(fill=tk.X, pady=2)
        ttk.Label(r, text="予定枚数", width=11, anchor=tk.W).pack(side=tk.LEFT)
        ttk.Spinbox(r, textvariable=self.var_expected,
                    from_=0, to=999, width=6).pack(side=tk.LEFT)
        ttk.Label(r, text="（0=無制限）", foreground="gray").pack(side=tk.LEFT, padx=2)

        # 出力先
        out_frame = ttk.LabelFrame(parent, text="出力先", padding=8)
        out_frame.pack(fill=tk.X, padx=6, pady=4)
        ttk.Label(out_frame, textvariable=self.var_base_dir,
                  wraplength=230, foreground="gray", justify=tk.LEFT).pack(fill=tk.X)
        ttk.Button(out_frame, text="📁 フォルダを選択…",
                   command=self._choose_dir).pack(fill=tk.X, pady=(4, 0))

        # セッション制御
        ctrl_frame = ttk.LabelFrame(parent, text="セッション", padding=8)
        ctrl_frame.pack(fill=tk.X, padx=6, pady=4)

        self._btn_start = ttk.Button(ctrl_frame, text="▶ セッション開始",
                                     command=self._start_session)
        self._btn_start.pack(fill=tk.X)

        self._btn_end = ttk.Button(ctrl_frame, text="■ セッション終了",
                                   command=self._end_session, state=tk.DISABLED)
        self._btn_end.pack(fill=tk.X, pady=(4, 0))

        self._btn_preview = ttk.Button(ctrl_frame, text="📺 プレビュー表示",
                                       command=self._toggle_preview)
        self._btn_preview.pack(fill=tk.X, pady=(4, 0))

        # 進捗バー
        self._progress = ttk.Progressbar(ctrl_frame, maximum=100, value=0)
        self._progress.pack(fill=tk.X, pady=(6, 0))
        self._lbl_progress = ttk.Label(ctrl_frame, text="", foreground="gray")
        self._lbl_progress.pack()

        # キャプチャボタン群
        cap_frame = ttk.LabelFrame(parent, text="キャプチャ操作  (ショートカット)", padding=8)
        cap_frame.pack(fill=tk.X, padx=6, pady=4)

        self._btn_capture = ttk.Button(cap_frame, text="📷  キャプチャ  [Space]",
                                       command=self._do_capture, state=tk.DISABLED)
        self._btn_capture.pack(fill=tk.X)

        row = ttk.Frame(cap_frame)
        row.pack(fill=tk.X, pady=(4, 0))
        self._btn_retake = ttk.Button(row, text="↩ 再撮り  [r]",
                                      command=self._do_retake, state=tk.DISABLED)
        self._btn_retake.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self._btn_skip = ttk.Button(row, text="⏭ スキップ  [s]",
                                    command=self._do_skip, state=tk.DISABLED)
        self._btn_skip.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(4, 0))

        ttk.Button(cap_frame, text="⌨ キー設定…",
                   command=self._open_keybind_dialog).pack(fill=tk.X, pady=(6, 0))

    def _build_right(self, parent):
        # サムネイルエリア (Canvas + スクロール)
        thumb_frame = ttk.LabelFrame(parent, text="キャプチャ一覧", padding=4)
        thumb_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 4))

        self._canvas = tk.Canvas(thumb_frame, background="#1e1e1e",
                                  highlightthickness=0)
        vsb = ttk.Scrollbar(thumb_frame, orient=tk.VERTICAL,
                             command=self._canvas.yview)
        self._canvas.configure(yscrollcommand=vsb.set)
        vsb.pack(side=tk.RIGHT, fill=tk.Y)
        self._canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        self._thumb_inner = tk.Frame(self._canvas, background="#1e1e1e")
        self._canvas_win = self._canvas.create_window(
            (0, 0), window=self._thumb_inner, anchor=tk.NW
        )
        self._thumb_inner.bind("<Configure>", self._on_canvas_configure)
        self._canvas.bind("<Configure>", self._on_canvas_width)

        self._thumb_refs = []   # PhotoImage の参照保持用
        self._thumb_col  = 4    # 列数（幅に応じて自動計算）

        # ログエリア
        log_frame = ttk.LabelFrame(parent, text="ログ", padding=4)
        log_frame.pack(fill=tk.X, ipady=4)

        self._log_text = scrolledtext.ScrolledText(
            log_frame, height=7, state=tk.DISABLED,
            font=("Menlo", 11), background="#0d0d0d", foreground="#c0c0c0",
            insertbackground="white", wrap=tk.NONE
        )
        self._log_text.pack(fill=tk.BOTH, expand=True)
        self._log_text.tag_config("error", foreground="#ff6b6b")
        self._log_text.tag_config("warn",  foreground="#ffa94d")
        self._log_text.tag_config("info",  foreground="#c0c0c0")

    # ── キーバインド ─────────────────────────────────────────────

    def _bind_keys(self):
        self._apply_keybinds()

    def _tk_key(self, key: str) -> str:
        """キー名を tkinter イベント文字列に変換"""
        # 1文字の印字可能文字はそのまま、特殊キーは <...> に包む
        specials = {
            "space": "<space>", "return": "<Return>", "enter": "<Return>",
            "tab": "<Tab>", "escape": "<Escape>",
            "up": "<Up>", "down": "<Down>", "left": "<Left>", "right": "<Right>",
            "f1": "<F1>", "f2": "<F2>", "f3": "<F3>", "f4": "<F4>",
            "f5": "<F5>", "f6": "<F6>", "f7": "<F7>", "f8": "<F8>",
        }
        k = key.strip().lower()
        return specials.get(k, k)

    def _apply_keybinds(self):
        """現在の self._keys を画面に反映（古いバインドを解除してから再設定）"""
        # 解除対象: 以前のバインドを全て unbind
        for action in ("capture", "retake", "skip"):
            for k in getattr(self, f"_bound_keys_{action}", []):
                try:
                    self.unbind(k)
                except Exception:
                    pass

        def _bind_action(action: str, callback):
            key   = self._keys[action]
            tk_k  = self._tk_key(key)
            bound = [tk_k]
            self.bind(tk_k, lambda e, cb=callback: cb())
            # 1文字キーは大文字も同時にバインド
            if len(key) == 1 and key.isalpha():
                upper = self._tk_key(key.upper())
                self.bind(upper, lambda e, cb=callback: cb())
                bound.append(upper)
            setattr(self, f"_bound_keys_{action}", bound)

        _bind_action("capture", self._do_capture)
        _bind_action("retake",  self._do_retake)
        _bind_action("skip",    self._do_skip)
        self._update_btn_labels()

    def _update_btn_labels(self):
        """ボタンラベルのショートカット表示を現在のキーに更新"""
        def fmt(k: str) -> str:
            return k.capitalize() if k != "space" else "Space"
        self._btn_capture.config(text=f"📷  キャプチャ  [{fmt(self._keys['capture'])}]")
        self._btn_retake .config(text=f"↩ 再撮り  [{fmt(self._keys['retake'])}]")
        self._btn_skip   .config(text=f"⏭ スキップ  [{fmt(self._keys['skip'])}]")

    def _load_keys(self) -> dict:
        try:
            if KEYBIND_FILE.exists():
                data = json.loads(KEYBIND_FILE.read_text(encoding="utf-8"))
                # 不足キーはデフォルトで補完
                return {**DEFAULT_KEYS, **{k: v for k, v in data.items() if k in DEFAULT_KEYS}}
        except Exception:
            pass
        return dict(DEFAULT_KEYS)

    def _save_keys(self):
        try:
            KEYBIND_FILE.write_text(
                json.dumps(self._keys, ensure_ascii=False, indent=2),
                encoding="utf-8"
            )
        except Exception:
            pass

    def _open_keybind_dialog(self):
        """キーバインド設定ダイアログ"""
        dlg = tk.Toplevel(self)
        dlg.title("キーバインド設定")
        dlg.resizable(False, False)
        dlg.grab_set()

        entries: dict[str, tk.StringVar] = {}
        labels_map = {"capture": "キャプチャ", "retake": "再撮り", "skip": "スキップ"}

        frame = ttk.Frame(dlg, padding=16)
        frame.pack(fill=tk.BOTH, expand=True)

        ttk.Label(frame, text="アクション").grid(row=0, column=0, padx=8, pady=4, sticky=tk.W)
        ttk.Label(frame, text="キー").grid(      row=0, column=1, padx=8, pady=4, sticky=tk.W)

        for i, (action, label) in enumerate(labels_map.items(), start=1):
            ttk.Label(frame, text=label).grid(row=i, column=0, padx=8, pady=4, sticky=tk.W)
            var = tk.StringVar(value=self._keys[action])
            entries[action] = var
            entry = ttk.Entry(frame, textvariable=var, width=14)
            entry.grid(row=i, column=1, padx=8, pady=4)

        ttk.Label(
            frame,
            text="例: space / return / r / s / f1〜f8",
            foreground="gray"
        ).grid(row=4, column=0, columnspan=2, padx=8, pady=(0, 8))

        def _apply():
            # 重複チェック
            vals = [v.get().strip().lower() for v in entries.values()]
            if len(vals) != len(set(vals)):
                messagebox.showwarning("重複", "同じキーを複数のアクションに割り当てられません", parent=dlg)
                return
            for action, var in entries.items():
                self._keys[action] = var.get().strip().lower()
            self._save_keys()
            self._apply_keybinds()
            dlg.destroy()

        def _reset():
            for action, var in entries.items():
                var.set(DEFAULT_KEYS[action])

        btn_row = ttk.Frame(frame)
        btn_row.grid(row=5, column=0, columnspan=2, pady=(4, 0))
        ttk.Button(btn_row, text="リセット", command=_reset).pack(side=tk.LEFT, padx=4)
        ttk.Button(btn_row, text="キャンセル", command=dlg.destroy).pack(side=tk.LEFT, padx=4)
        ttk.Button(btn_row, text="適用", command=_apply).pack(side=tk.LEFT, padx=4)

    # ── デバイス操作 ──────────────────────────────────────────────

    def _refresh_devices(self):
        """ボタンから呼ばれる。バックグラウンドで取得してUIを更新。"""
        self.var_status.set("デバイス一覧を取得中…")
        self.update_idletasks()
        self._refresh_devices_async()

    def _refresh_devices_async(self):
        """バックグラウンドスレッドでデバイス取得 → メインスレッドでUI更新。"""
        self.var_status.set("デバイス一覧を取得中…")
        self.update_idletasks()

        def _fetch():
            raw = list_avfoundation_devices()
            self.after(0, lambda: self._refresh_devices_done(raw))

        threading.Thread(target=_fetch, daemon=True).start()

    def _refresh_devices_done(self, raw: list):
        """デバイス取得完了後にメインスレッドでUIを更新。"""
        # ERR エントリはエラーメッセージとして表示し、デバイスリストには含めない
        errors = [msg for idx, msg in raw if idx == "ERR"]
        self._devices = [(idx, name) for idx, name in raw if idx != "ERR"]

        if errors:
            self.var_status.set(errors[0])
            self._device_combo["values"] = []
            return

        if self._devices:
            labels = [f"[{idx}] {name}" for idx, name in self._devices]
            self._device_combo["values"] = labels
            self._device_combo.current(0)
            self.var_device_index.set(self._devices[0][0])
            self.var_device_label.set(labels[0])
            self.var_status.set(f"{len(self._devices)} 台のデバイスを検出")
        else:
            self._device_combo["values"] = []
            self.var_status.set("デバイスが見つかりません")

    def _on_device_selected(self, event):
        sel = self._device_combo.current()
        if 0 <= sel < len(self._devices):
            self.var_device_index.set(self._devices[sel][0])

    # ── カメラ権限 ──────────────────────────────────────────────────

    def _request_camera_permission_async(self):
        """
        pyobjc 経由で AVCaptureDevice.requestAccessForMediaType_ を呼び、
        macOS TCC にこの .app からのカメラ要求を登録する。
        許可ダイアログ待ちはバックグラウンドスレッドで行い、UI をブロックしない。
        pyobjc が使えない環境（直接 python3 実行時）は何もしない。
        """
        def _request():
            granted = request_camera_permission()
            if granted:
                # 権限取得完了後にデバイス一覧を自動取得
                self.after(0, self._refresh_devices_async)
            else:
                self.after(0, self._warn_camera_permission)

        threading.Thread(target=_request, daemon=True).start()

    def _warn_camera_permission(self):
        self.var_status.set("カメラ権限: 未許可 — システム設定で許可してください")
        messagebox.showwarning(
            "カメラ権限が必要です",
            "システム設定 → プライバシーとセキュリティ → カメラ\n"
            "で CaptureSession を許可してから再起動してください。\n\n"
            "設定画面を開きますか？"
        )
        import subprocess as _sp
        _sp.Popen([
            "open",
            "x-apple.systempreferences:"
            "com.apple.preference.security?Privacy_Camera"
        ])

    # ── 出力先 ───────────────────────────────────────────────────

    def _choose_dir(self):
        d = filedialog.askdirectory(initialdir=self.var_base_dir.get())
        if d:
            self.var_base_dir.set(d)

    # ── セッション制御 ───────────────────────────────────────────

    def _start_session(self):
        if not self.ffmpeg:
            messagebox.showerror("エラー", "ffmpeg が見つかりません")
            return
        if not self.var_device_index.get():
            messagebox.showwarning("デバイス未選択",
                                   "先に「デバイス一覧を更新」してデバイスを選択してください。")
            return

        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.session_dir  = Path(self.var_base_dir.get()) / f"session_{ts}"
        self.capture_dir  = self.session_dir / "capture"
        log_dir           = self.session_dir / "log"
        self.capture_dir.mkdir(parents=True, exist_ok=True)
        log_dir.mkdir(parents=True, exist_ok=True)

        log_path = log_dir / "capture.log"
        self.log_fh = open(log_path, "a", encoding="utf-8")

        # FIX #1/#2: カウンタを完全リセット
        self.png_count          = 0
        self.skip_count         = 0
        self._seq               = 0
        self.last_png_path      = None
        self.last_png_seq       = None
        self._capture_in_flight = False
        self.session_active     = True

        self._thumb_refs.clear()
        for w in self._thumb_inner.winfo_children():
            w.destroy()

        self._set_session_ui(active=True)
        self._append_log(f"START device='{self.var_device_label.get()}' "
                         f"resolution={self.var_resolution.get()} session={ts}")
        self.var_status.set("セッション開始 — Enter でキャプチャ")

    def _end_session(self):
        self.session_active = False
        self._append_log(f"END captures={self.png_count} skipped={self.skip_count}")
        self._close_log()
        self._set_session_ui(active=False)
        self.var_status.set(
            f"セッション終了 — {self.png_count} PNG / {self.skip_count} スキップ  "
            f"→ {self.session_dir}"
        )

    def _set_session_ui(self, active: bool):
        state_on  = tk.NORMAL if active else tk.DISABLED
        state_off = tk.DISABLED if active else tk.NORMAL
        self._btn_start  .config(state=state_off)
        self._btn_end    .config(state=state_on)
        self._btn_capture.config(state=state_on)
        self._btn_retake .config(state=state_on)
        self._btn_skip   .config(state=state_on)

    # FIX #6: ウィンドウクローズ時の安全な終了処理
    def _on_close(self):
        self._stop_preview()
        if self.session_active:
            self._end_session()
        else:
            self._close_log()
        self.destroy()

    def _close_log(self):
        if self.log_fh:
            try:
                self.log_fh.close()
            except Exception:
                pass
            self.log_fh = None

    # ── プレビューウィンドウ ─────────────────────────────────────────

    def _toggle_preview(self):
        if self._preview_active:
            self._stop_preview()
        else:
            self._start_preview()

    def _start_preview(self):
        if not self.ffmpeg:
            messagebox.showerror("エラー", "ffmpeg が見つかりません")
            return
        if not self.var_device_index.get():
            messagebox.showwarning("デバイス未選択",
                                   "先にデバイスを選択してください。")
            return

        # ウィンドウ生成
        win = tk.Toplevel(self)
        win.title("📺 プレビュー")
        win.attributes("-topmost", True)   # 常に最前面
        win.resizable(True, True)
        win.protocol("WM_DELETE_WINDOW", self._stop_preview)

        # デバイス名をタイトルに表示
        device_label = self.var_device_label.get()
        win.title(f"📺 {device_label}")

        # 解像度からアスペクト比を計算して初期ウィンドウサイズを決定
        try:
            w_str, h_str = self.var_resolution.get().split("x")
            aspect = int(w_str) / int(h_str)
        except Exception:
            aspect = 16 / 9
        init_w, init_h = 640, int(640 / aspect)
        win.geometry(f"{init_w}x{init_h}")

        # 背景ラベル（画像表示用）
        lbl = tk.Label(win, background="black", cursor="none")
        lbl.pack(fill=tk.BOTH, expand=True)

        # ステータスラベル
        status_lbl = tk.Label(win, text="取得中…", background="black",
                               foreground="#888", font=("Menlo", 10))
        status_lbl.pack(side=tk.BOTTOM, fill=tk.X)

        self._preview_win        = win
        self._preview_label      = lbl
        self._preview_status_lbl = status_lbl
        self._preview_active     = True
        self._preview_in_flight  = False
        self._btn_preview.config(text="📺 プレビュー停止")

        self._preview_tick()

    def _stop_preview(self):
        self._preview_active = False
        if self._preview_job:
            try:
                self.after_cancel(self._preview_job)
            except Exception:
                pass
            self._preview_job = None
        if self._preview_win:
            try:
                self._preview_win.destroy()
            except Exception:
                pass
            self._preview_win   = None
            self._preview_label = None
        # 一時ファイル削除
        try:
            if os.path.exists(PREVIEW_TMPFILE):
                os.remove(PREVIEW_TMPFILE)
        except Exception:
            pass
        self._btn_preview.config(text="📺 プレビュー表示")

    def _preview_tick(self):
        """1秒ごとにフレームを取得してプレビューを更新する"""
        if not self._preview_active:
            return
        # 前回の取得がまだ完了していない場合はスキップ
        if self._preview_in_flight:
            self._preview_job = self.after(PREVIEW_INTERVAL_MS, self._preview_tick)
            return

        self._preview_in_flight = True

        def _fetch():
            err = capture_frame(
                ffmpeg       = self.ffmpeg,
                device_index = self.var_device_index.get(),
                resolution   = self.var_resolution.get(),
                pixel_format = self.var_pixel_format.get(),
                framerate    = int(self.var_framerate.get()),
                output_path  = PREVIEW_TMPFILE,
            )
            self.after(0, lambda: self._preview_update(err))

        threading.Thread(target=_fetch, daemon=True).start()

    def _preview_update(self, err: str):
        """取得完了後にメインスレッドで画像を更新"""
        self._preview_in_flight = False

        if not self._preview_active or not self._preview_label:
            return

        ts = datetime.now().strftime("%H:%M:%S")

        if err:
            self._preview_status_lbl.config(
                text=f"{ts}  取得失敗: {err.strip()[:80]}"
            )
        elif os.path.exists(PREVIEW_TMPFILE):
            try:
                img = tk.PhotoImage(file=PREVIEW_TMPFILE)
                # ウィンドウサイズに合わせてリサイズ
                win_w = self._preview_win.winfo_width()
                win_h = self._preview_win.winfo_height() - 24  # ステータス分を引く
                if win_w > 1 and win_h > 1:
                    sx = max(1, -(-img.width()  // win_w))
                    sy = max(1, -(-img.height() // win_h))
                    s  = max(sx, sy)
                    img = img.subsample(s, s)
                self._preview_label.config(image=img)
                self._preview_label.image = img   # GC防止
                self._preview_status_lbl.config(text=f"{ts}  更新")
            except Exception as e:
                self._preview_status_lbl.config(text=f"{ts}  表示エラー: {e}")

        # 次回スケジュール
        if self._preview_active:
            self._preview_job = self.after(PREVIEW_INTERVAL_MS, self._preview_tick)

    # ── キャプチャ操作 ────────────────────────────────────────────

    def _do_capture(self):
        if not self.session_active:
            return
        # FIX #5: 飛行中フラグで二重発火を防止
        if self._capture_in_flight:
            return

        # FIX #1: 連番を払い出してからスレッドへ渡す（retake後も重複しない）
        self._seq += 1
        seq     = self._seq
        seq_str = f"{seq:04d}"
        ts      = datetime.now().strftime("%Y%m%d_%H%M%S")
        out     = str(self.capture_dir / f"{seq_str}_{ts}.png")

        self._capture_in_flight = True
        self.var_status.set(f"キャプチャ中… #{seq_str}")
        self._btn_capture.config(state=tk.DISABLED)
        self.update_idletasks()

        def task():
            err = capture_frame(
                ffmpeg        = self.ffmpeg,
                device_index  = self.var_device_index.get(),
                resolution    = self.var_resolution.get(),
                pixel_format  = self.var_pixel_format.get(),
                framerate     = int(self.var_framerate.get()),
                output_path   = out,
            )
            self.after(0, lambda: self._capture_done(seq_str, out, err))

        threading.Thread(target=task, daemon=True).start()

    def _capture_done(self, seq_str: str, out: str, err: str):
        # FIX #5: 飛行中フラグを必ず解除（成功・失敗問わず）
        self._capture_in_flight = False

        if err:
            # FIX #1: 失敗時は払い出し済みの連番を戻す
            self._seq -= 1
            self._append_log(f"Capture failed #{seq_str}: {err.strip()}", "error")
            self.var_status.set(f"キャプチャ失敗 #{seq_str}")
        else:
            # FIX #1: png_count のみインクリメント（seq とは独立）
            self.png_count    += 1
            self.last_png_path = out
            self.last_png_seq  = seq_str
            self._append_log(f"Captured #{seq_str} → {Path(out).name}")
            self._add_thumbnail(seq_str, out, kind="ok")
            self.var_status.set(f"#{seq_str} キャプチャ完了")
            self._update_progress()

        # FIX #5: session_active を確認してからボタンを戻す
        if self.session_active:
            self._btn_capture.config(state=tk.NORMAL)

    def _do_retake(self):
        if not self.session_active or not self.last_png_path:
            return
        path    = self.last_png_path
        seq_str = self.last_png_seq

        if os.path.exists(path):
            os.remove(path)

        # FIX #1: png_count を減らし、_seq も戻して連番を再利用
        self.png_count    -= 1
        self._seq         -= 1
        self.last_png_path = None
        self.last_png_seq  = None

        self._append_log(f"Retake: discarded #{seq_str}")
        self.var_status.set(f"#{seq_str} を破棄 — 再撮りしてください")
        self._remove_last_thumbnail()
        self._update_progress()

    def _do_skip(self):
        if not self.session_active:
            return

        # FIX #2: skip と seq を独立管理。連番は seq から払い出す
        self._seq   += 1
        self.skip_count += 1
        seq_str = f"{self._seq:04d}"

        placeholder = self.capture_dir / f"{seq_str}_SKIPPED.txt"
        placeholder.touch()
        self._append_log(f"Skipped #{seq_str}")
        self.var_status.set(f"#{seq_str} スキップ")
        self._add_thumbnail(seq_str, None, kind="skip")
        self._update_progress()

    # ── 進捗バー ─────────────────────────────────────────────────

    def _update_progress(self):
        expected = self.var_expected.get()
        # FIX #2: png_count のみで進捗計算（skip は分母に含めない）
        if expected > 0:
            pct = min(100, int(self.png_count / expected * 100))
            self._progress["value"] = pct
            self._lbl_progress.config(
                text=f"{self.png_count} / {expected}  ({pct}%)"
            )
            if self.png_count >= expected:
                self.var_status.set(
                    f"予定枚数 {expected} 枚に到達 — 継続または終了してください"
                )
        else:
            self._progress["value"] = 0
            self._lbl_progress.config(text=f"{self.png_count} PNG")

    # ── サムネイル ────────────────────────────────────────────────

    def _add_thumbnail(self, seq_str: str, png_path: Optional[str], kind: str):
        """サムネイルカードをグリッドに追加"""
        idx   = len(self._thumb_refs)
        col   = self._thumb_col
        row_i = idx // col
        col_i = idx % col

        card = tk.Frame(self._thumb_inner, background="#2a2a2a",
                        relief=tk.FLAT, bd=1)
        card.grid(row=row_i, column=col_i, padx=4, pady=4, sticky=tk.NW)

        if png_path and os.path.exists(png_path):
            try:
                img = self._load_thumbnail(png_path)
                lbl_img = tk.Label(card, image=img, background="#2a2a2a")
                lbl_img.pack()
                self._thumb_refs.append(img)   # GC防止
            except Exception:
                self._add_placeholder_label(card, seq_str, kind)
                self._thumb_refs.append(None)
        else:
            self._add_placeholder_label(card, seq_str, kind)
            self._thumb_refs.append(None)

        color = "#ffa94d" if kind == "skip" else "#868e96"
        label_text = f"#{seq_str}" + (" SKIP" if kind == "skip" else "")
        tk.Label(card, text=label_text, foreground=color,
                 background="#2a2a2a", font=("Menlo", 9)).pack()

        # スクロールを末尾へ
        self._thumb_inner.update_idletasks()
        self._canvas.configure(scrollregion=self._canvas.bbox("all"))
        self._canvas.yview_moveto(1.0)

    def _add_placeholder_label(self, parent, seq_str: str, kind: str):
        icon  = "⏭" if kind == "skip" else "📷"
        color = "#ffa94d" if kind == "skip" else "#495057"
        tk.Label(parent, text=icon, font=("", 24),
                 width=THUMB_W // 14, height=THUMB_H // 20,
                 background=color, foreground="white").pack()

    def _load_thumbnail(self, path: str):
        # FIX #4: アスペクト比を保ったまま THUMB_W×THUMB_H の枠に収める
        img = tk.PhotoImage(file=path)
        w, h = img.width(), img.height()
        # 縦横それぞれの縮小率を独立計算し、大きい方（より縮む）を採用
        sx = max(1, -(-w // THUMB_W))   # ceil(w / THUMB_W)
        sy = max(1, -(-h // THUMB_H))   # ceil(h / THUMB_H)
        s  = max(sx, sy)
        return img.subsample(s, s)

    def _remove_last_thumbnail(self):
        if not self._thumb_refs:
            return
        self._thumb_refs.pop()
        children = self._thumb_inner.winfo_children()
        if children:
            children[-1].destroy()

    def _on_canvas_configure(self, event):
        self._canvas.configure(scrollregion=self._canvas.bbox("all"))

    def _on_canvas_width(self, event):
        # Canvas 幅に合わせて内部フレーム幅を更新
        self._canvas.itemconfig(self._canvas_win, width=event.width)
        new_col = max(1, event.width // (THUMB_W + 12))
        if new_col != self._thumb_col:
            self._thumb_col = new_col

    # ── ログ ─────────────────────────────────────────────────────

    # FIX #3: level 引数を実際にタグ判定に使用する
    def _append_log(self, message: str, level: str = "info"):
        ts  = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
        if level == "error":
            tag      = "error"
            severity = "ERROR"
        elif level == "warn":
            tag      = "warn"
            severity = "WARN "
        else:
            tag      = "info"
            severity = "INFO "
        line = f"{ts} [{severity}]  {message}\n"

        self._log_text.config(state=tk.NORMAL)
        self._log_text.insert(tk.END, line, tag)
        self._log_text.see(tk.END)
        self._log_text.config(state=tk.DISABLED)

        if self.log_fh:
            self.log_fh.write(line)
            self.log_fh.flush()


# ── エントリポイント ──────────────────────────────────────────────

if __name__ == "__main__":
    app = App()
    app.mainloop()
