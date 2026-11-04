# pix-dt295-mirakc — PIX-DT295 を mirakc のチューナーサーバーにする

ピクセラの USB チューナー **PIX-DT295**（本来は Windows 専用）を、非公式のユーザー空間ドライバ
[pix-userland](https://github.com/Khronos31/pix-userland) と [mirakc](https://github.com/mirakc/mirakc) で
Docker のチューナーサーバーにするためのスクリプト一式です。ネットワーク越しに mpv で視聴・録画するクライアントも付いています。

> pix-userland の DT295 対応は **試験段階** です。BS は独自パッチ込みで受信を確認していますが、CS は未対応です。
> さらにこのリポジトリでは独自パッチを当てています（後述）。

> **免責**: 本リポジトリは個人の非公式プロジェクトで、株式会社ピクセラ・pix-userland・mirakc の開発元とは無関係です。
> メーカーのサポート対象外の使い方であり、無保証です。機器の故障・データの損失などについて作者は責任を負いません。
> 受信した放送の録画・利用は私的使用の範囲で行ってください。

## 仕組み

```
[サーバー: Linux + Docker]                                      [クライアント]
PIX-DT295 ─USB─ pixd ─ pix-dt295-tuner(pix-ts) ─ mirakc :40772 ─┬─HTTP── client/tv.sh ─ mpv
                                                              └─HTTP── EPGStation / KonomiTV など
```

- `server/`: mirakc の公式イメージに、パッチを当ててビルドした pix-userland（pixd / pix-ts）と受信ラッパーを載せたイメージ。
  mirakc は Mirakurun 互換の API を持つので、EPGStation や KonomiTV などからもそのまま使えます。
- `client/`: mirakc から局一覧を取ってきて mpv で見るスクリプト。局切替は mpv の中（Lua）で行います。
- 放送のスクランブルは **チューナー本体内で B-CAS カードにより解除** されます。B-CAS カードを本体に挿しておく必要があります。

## サーバー（Docker）

### 必要なもの

- Linux と Docker / Docker Compose v2。動作確認は x86_64（Synology DS920+ の Container Manager）
- PIX-DT295 本体、B-CAS カード、地デジアンテナ（BS も見るなら BS アンテナ。DT295 は LNB 給電をしないので、給電は外部機器で）
- コンテナに USB を渡すため `privileged` で動かします

### セットアップ

`server/` ディレクトリをチューナーを挿したホストに置き、局の設定を作って起動します。

```sh
cd server
cp config.example.yml config.yml         # channels はあとで自分の地域に合わせる
docker compose up -d --build             # 初回はビルドに数分かかります
docker compose exec mirakc pix-dt295-scan   # T13〜T52 を走査（5 分ほど）。受信できた ch の設定を出力
```

`pix-dt295-scan` が出力した `channels:` を `config.yml` に貼り付けて、`docker compose restart` してください。
mirakc が各チャンネルのサービス（局のサブチャンネル）を自動で調べます。
一部だけ調べるときは `pix-dt295-scan 20 26` のようにチャンネル番号を渡します。
BS は `pix-dt295-scan bs`（BS01〜BS23 の各スロット 0〜3 を走査、10 分ほど）で調べ、`channel: 'BS15_0'` のように
トランスポンダ番号とスロット番号で書きます。BS を使うときは `tuners` の `types` を `[GR, BS]` にしてください。
受信量が少ない（1MB 前後）ものは有料放送で、契約がないと映りません。

別のマシンで編集して ssh 先へ送る場合は `deploy.sh` が使えます（`config.yml` が手元にあればそれも送ります）。

```sh
./server/deploy.sh <ssh ホスト> <配置先ディレクトリ>
```

### 確認

```sh
curl http://<ホスト>:40772/api/services                # 局（サービス）の一覧
docker compose logs -f                                  # mirakc のログ
docker compose exec mirakc tail -f /var/log/pix/pixd.log /var/log/pix/pix-ts.log
```

mirakc に認証はありません。LAN や VPN（Tailscale など）の内側だけで公開してください。

## クライアント

### mpv で直接見る

mirakc のストリームは HTTP の MPEG-TS なので、対応したプレイヤーならそのまま再生できます。

```sh
mpv http://<ホスト>:40772/api/services/<サービス ID>/stream
```

### client/tv.sh

局の一覧表示・番号キーでの切替・録画をまとめたスクリプトです。
`bash`・`mpv`・`curl`・`python3` を使います。macOS で動作確認しています（標準の bash 3.2 で動くように書いています）。
Linux でも同じ手順で動く想定ですが、未確認です。

```sh
brew install mpv                         # mpv の導入（macOS の例）
cd client
echo 'TV_MIRAKC_URL=http://<ホスト>:40772' > tv.conf    # 接続先（環境変数でも可）
./tv.sh              # 視聴（リモコン番号が最小の局から）
./tv.sh 5            # リモコン番号・局名の一部・サービス ID で局を指定（例: 5 / NHK / 3219235840）
./tv.sh list         # 局一覧
./tv.sh rec 1 1800   # 1800 秒録画（選んだ局のみ）。秒を省略すると Ctrl+C まで
```

mpv のウィンドウ上で操作します。

| キー | 動作 |
|---|---|
| `1`〜`9` | リモコン番号の局へ切替 |
| `↑` / `↓` | 局リストの 1 つ上 / 下の局へ（端で反対側に回る） |
| `l` | 局リストを 5 秒表示 |
| 画面下の ◀◀ / ▶▶ ボタン | 前 / 次の局へ（`↑` / `↓` と同じ） |
| `q` | 終了 |

- 切り替えると画面左上に全局リストが出て、選局中の局が黄色・太字（▶）になります。
- 連打した場合は最後の局にだけ選局します（`↓↓↓` なら 3 つ先）。
- 一定時間たっても映像が出ない場合は自動で選局し直し（最大 3 回）、だめなら「受信できません」と表示します。
- 局一覧は物理チャンネルごとにメインのサービス（サービス ID が最小のもの）だけを並べます。
  サブチャンネルはサービス ID で指定すれば見られます。

## 設定（環境変数）

サーバー（`server/compose.yaml` の `environment`）

| 変数 | 既定 | 内容 |
|---|---|---|
| `PIX_DT295_ACQ_XFER_BYTES` | 2048 | 番組表取得中の USB 転送サイズ（パッチ） |
| `PIX_DT295_XFER_BYTES` | 65536 | 受信中の USB 転送サイズ（パッチ。上流と同じ） |
| `PIX_DT295_XFERS` | 32 | 同時に投げる USB 転送数（パッチ。上流は 8） |
| `PIX_DT295_MIN_GAP` | 2.0 | 選局と選局（停止）の最小間隔（秒）。選局処理中にチューナーを止めると pixd が落ちるため |

クライアント（環境変数または `client/tv.conf`）

| 変数 | 既定 | 内容 |
|---|---|---|
| `TV_MIRAKC_URL` | `http://localhost:40772` | mirakc の URL |
| `TV_REC_DIR` | `~/Movies`（無ければホーム） | 録画の保存先 |
| `TV_WATCHDOG_SEC` | 12 | 映像が出ないとき選局し直すまでの秒数 |
| `TV_GEOMETRY` | `70%x63%+50%+50%` | mpv の初期ウィンドウ（mpv の `--geometry` 書式）。画面の幅 70%・高さ 63% で中央に置く（16:10 の画面でちょうど 16:9） |

## 独自パッチ（server/dt295-xfer.patch）

イメージのビルド時に次の変更を pix-userland に当てます。

1. **番組表取得中は USB 転送を小さくする**
   DT295 はバルク転送をバッファが満杯になるまで返しません。番組表（PSI）だけを通している取得中は
   データが少なく、64 KiB の転送が埋まるまで約 10 秒待たされていました（上流のままだと選局に約 13 秒）。
   取得中だけ転送サイズを小さくし（`PIX_DT295_ACQ_XFER_BYTES`）、受信開始時に元のサイズへ戻します。
2. **地デジは PMT がそろってから受信を始める**
   上流 a31a43e 以降は CAT が先に届くと途中の段取りのまま受信を始めますが、その状態では TS が出ず、
   止めたときに pixd が落ちる局がありました（T17 で確認）。a31a43e より前の動作に戻しています。
3. **受信していない間もセッションを更新する**
   DT295 のセッションは 30 秒ごとに更新（チャレンジ応答）が必要ですが、上流は受信中にしか更新しません。
   そのため 1〜2 分選局しないとセッションが失効し、次の選局でカード初期化に失敗して（`NO_CARD`）、
   USB を挿し直すまで使えなくなっていました。pixd に、受信していない間も更新を続けるスレッドを追加しています。
4. **診断用のログ**（`pix-dt295-mirakc:` で始まる行）を pixd に追加。選局の各段階の時刻と、boot・カード初期化が失敗したときの理由を出します。
5. **BS で電波をつかめなくても固まらないようにする**
   上流は失敗するとどんな理由でも DT295 のコンテキストを使えなくするため、BS のロック待ちがタイムアウトしただけで
   以後の選局（地デジも）がすべて失敗し、USB を挿し直すまで戻りませんでした。ロック待ちのタイムアウトだけは使える状態のまま返します。

実測: 選局 → 受信開始 約 1.5 秒（PSI がそろうまで）。mirakc 経由でクライアントに映像が出るまで約 2〜3 秒。

## 受信ラッパー（server/pix-dt295-tuner）

mirakc は受信コマンドを止めるとき SIGKILL を送ります。pix-ts がそのまま出力先を失うと異常終了し、
チューナーが中途半端な状態で残るため、ラッパーで次のように扱います。

- pix-ts の出力は、下流が閉じても読み捨てを続ける中継を通す
- 見張りプロセスがラッパーの消滅を検知し、pix-ts を SIGTERM で正常に止める
- 選局から `PIX_DT295_MIN_GAP` 秒は止めない。次の選局は前の後片付けが終わるまで待つ

## トラブルシューティング

- **選局できない（mirakc が 404、ログに `NO_CARD` / `USB_IO`）**
  チューナーが中途半端な状態で残っています。**USB を挿し直して** から `docker compose restart` してください。
  DT295 は前のセッションの状態を持ったまま残るため、コンテナの再起動・USB のリセットでは直らず、電源を切る必要があります。
  原因は `docker compose exec mirakc grep -E 'failed|POLL' /var/log/pix/pixd.log` で確認できます。
- **`B-CAS: present=unknown`**
  表示上は不明でも受信できます。`NO_CARD` が続く場合はカードの向き・挿し込みを確認。
- **特定の局だけ映らない（「受信できません」）**
  チューナーが電波を掴めていません（ドライバはロック確認をしないため、データが来ないまま待ちます）。
  アンテナ・ケーブル・分配器・ブースターを確認してください。
  深夜・早朝は送信所のメンテナンスで停波していることがあるので、時間をおいて再確認してください。
- **PIX-DT295 が見つからない**（コンテナがすぐ終了する）
  ホストで `lsusb` などに `06b8:103b` が出ているか、`/dev/bus/usb` を渡せているか確認してください。

## ファイル

| ファイル | 内容 |
|---|---|
| `server/Dockerfile` | pix-userland のビルド（パッチ適用込み）と mirakc イメージへの組み込み |
| `server/compose.yaml` | コンテナの設定（USB・ポート・ボリューム・環境変数） |
| `server/config.example.yml` | mirakc の設定のひな形（`config.yml` にコピーして使う） |
| `server/entrypoint.sh` | pixd を常駐させてから mirakc を起動 |
| `server/pix-dt295-tuner` | mirakc の受信コマンド（上記のラッパー） |
| `server/pix-dt295-scan` | 受信できるチャンネルを調べて `channels` 設定を出力 |
| `server/deploy.sh` | ssh 先へ転送して `docker compose up -d --build` |
| `server/dt295-xfer.patch` | pix-userland への独自パッチ |
| `client/tv.sh` | 視聴・録画・局一覧 |
| `client/tv.lua` | mpv 用の局切替スクリプト（tv.sh が読み込ませる） |

## 既知の制約

- 同時受信は 1 系統のみ（地デジと BS/CS は排他）。視聴中に別の局を選ぶと、mirakc はそれまでの受信を止めて切り替えます。
- LNB 給電非対応（BS/CS アンテナへの給電は外部機器で）。CS は未対応（上流で録画が止まる制限があります）。
- 字幕・データ放送は `client/tv.sh` では未対応。番組表（EPG）は mirakc が取得しますが、`client/tv.sh` では表示しません
  （EPGStation などを使ってください）。

## ライセンス

- スクリプト類（`server/` `client/` のスクリプト・設定）: MIT License（`LICENSE`）
- `server/dt295-xfer.patch`: pix-userland の改変のため GPL-2.0-or-later
- pix-userland 本体・ファームウェア・mirakc は本リポジトリに含まれません（イメージのビルド時に上流から取得します）。それぞれのライセンスに従ってください。
