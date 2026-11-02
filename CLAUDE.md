# CLAUDE.md — pix-tv-mac

PIXELA の USB チューナー **PIX-DT295**（本来 Windows 専用、VID:PID `06b8:103b`）を、
非公式ユーザー空間ドライバ **pix-userland** と mpv で Apple Silicon Mac から視聴するためのスクリプト集。
利用者向けの説明は `README.md`。ここには作業の引き継ぎに必要な経緯・設計判断・落とし穴をまとめる。

- 環境: MacBook Air M4 / macOS / Homebrew（`~/.homebrew` の場合あり）/ mpv 0.41 / FFmpeg 9 / bash 3.2（macOS 標準）
- 受信地: 静岡県内（静岡の各局に加え、関東の tvk・テレ東が入る）
- リモート: `git@github.com:tondol/pix-tv-mac.git`。コミットメッセージは日本語。

## 構成

```
tv.sh ─┬─ pixd（デーモン、USB を保持）… tv.sh が起動し、終了時に TERM で止める
       └─ watch: pix-ts → FIFO(in) → ffmpeg(指定サービスだけ -c copy) → FIFO(out) → mpv（JSON IPC で制御）
setup.sh … brew で依存導入 → pix-userland を commit 38ef18e に固定して clone → dt295-xfer.patch 適用 → cmake で pixd/pixctl/pix-ts だけビルド
sdt_names.py … TS の SDT から局名を読む（TS 解析は自前、ARIB 文字列だけ ariblib でデコード。ariblib の TS リーダは Python 3.7+ で壊れている）
dt295-xfer.patch … pix-userland への独自パッチ（下記）
```

- 放送スクランブルはチューナー内で B-CAS により解除済み。ソフト側で B25/MULTI2 は不要（pix-userland も非対応）。
- `tv.sh` のサブコマンド: `watch [局]`（省略時の既定）/ `rec <局> [秒]` / `list` / `scan` / `names <ch>...` / `diag <局> [秒]` / `help`。
  局は キー（nhk）・リモコン番号（1）・物理ch（T20）で指定。局表は `tv.sh` 冒頭の `STATIONS`。

## 守ること

- **bash 3.2 互換**（`$BASHPID`・`read -t 0.5` 小数・`{fd}<>` などは不可）。高精度の時刻や sleep は `perl -MTime::HiRes`。
- 利用者向けメッセージ・コメント・README は日本語。
- `watch` は `logs/` に `mpv.log` `ffmpeg.log` `pix-ts.log` `pixd.log`（UNIX 時刻付き）`switch.log` `ipc.log` を出す。調査はまずここ。
- 実機テストは `./tv.sh diag <局> 15`（0.5 秒ごとの状態＋時刻付き pixd ログ）。
- チューナーが変な状態（`USB_IO` / `NO_CARD` / データ 0）になったら **USB を挿し直す** のが確実な復旧手段。

## これまでに踏んだ落とし穴（再発させないこと）

1. **macOS の mpv は FIFO をパスで開くと極端に遅い**（29 秒で 18KB）。`ffmpeg://file:<path>` で開かせる。stdin（`-`）は問題ない。
2. **pix-ts は出力先が閉じると `INTERNAL` で異常終了し、チューナーが中途半端な状態で残る**。
   対策: `pix-ts | { cat || cat >/dev/null; }` で下流切断後も読み捨て、止めるときは `pix-ts` に SIGTERM（PID は `sh -c 'echo $$ > file; exec ...'` で取得）。
3. **書き手の現れない FIFO を mpv が開くと mpv ごと固まり、切替も `q` も効かなくなる**。
   対策: 出力 FIFO をシェルが `exec 7<>"$fout"` で両方向に開いて保持し、切替時に `exec 7>&-` で閉じて EOF を渡す。子プロセスには `7>&-` で継承させない。
4. **選局処理中に pix-ts を止めると pixd が落ちる**（`PIX_CONTEXT_POLL error=255`）。選局間隔を最低 `PIX_TV_MIN_GAP`（2 秒）空け、連打は 0.35 秒以内の要求をまとめる。
5. **ドライバはロック（電波捕捉）を確認しない**。掴めないと 0 パケットのまま `rc=0` で待ち続ける → watch に見張り（6 秒で再選局、最大 3 回）。
6. `exec 7>&- 2>/dev/null` のように exec にリダイレクトを付けるとシェルの stderr が恒久的に消える。付けない。
7. mpv の `osd-overlay` を IPC から作ると接続終了で消える → 局リストは起動時に読み込ませる Lua スクリプト（`tv-osd.lua`、`script-message tv-osd`）で描く。
8. mpv の `--geometry` は Retina では実ピクセル単位で位置もずれる → 画面比の `70%x63%+50%+50%` を既定に。
9. OSC の ◀◀/▶▶ は `--script-opts-append=osc-playlist_{prev,next}_mbtn_left_command=script-message tv-step ...` で局切替に割当（mpv 0.38+）。ボタンを有効にするため `--loop-playlist=inf`、終端で次を読まないよう `--keep-open=always`。

## 独自パッチ dt295-xfer.patch（pix-userland 38ef18e 向け）

選局から受信開始が上流で約 13 秒 → 約 1.3〜1.8 秒（watch 切替時）。環境変数なしなら上流と同じ動作で、上流テストも通る。

- `src/dt295_stream.c` / `include/dt295_stream.h`: バルク転送サイズ・本数を環境変数で可変（`PIX_DT295_XFER_BYTES`, `PIX_DT295_XFERS` 最大 32）。
  番組表取得中だけ `PIX_DT295_ACQ_XFER_BYTES`（tv.sh 既定 2048）を使う。DT295 は転送が満杯になるまで返さないため、PSI だけ流れる取得中に 64KB だと 10 秒前後待たされていた。
- `pix-dt295-receiver-adapter.cpp`: 取得開始/本番開始で `dt295_stream_set_acquisition_hint()` を呼ぶ。`pix-tv:` で始まる計測ログ（open / card / tune / first usb data / psi）。
- 以前は `src/dt295_routes.c` に地デジで CAT を待たない変更（`PIX_DT295_CAT_OPTIONAL`）も入れていたが、上流 58085f0 で CAT 待ちが廃止されたので外した。
- パッチを直したら `cd pix-userland && git diff > ../dt295-xfer.patch`。`setup.sh` は対象ファイルを checkout で戻してから当て直す。

## 上流 pix-userland への追従

**最終確認: 2026-11-02（38ef18e）**。作業開始時にこの日付から 1 週間以上たっていたら、追従するか利用者に一言聞く。

1. `git -C pix-userland fetch origin` → `git log --oneline <PIN>..origin/main` で新しいコミットを確認。
   パッチ対象（`include/dt295_stream.h` `src/dt295_stream.c` `pix-dt295-receiver-adapter.cpp`）と、選局・PSI・CAT・停止処理まわりの変更を読む。
2. **パッチの各部分が上流で不要になっていないか判断する**（例: CAT 待ちは 58085f0 で上流が対応したので外した）。
   上流の README / docs で、pix-ts の未実装オプションや既知のバグ（報告候補）が直っていないかも見る。
3. 最新に当たるか確認: `git worktree add --detach /private/tmp/claude-501/pu-latest origin/main` → `git apply --check -v ../dt295-xfer.patch` → `git worktree remove --force`。
   当たらなければ最新の上で手で当て直し、`git diff > ../dt295-xfer.patch` で作り直す。
4. **更新前のビルドで先に基準を測る**（受信状況は日によって変わるので、比較は同じ時間帯に行う）: `./tv.sh diag nhk 12` を 2 回。
   出力の `pix-tv: tune begin` → `first usb data` → `psi ... ready=1` の時刻と、最初に `size>0` になった時刻を記録する。
5. `setup.sh` の `PIN_COMMIT` を書き換え → `HOMEBREW_NO_AUTO_UPDATE=1 ./setup.sh` → 同じ diag を 2 回で比較。
   2026-11-02 の基準（T20）: first usb data 約 0.9 秒、ready 約 1.4〜2.0 秒、データ出始め 2.4〜3.0 秒（0.5 秒刻み）。
6. 遅くなる・`rc≠0`・受信できない場合は `PIN_COMMIT` を戻して原因を調べる。問題なければ README・CLAUDE.md の commit 番号とこの節の最終確認日を更新する。
   watch の切替は自動計測できないので、利用者に `./tv.sh` で体感確認を頼む。

## 状況・既知の問題

- 受信確認済み（2026-11-02）: T13 Eテレ / T15 SBS / T17 テレビ静岡 / T18 静岡朝日 / T19 静岡第一 / T20 NHK総合 / T23 テレ東 / T26 tvk（`STATIONS` の全 8 局）。
- T13（Eテレ）は 2026-11-02 早朝だけデータが来なかったが、上流設定でも同じで、その後は受信できている。送信側の停波（深夜・早朝のメンテナンス）だった可能性が高い。
  1 局だけ来ないときは、ソフトを疑う前に時間をおいて再確認する。
- `B-CAS: present=unknown` は表示上のもので受信に支障なし。
- BS/CS は未着手（DT295 は LNB 給電なし）。

## 次にやりたいこと

- **Synology DS920+（x86_64 / Container Manager）に DT295 を挿して mirakc 化**。
  1 コンテナに pixd + 受信ラッパー（上記 2・5 の対策入り、選局失敗はタイムアウトで終了）+ mirakc、パッチ済み pix-userland を Linux x64 でビルド、USB は `privileged` で渡す。
  既存の yude/pix-userland-mirakc-tuner（Go の薄いラッパー、実機未検証）が参考。EPGStation / KonomiTV は compose で後付け。
  DT295 の Linux 実機受信は上流でも未確認なので、まず diag 相当で受信確認から。
- pix-userland への報告候補（未送付）:
  Issue「取得中の 64KB 転送で選局が遅い」、PR「macOS で test ターゲットがビルドできない（mkdtemp 未宣言・`--wrap` 非対応）」
  「README の `pix-ts --control` / `--fail-on-drop` が未実装」、バグ報告「ロック未確認で 0 パケット rc=0」「選局中停止で pixd が落ちる」。
