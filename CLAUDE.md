# CLAUDE.md

PIXELA の USB チューナー **PIX-DT295**（本来 Windows 専用、VID:PID `06b8:103b`）を、非公式ユーザー空間ドライバ
**pix-userland** と **mirakc** で Docker のチューナーサーバーにするリポジトリ。mpv で見るクライアント（client/）も含む。
利用者向けの説明は `README.md`。ここには作業の引き継ぎに必要な経緯・設計判断・落とし穴をまとめる。

- 対象は「Docker が動く Linux ＋ DT295」と「mpv が動くクライアント（macOS で確認、Linux も想定）」。特定の NAS・OS・地域を前提にしない。
  個人の環境（ホスト名・局の設定）はリポジトリに入れない（`server/config.yml` `client/tv.conf` は gitignore）。
- 開発時の環境: サーバーは Synology DS920+（DSM 7.4 / カーネル 4.4 / docker 24）、クライアントは MacBook Air M4（mpv 0.41 / bash 3.2）。
- コミットメッセージは日本語。リポジトリ名は今後変える予定なので、ドキュメントにリポジトリ名・URL を書かない。

## 構成

```
server/ … Docker イメージ（mirakc + pixd + 受信ラッパー）
  Dockerfile        pix-userland を PIX_COMMIT に固定して clone → dt295-xfer.patch → cmake で pixd/pixctl/pix-ts
                    → mirakc/mirakc:debian に載せる。firmware/dt295.bin は /usr/local/share/pix/ に置き、pixd に --firmware で渡す
  entrypoint.sh     USB の位置を調べて pixd を常駐（落ちたら作り直す）→ mirakc を exec
  pix-dt295-tuner      mirakc の tuners[].command。地デジは 20 / T20、BS は BS15_0。TS を stdout に出す（下の落とし穴 1〜3 の対策）
  pix-dt295-scan       受信できる物理 ch を調べて channels 設定を出力（docker compose exec mirakc pix-dt295-scan [bs]）
  compose.yaml      privileged + /dev/bus/usb、init: true、named volume（epg・log）、40772 番
  config.example.yml / deploy.sh（ssh 先へ転送して compose up）
client/ … 視聴スクリプト（macOS / Linux）
  tv.sh             watch / rec / list。局一覧は mirakc の /api/services から取る（局表を持たない）
  tv.lua            mpv スクリプト。キー・OSC ボタン → loadfile、局リスト OSD、見張り（映像が出なければ再選局）
```

- 放送スクランブルはチューナー内で B-CAS により解除済み。ソフト側で B25/MULTI2 は不要（mirakc の decode-filter も不要）。
- ログはコンテナ内の `/var/log/pix/`（`pixd.log` `pix-ts.log`、時刻付き）と `docker compose logs`（mirakc）。調査はまずここ。
  クライアントは `client/logs/mpv.log`。

## 守ること

- `client/` は macOS 標準の **bash 3.2 でも動くこと**（`$BASHPID`・`read -t` の小数・`{fd}<>` などは不可）。JSON は python3。GNU 固有のオプションも避ける。
  `server/` はコンテナ内の bash 5 で動く。
- 利用者向けメッセージ・コメント・README は日本語。
- チューナーが変な状態（`USB_IO` / `NO_CARD` / データ 0）になったら **USB を挿し直してコンテナを再起動** するのが確実な復旧手段。
  コンテナの再起動だけでは直らない（2026-11-02 に確認）。

## これまでに踏んだ落とし穴（再発させないこと）

1. **mirakc は受信コマンドを止めるとき、直接の子プロセスに SIGKILL だけを送る（猶予なし）**（mirakc-core `command_util.rs`）。
   ラッパーが殺されると pix-ts が取り残されるので、見張りプロセスがラッパーの消滅を検知して pix-ts に SIGTERM を送る。
   SIGKILL 後の孤児を回収するため compose で `init: true`。
2. **pix-ts は出力先が閉じると `INTERNAL` で異常終了し、チューナーが中途半端な状態で残る**。
   対策: `> >(cat || exec cat >/dev/null)` で下流切断後も読み捨て、止めるときは pix-ts に SIGTERM。
3. **選局処理中に pix-ts を止めると pixd が落ちる**（`PIX_CONTEXT_POLL error=255`）。選局から最低 `PIX_DT295_MIN_GAP`（2 秒）は止めず、
   次の選局は `flock` で前の後片付けが終わるまで待つ（ロックの fd は pix-ts・見張りが持ち続ける）。
4. **ドライバはロック（電波捕捉）を確認しない**。掴めないと 0 パケットのまま待ち続ける →
   サーバーは mirakc の `time-limit: 10000`、クライアントは tv.lua の見張り（`TV_WATCHDOG_SEC`、最大 3 回再選局）。
5. **pixd は runtime ディレクトリが 700 でないと拒否する**（pix-ts は `UNSUPPORTED`、pixd は `PIX_STAGE reserve error=11`）。entrypoint で chmod 700。
6. Synology の docker は存在しないパスをバインドマウントできない → データは named volume にした。非対話 ssh では PATH に docker が無い（`/usr/local/bin` を足す）。
7. mpv の `--geometry` は Retina では実ピクセル単位で位置もずれる → 画面比の `70%x63%+50%+50%` を既定に。
8. OSC の ◀◀/▶▶ は `--script-opts-append=osc-playlist_{prev,next}_mbtn_left_command=script-message tv-step ...` で局切替に割当（mpv 0.38+）。
   ボタンを有効にするため `--loop-playlist=inf`、終端で次を読まないよう `--keep-open=always`。
9. mpv の数字キー・↑↓ は既定の割当があるので `mp.add_forced_key_binding` で上書きする。
10. **DT295 は一度固まると電源を切るまで戻らない**（`boot failed: firmware boot requires cold state 0 or unauthenticated state 16`）。
    前の pixd のセッション（鍵）を持ったまま残るため。sysfs の `authorized` 0→1 も `USBDEVFS_RESET` も効かなかった（2026-11-02）。
    固まる原因を作らないことが最優先。自動復旧するなら uhubctl 対応ハブでの電源の入れ直しが候補（未検証）。
11. **上流 a31a43e の「CAT が来たら部分プランで開始」で、T17 は TS が出ないまま止まり、停止時に pixd が落ちた** → 38ef18e まではパッチで無効化していた。
    5d8bd93 では無効化を外して T17 を 15 秒×3・選局 3 秒で停止×3 しても正常（2026-11-05）。ただしその試験で地デジの `state=partial` は
    一度も起きておらず、上流の計画処理の書き直しで直ったのか再現しなかっただけかは不明。症状が戻ったらパッチ（`may_plan` から `snapshot.have_cat` を外す）を戻す。
12. **1〜2 分選局しないと、次の open でカード初期化が失敗する（`card initialization requires authenticated idle state` → NO_CARD）**。
    DT295 のセッションは 30 秒ごとの更新（`dt295_renew_if_due`、チャレンジ応答）が必要なのに、上流は `pump()`（受信中）からしか呼ばない。
    番組表取得のように約 60 秒間隔なら持つが、112 秒空くと失効した。→ 38ef18e まではパッチで pixd に更新スレッドを足していた。
    上流 5d8bd93 は close でセッションを終える（次の open で認証し直す。ログは毎回 `open begin session=0`）ので、アイドル中に失効するセッションが無い。
    更新スレッドを外して 2 分 36 秒空けてから選局しても正常（2026-11-05）。
13. ログは named volume に残るので、entrypoint の「pixd ready」待ちは今回の起動以降の行だけを見る（前回の行で早まると最初の選局が rc=3）。
14. **コンテナを止めるときは pixd を正常終了させる**。entrypoint が `exec mirakc` していた頃は SIGTERM が pixd に届かず SIGKILL され、
    DT295 がセッションを持ったまま固まった（再起動・更新のたびに挿し直しが必要だった）。今は trap で mirakc → 受信の後片付け → pixd の順に止め、
    compose の `stop_grace_period: 30s`。`docker compose restart` 後に挿し直しなしで boot できることを確認済み（2026-11-02）。
15. **上流 5d8bd93 から pix-ts は `--receiver ID` が必須、pixd は `--firmware FILE` が必須**（埋め込みの CMake オプションも廃止）。
    `--receiver` が無いと pix-ts は `argument error` で rc=2 になり、mirakc の選局がすべて失敗する（受信ラッパーは `--receiver 0`）。
16. **BS のロック待ちがタイムアウトすると DT295 が固まった**（上流の `fail()` はどんな失敗でも context を `poisoned` にするため、
    以後は `boot failed: DT295 context unavailable` で地デジも含めて全滅し、挿し直しが必要）。電波の無いトランスポンダ・スロットを選ぶだけで起きる。
    → パッチで衛星のロック待ちのタイムアウトだけ `soft_fail()`（poisoned にしない）。空きスロット（TSID 0）は上流でも poisoned にならない（rc=2）。
    38ef18e では最初の BS 選局で `PIX_CONTEXT_POLL error=255` になり pixd ごと落ちた。5d8bd93 ではこれは起きない。
17. mirakc は起動直後に全局の scan-services・update-schedules を回す（BS 込みで 15 分ほど）。その間に手動で pix-dt295-tuner を叩くと
    flock で待たされたまま timeout になり 0 バイトに見える。試験は `/api/tuners` の users が空になってから。

旧構成（Mac にチューナーを直結、tv.sh が pixd を起動して FIFO→ffmpeg→mpv）で得た知見:
macOS の mpv は FIFO をパスで開くと極端に遅い（`ffmpeg://file:` で回避）、書き手の現れない FIFO を開くと mpv ごと固まる。

## 独自パッチ server/dt295-xfer.patch（pix-userland 5d8bd93 向け）

選局から受信開始が上流で約 13 秒 → 約 1.5 秒。転送サイズは環境変数なしなら上流と同じ。BS の soft_fail は常に効く（上流テストは未実行）。

- `src/dt295_stream.c` / `include/dt295_stream.h`: バルク転送サイズ・本数を環境変数で可変（`PIX_DT295_XFER_BYTES`, `PIX_DT295_XFERS` 最大 32）。
  番組表取得中だけ `PIX_DT295_ACQ_XFER_BYTES`（compose 既定 2048）を使う。DT295 は転送が満杯になるまで返さないため、PSI だけ流れる取得中に 64KB だと 10 秒前後待たされていた。
- `pix-dt295-receiver-adapter.cpp`: 取得開始/本番開始で `dt295_stream_set_acquisition_hint()` を呼ぶ。`pix-dt295-mirakc:` で始まる計測ログ（open / card / tune / first usb data / psi）と、
  boot / open_session / card initialize / card activate が失敗したときの理由（上流は捨てていて、全部 USB_IO / NO_CARD としか分からない）。
- `src/dt295.c`: 衛星のロック待ちのタイムアウト（`dt295_satellite_wait_lock`・TSID 指定の `dt295_tune_satellite`）を `soft_fail()` に（落とし穴 16）。
- 以前は `src/dt295_routes.c` に地デジで CAT を待たない変更も入れていたが、上流 58085f0 で CAT 待ちが廃止されたので外した。
- パッチを作り直すときは、手元に pix-userland を clone（gitignore 済み）して `PIX_COMMIT` を checkout → 当てて編集 → `git diff > ../server/dt295-xfer.patch`。

## 上流 pix-userland への追従

**最終確認: 2026-11-05（5d8bd93）**。作業開始時にこの日付から 1 週間以上たっていたら、追従するか利用者に一言聞く。

1. 手元の `pix-userland/`（無ければ clone）で `git fetch origin` → `git log --oneline <PIX_COMMIT>..origin/main`。
   パッチ対象（`include/dt295_stream.h` `src/dt295_stream.c` `pix-dt295-receiver-adapter.cpp`）と、選局・PSI・CAT・停止処理まわりの変更を読む。
2. **パッチの各部分が上流で不要になっていないか判断する**（例: CAT 待ちは 58085f0 で上流が対応したので外した）。
   上流の README / docs で、pix-ts の未実装オプションや既知のバグ（報告候補）が直っていないかも見る。
3. 最新に当たるか確認: `git worktree add --detach /private/tmp/claude-501/pu-latest origin/main` → `git apply --check -v <repo>/server/dt295-xfer.patch` → `git worktree remove --force`。
4. **更新前のイメージで先に基準を測る**（受信状況は日によって変わるので同じ時間帯に比較）。視聴していないときに
   `docker compose exec mirakc sh -c 'timeout 12 pix-dt295-tuner 20 | wc -c'` を 2 回 → `/var/log/pix/pixd.log` の
   `pix-dt295-mirakc: tune begin` → `first usb data` → `psi ... ready=1` の時刻差を記録する。
   2026-11-05 の基準（5d8bd93、NAS、mirakc の起動時の選局から）: first usb data 約 0.8〜1.3 秒、ready 約 1.1〜1.7 秒。
   起動時の mirakc の選局（scan-services）の pixd.log でも同じ時刻差が取れるので、手動の計測の代わりに使える。
5. `server/Dockerfile` の `PIX_COMMIT` を書き換え → `server/deploy.sh <host> <dir>` → 同じ計測を 2 回で比較。
6. 遅くなる・受信できない場合は `PIX_COMMIT` を戻す。問題なければ README・CLAUDE.md の commit 番号とこの節の最終確認日を更新し、
   利用者に `client/tv.sh` で切替の体感確認を頼む。

## 状況・既知の問題

- 2026-11-02: DS920+ のコンテナで受信・mirakc のサービス検出（8 局 22 サービス）・Mac からのストリーム取得まで確認。
- アイドル後の NO_CARD（落とし穴 12）は、上流 5d8bd93 が close でセッションを終えるようになって起きなくなった。
- `B-CAS: present=unknown` は表示上のもので受信に支障なし。
- BS: 2026-11-05 に 5d8bd93 + パッチで受信を確認（BS 全スキャン 48 通りで固まらない）。CS は未対応（上流で複数 ECM の録画が止まる）。
  DT295 は LNB 給電なし。

## 次にやりたいこと

- それでも固まったときの自動復旧（uhubctl 対応ハブでの電源の入れ直し。未検証）。
- EPGStation / KonomiTV を compose で後付け。
- pix-userland への報告候補（未送付）:
  Issue「取得中の 64KB 転送で選局が遅い」、PR「macOS で test ターゲットがビルドできない（mkdtemp 未宣言・`--wrap` 非対応）」
  「README の `pix-ts --control` / `--fail-on-drop` が未実装」、バグ報告「ロック未確認で 0 パケット rc=0」「選局中停止で pixd が落ちる」、
  バグ報告「DT295 で衛星のロック待ちがタイムアウトすると context が poisoned になり、挿し直すまで全選局が失敗する」（落とし穴 16）。
