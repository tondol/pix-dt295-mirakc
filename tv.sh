#!/bin/bash
# PIX-DT295 で地デジを見る（pix-userland + mpv）。使い方は ./tv.sh help
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/pix-userland/build/cmake"
INSTANCE="tv"
# mpv の初期ウィンドウ: 画面の幅 70%・高さ 63%（16:10 の MacBook でちょうど 16:9）、画面中央。mpv の --geometry 書式
MPV_GEOMETRY="${PIX_TV_GEOMETRY:-70%x63%+50%+50%}"
# USB 受信の転送サイズ（dt295-xfer.patch 適用時に有効）。番組表取得中だけ小さい転送にして選局を速くする
export PIX_DT295_ACQ_XFER_BYTES="${PIX_DT295_ACQ_XFER_BYTES:-2048}"
export PIX_DT295_XFERS="${PIX_DT295_XFERS:-32}"
for p in /opt/homebrew/bin "$HOME/.homebrew/bin" /usr/local/bin; do
  [ -d "$p" ] && PATH="$p:$PATH"
done

# 局一覧: キー  リモコン番号  物理ch  サービスID(空=先頭の番組)  表示名
STATIONS="
nhk     1  T20  35840  NHK総合・静岡
etv     2  T13  35848  NHKEテレ・静岡
tvk     3  T26  24632  tvk
sdt     4  T19  35872  静岡第一テレビ
satv    5  T18  35880  静岡朝日テレビ
sbs     6  T15  35856  SBS静岡放送
tx      7  T23  1072   テレ東
sut     8  T17  35864  テレビ静岡
"
usage() {
  cat <<'EOF'
使い方: ./tv.sh [コマンド] [引数]

  watch [局]          テレビモード（コマンド省略時もこれ）。局は キー / リモコン番号 / 物理ch（T20 など）
                      mpv の窓で 1〜8・↑↓・◀◀▶▶ で切替、l で局リスト、q で終了
  rec <局> [秒]       録画して ~/Movies に保存（物理チャンネルの TS 全体）。秒を省略すると Ctrl+C まで
  list                局一覧
  scan                T13〜T52 を走査して受信できる物理チャンネルを表示
  names <ch>...       チャンネルの局名・サービス ID を表示（例: names T13 T20）
  diag <局> [秒]      テスト受信して状態と時刻付きログを表示（調査用、既定 15 秒）
  help                このヘルプ

例: ./tv.sh            ./tv.sh tx           ./tv.sh rec nhk 1800
EOF
}

# lookup ARG → L_KEY L_CH L_SID L_LABEL を設定。ARG は キー / リモコン番号 / 物理ch（T20, 20）
# 物理ch 指定のときは L_SID が空（先頭の番組を再生）。解決できなければ 1 を返す
lookup() {
  local hit a
  a="$(echo "$1" | tr 'A-Z' 'a-z')"
  hit="$(echo "$STATIONS" | awk -v k="$a" 'NF && ($1==k || $2==k){print; exit}')"
  if [ -n "$hit" ]; then
    L_KEY="$(echo "$hit" | awk '{print $1}')"
    L_CH="$(echo "$hit" | awk '{print $3}')"
    L_SID="$(echo "$hit" | awk '{print $4}')"; [ "$L_SID" = "-" ] && L_SID=""
    L_LABEL="$(echo "$hit" | awk '{print $5}')"
    return 0
  fi
  if [[ "$a" =~ ^t?([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -ge 13 ] && [ "${BASH_REMATCH[1]}" -le 62 ]; then
    L_KEY="T${BASH_REMATCH[1]}"; L_CH="$L_KEY"; L_SID=""; L_LABEL="$L_KEY"
    return 0
  fi
  return 1
}
STATION_KEYS="$(echo "$STATIONS" | awk 'NF{print $1}')"

# --- サブコマンドの決定（局名などだけ渡されたら watch とみなす） ---
CMD_NAME="${1:-watch}"; [ $# -gt 0 ] && shift
case "$CMD_NAME" in
  help|-h|--help) usage; exit 0 ;;
  list)
    echo "キー    No  ch   名前"
    echo "$STATIONS" | awk 'NF{printf "%-7s %-3s %-4s %s\n",$1,$2,$3,$5}'
    exit 0 ;;
  watch|rec|scan|names|diag) ;;
  test) CMD_NAME=diag ;;                      # 旧名
  *)
    if lookup "$CMD_NAME"; then set -- "$CMD_NAME" "$@"; CMD_NAME=watch
    else echo "不明なコマンド: $CMD_NAME" >&2; usage >&2; exit 2; fi ;;
esac
case "$CMD_NAME" in
  rec|diag)
    if [ -z "${1:-}" ] || ! lookup "$1"; then
      echo "局またはチャンネルを指定してください（例: ./tv.sh $CMD_NAME nhk）" >&2; exit 2
    fi ;;
  names) [ $# -gt 0 ] || { echo "例: ./tv.sh names T13 T20" >&2; exit 2; } ;;
esac

if [ ! -x "$BIN/pixd" ]; then
  echo "先に ./setup.sh を実行してください。" >&2
  exit 1
fi

# --- DT295 (06b8:103b) の USB ポートを探す ---
PORT="$("$BIN/pixd" --list-json | python3 -c '
import json, sys
d = json.load(sys.stdin)
devs = [x for e in d.get("enclosures", []) for x in e.get("devices", [])]
devs += d.get("ungrouped_usb_devices", [])
for x in devs:
    if x.get("usb") == "06b8:103b" and x.get("port"):
        print(x["port"]); break
')"
if [ -z "$PORT" ]; then
  echo "PIX-DT295 が見つかりません。USB 接続を確認してください。" >&2
  "$BIN/pixd" --list-json >&2
  exit 1
fi
echo "==> PIX-DT295: usb:$PORT"

# --- pixd を起動（ソケットパス長制限があるので /tmp 直下の短いパス） ---
RUNTIME="$(mktemp -d /tmp/pixtv.XXXX)"
# pixd のログには UNIX 時刻（秒）を付ける
"$BIN/pixd" --device "usb:$PORT" --instance "$INSTANCE" --runtime-dir "$RUNTIME" \
  2> >(perl -MTime::HiRes=time -ne 'BEGIN{$|=1} printf("%.2f %s", time, $_)' >"$RUNTIME/pixd.log") &
PIXD_PID=$!
# PID が終わるのを最大 $2 秒待つ（終われば 0）
wait_pid() {
  local i
  for i in $(seq 1 $(( $2 * 10 ))); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}
stop_ts() {
  [ -f "$RUNTIME/ts.pid" ] || return 0
  local p; p="$(cat "$RUNTIME/ts.pid")"; rm -f "$RUNTIME/ts.pid"
  kill -0 "$p" 2>/dev/null || return 0
  [ "${1:-}" = quiet ] || echo "==> 受信を停止中 (pix-ts pid=$p)"
  kill -TERM "$p" 2>/dev/null
  if ! wait_pid "$p" 15; then
    echo "    15秒で止まらないので強制終了します" >&2
    kill -KILL "$p" 2>/dev/null
  fi
}
MPV_PID=""; FF_PID=""
cleanup() {
  trap - EXIT INT TERM
  exec 7>&-
  [ -n "$FF_PID" ] && kill "$FF_PID" 2>/dev/null
  [ -n "$MPV_PID" ] && kill "$MPV_PID" 2>/dev/null
  stop_ts
  if kill -0 "$PIXD_PID" 2>/dev/null; then
    echo "==> pixd を停止中"
    kill -TERM "$PIXD_PID" 2>/dev/null
    if ! wait_pid "$PIXD_PID" 15; then
      echo "    pixd が止まらないので強制終了します（次回はUSBを挿し直してください）" >&2
      kill -KILL "$PIXD_PID" 2>/dev/null
    fi
  fi
  [ -s "$RUNTIME/pixd.log" ] && { echo "--- pixd log ---"; tail -n 5 "$RUNTIME/pixd.log"; }
  [ -d "$DIR/logs" ] && [ -s "$RUNTIME/pixd.log" ] && cp "$RUNTIME/pixd.log" "$DIR/logs/pixd.log"
  rm -rf "$RUNTIME"
}
trap cleanup EXIT INT TERM

ctl() { "$BIN/pixctl" --runtime-dir "$RUNTIME" --instance "$INSTANCE" "$@"; }
for _ in $(seq 1 30); do
  ctl status >/dev/null 2>&1 && break
  if ! kill -0 "$PIXD_PID" 2>/dev/null; then
    echo "pixd が起動できませんでした:" >&2; cat "$RUNTIME/pixd.log" >&2; exit 1
  fi
  sleep 0.5
done
echo "==> B-CAS: $(ctl card-status 2>&1 | tr '\n' ' ')"

ts() { "$BIN/pix-ts" --runtime-dir "$RUNTIME" --instance "$INSTANCE" "$@"; }

case "$CMD_NAME" in
  scan)
    echo "==> 地デジ T13〜T52 をスキャン（1chあたり約12秒・全体で8分ほど）"
    found=()
    for n in $(seq 13 52); do
      out="$RUNTIME/T$n.ts"
      ts -c "T$n" -t 12 --tune-timeout-ms 4000 -o "$out" 2>"$RUNTIME/T$n.log"
      rc=$?
      size=$( (wc -c <"$out" 2>/dev/null || echo 0) | tr -d ' ')
      if [ "$rc" -eq 0 ] && [ "${size:-0}" -gt 0 ]; then
        printf "  T%-3s OK  (%s bytes)\n" "$n" "$size"; found+=("T$n")
      else
        printf "  T%-3s --  (rc=%s, %s bytes) %s\n" "$n" "$rc" "${size:-0}" "$(tail -n 1 "$RUNTIME/T$n.log" 2>/dev/null)"
      fi
      rm -f "$out"
    done
    echo
    echo "==> 受信できたチャンネル: ${found[*]:-なし}"
    [ ${#found[@]} -gt 0 ] && echo "    例: ./tv.sh ${found[0]}"
    ;;
  diag)
    lookup "$1"; CH="$L_CH"; SEC="${2:-15}"
    echo "==> $L_LABEL ($CH) を ${SEC}秒テスト受信（0.5秒ごとに状態を表示）"
    T0=$(python3 -c 'import time;print(time.time())')
    ts -c "$CH" -t "$SEC" -o "$RUNTIME/test.ts" 2>"$RUNTIME/test.log" &
    TS_PID=$!
    last=""
    while kill -0 "$TS_PID" 2>/dev/null; do
      line="$(ctl status 2>/dev/null | python3 -c '
import json,sys,os,time
t0=float(sys.argv[1]); f=sys.argv[2]
try:
    r=json.load(sys.stdin)["receivers"][0]
    st="%s/%s tune=%s" % (r.get("state"), r.get("operation"), "yes" if r.get("current_tune") else "no")
except Exception as e:
    st="status?"
sz=os.path.getsize(f) if os.path.exists(f) else 0
print("%5.1fs %s size=%d" % (time.time()-t0, st, sz))
' "$T0" "$RUNTIME/test.ts")"
      key="${line#* }"; key="${key% size=*}$( [ "${line##*size=}" = 0 ] && echo 0 || echo 1)"
      [ "$key" != "$last" ] && echo "  $line"; last="$key"
      sleep 0.5
    done
    wait "$TS_PID"; rc=$?
    cat "$RUNTIME/test.log"
    echo "rc=$rc  size=$(wc -c <"$RUNTIME/test.ts" 2>/dev/null | tr -d ' ') bytes"
    echo "--- pixd log（受信開始からの秒数）---"
    perl -ne 'if(/^([\d.]+) (.*)/){printf("  %5.1fs %s\n",$1-'"$T0"',$2)}' "$RUNTIME/pixd.log"
    ;;
  names)
    VENV="$DIR/.venv"
    if [ ! -x "$VENV/bin/python" ]; then
      echo "==> 局名デコード用の ariblib を準備"
      python3 -m venv "$VENV" && "$VENV/bin/pip" -q install ariblib || exit 1
    fi
    for CH in "$@"; do
      out="$RUNTIME/$CH.ts"
      ts -c "$CH" -t 12 --tune-timeout-ms 4000 -o "$out" 2>/dev/null
      echo "== $CH"
      "$VENV/bin/python" "$DIR/sdt_names.py" "$out"
      rm -f "$out"
    done
    ;;
  rec)
    lookup "$1"; CH="$L_CH"; SEC="${2:-}"
    OUT="$HOME/Movies/$(date +%Y%m%d-%H%M%S)-$L_KEY.ts"
    if [ -n "$SEC" ]; then
      echo "==> $L_LABEL ($CH) を ${SEC}秒録画 → $OUT"
      ts -c "$CH" -t "$SEC" -o "$OUT"
    else
      echo "==> $L_LABEL ($CH) を録画中（Ctrl+C で終了） → $OUT"
      ts -c "$CH" -o "$OUT"
    fi
    ;;
  watch)
    # mpv は開いたまま、局ごとに pix-ts→ffmpeg を張り替えて loadfile で切り替える
    SOCK="$RUNTIME/mpv.sock"; CMD="$RUNTIME/cmd.fifo"; mkfifo "$CMD"
    exec 3<>"$CMD"   # 先に開いておく（書き手が相手待ちで固まらないように）
    CONF="$RUNTIME/input.conf"
    {
      for k in $STATION_KEYS; do
        lookup "$k"; n="$(echo "$STATIONS" | awk -v k="$k" '$1==k{print $2}')"
        echo "$n run \"/bin/sh\" \"-c\" \"echo $k > '$CMD'\""
      done
      echo "UP run \"/bin/sh\" \"-c\" \"echo prev > '$CMD'\""
      echo "DOWN run \"/bin/sh\" \"-c\" \"echo next > '$CMD'\""
      echo "l run \"/bin/sh\" \"-c\" \"echo list > '$CMD'\""
      echo "q quit"
    } >"$CONF"
    mpv_cmd() {  # mpv_cmd arg1 arg2 ... を JSON IPC で送る
      python3 - "$SOCK" "$@" <<'PY' 2>>"$LOGDIR/ipc.log"
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
cmd = sys.argv[2:]
s.sendall((json.dumps({"command": cmd}) + "\n").encode())
s.settimeout(1)
try: s.recv(4096)
except Exception: pass
s.close()
PY
    }
    osd_list() {  # 全局リストを OSD に出し、$1 の局だけ色を変える（$2 秒で消える）
      local k n name text='{\an7}{\fs28}{\bord2}'
      for k in $STATION_KEYS; do
        n="$(echo "$STATIONS" | awk -v k="$k" '$1==k{print $2}')"
        name="$(echo "$STATIONS" | awk -v k="$k" '$1==k{print $5}')"
        if [ "$k" = "$1" ]; then
          text="$text{\c&H00D7FF&}{\b1}▶ $n  $name{\r}{\fs28}{\bord2}\N"
        else
          text="$text{\alpha&H30&}\h\h\h$n  $name{\r}{\fs28}{\bord2}\N"
        fi
      done
      mpv_cmd script-message tv-osd "$text" "${2:-3}"
    }
    LOGDIR="$DIR/logs"; mkdir -p "$LOGDIR"; rm -f "$LOGDIR"/*.log
    # 局リスト表示用の mpv スクリプト（IPC からの script-message で ASS のオーバーレイを出す）
    cat >"$RUNTIME/tv-osd.lua" <<'LUA'
local ov = mp.create_osd_overlay("ass-events")
ov.res_y = 720
local timer
mp.register_script_message("tv-osd", function(text, dur)
  ov.data = text
  ov:update()
  if timer then timer:kill() end
  timer = mp.add_timeout(tonumber(dur) or 3, function() ov:remove() end)
end)
-- OSC のボタンなどから tv.sh へ切替要求を送る
local cmd = mp.get_opt("tv-osd-cmd")
mp.register_script_message("tv-step", function(dir)
  if not cmd then return end
  local f = io.open(cmd, "w")
  if f then f:write(dir .. "\n"); f:close() end
end)
LUA
    echo "    ログ: $LOGDIR"
    # keep-open: 切替中は直前のフレームを表示したまま / auto-window-resize=no: 窓サイズを維持
    # probe-info=nostreams: PMT からストリームが分かれば解析待ちをしない（切替を速くする）
    # OSC（画面下のコントローラ）の ◀◀ / ▶▶ ボタンを局の切替に割り当てる。
    # ボタンを有効にするため loop-playlist=inf、終端で次を読みに行かないよう keep-open=always
    mpv --idle=yes --force-window=yes --keep-open=always --loop-playlist=inf \
        --auto-window-resize=no --title='${?media-title:${media-title} - }pix-tv' --geometry="$MPV_GEOMETRY" \
        --script-opts-append="tv-osd-cmd=$CMD" \
        --script-opts-append="osc-playlist_prev_mbtn_left_command=script-message tv-step prev" \
        --script-opts-append="osc-playlist_next_mbtn_left_command=script-message tv-step next" \
        --log-file="$LOGDIR/mpv.log" --demuxer-lavf-probe-info=nostreams --script="$RUNTIME/tv-osd.lua" \
        --input-ipc-server="$SOCK" --input-conf="$CONF" \
        --cache=yes --demuxer-max-bytes=64MiB --demuxer-lavf-format=mpegts >/dev/null 2>&1 &
    MPV_PID=$!
    for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done

    CUR=""; GEN=0; TUNE_AT=0; RETRIES=0; LAST_TUNE_HR=""
    MIN_GAP="${PIX_TV_MIN_GAP:-2.0}"
    # 選局後この秒数たっても ffmpeg が出力を始めなければ選局し直す（電波を掴み損ねることがある）
    WATCHDOG_SEC="${PIX_TV_WATCHDOG_SEC:-6}"
    tune_to() {
      lookup "$1" || return
      CUR="$L_KEY"; GEN=$((GEN + 1)); TUNE_AT=$SECONDS
      [ "${2:-}" = retry ] || RETRIES=0
      perl -MTime::HiRes=time -e 'printf("%.2f request %s\n", time, $ARGV[0])' "$L_KEY" >>"$LOGDIR/switch.log"
      osd_list "$L_KEY"
      # 選局処理の最中に止めるとチューナーが固まるので、前の選局から最低 MIN_GAP 秒は空ける
      if [ -n "$LAST_TUNE_HR" ]; then
        perl -MTime::HiRes=time,sleep -e '$w=$ARGV[0]+$ARGV[1]-time; sleep($w) if $w>0' \
          "$LAST_TUNE_HR" "$MIN_GAP"
      fi
      [ -n "$FF_PID" ] && kill "$FF_PID" 2>/dev/null; FF_PID=""
      # 前の出力 FIFO の保持を外す → ffmpeg も居なければ mpv は EOF を受けて解放される
      exec 7>&-
      stop_ts quiet
      echo "==> $L_LABEL ($L_CH / sid=$L_SID)"
      perl -MTime::HiRes=time -e 'printf("%.2f switch %s\n", time, $ARGV[0])' "$L_KEY" >>"$LOGDIR/switch.log"
      local fin="$RUNTIME/in$GEN.fifo" fout="$RUNTIME/out$GEN.fifo"
      rm -f "$RUNTIME"/in*.fifo "$RUNTIME"/out*.fifo; mkfifo "$fin" "$fout"
      # 出力 FIFO をこのシェルが読み書き両用で開いておく。mpv/ffmpeg の open が相手待ちで
      # 固まらず、受信できないときも fd 7 を閉じれば mpv に EOF を渡して解放できる
      exec 7<>"$fout"
      LAST_TUNE_HR="$(perl -MTime::HiRes=time -e 'printf("%.3f", time)')"
      sh -c 'echo $$ >"$1"; shift; exec "$@"' _ "$RUNTIME/ts.pid" \
          "$BIN/pix-ts" --runtime-dir "$RUNTIME" --instance "$INSTANCE" -c "$L_CH" -o - 2>>"$LOGDIR/pix-ts.log" 7>&- \
        | { cat || cat >/dev/null; } >"$fin" 7>&- &
      echo "=== $(date +%T) $L_KEY $L_CH sid=$L_SID" >>"$LOGDIR/ffmpeg.log"
      # サービス ID があればその番組だけ、物理 ch 指定なら先頭の映像・音声を取り出す
      local maps
      if [ -n "$L_SID" ]; then maps="-map 0:p:$L_SID:v:0 -map 0:p:$L_SID:a?"
      else maps="-map 0:v:0 -map 0:a:0?"; fi
      # shellcheck disable=SC2086
      ffmpeg -nostdin -hide_banner -loglevel info -stats_period 5 -probesize 1M -analyzeduration 1M -i "$fin" \
          $maps -c copy -f mpegts -y "$fout" 2>>"$LOGDIR/ffmpeg.log" 7>&- &
      FF_PID=$!
      # 窓タイトル（局名 - pix-tv）。読み込み前に設定して FIFO のファイル名が一瞬出ないようにする
      mpv_cmd set_property force-media-title "$L_LABEL"
      mpv_cmd loadfile "ffmpeg://file:$fout" replace
      mpv_cmd set pause no
      osd_list "$L_KEY" 5   # 新しい映像が出るまで残るよう、読み込み開始後にもう一度出す
    }
    offset_key() {  # offset_key KEY +1/-1 → 隣の局のキー
      local keys n i idx=0
      keys=($STATION_KEYS); n=${#keys[@]}
      for i in "${!keys[@]}"; do [ "${keys[$i]}" = "$1" ] && idx=$i; done
      echo "${keys[$(( (idx + $2 + n) % n ))]}"
    }
    drain_requests() {  # 0.35 秒以内に続けて届いた要求をまとめて取り出す
      perl -MIO::Select -e 'open(my $f, "<&=3") or exit; my $s = IO::Select->new($f); my $buf = "";
        while ($s->can_read(0.35)) { my $n = sysread($f, my $c, 4096); last unless $n; $buf .= $c; }
        print $buf;'
    }

    first="${1:-nhk}"; lookup "$first" || first=nhk
    tune_to "$first"
    echo "    mpv ウィンドウで 1〜8 / ↑↓ で切替、l で局一覧、q で終了"
    while kill -0 "$MPV_PID" 2>/dev/null; do
      if read -r -t 1 -u 3 req; then
        # 連打は最後の結果だけ選局する（↑↑↑ なら 3 つ先）
        target="$CUR"
        for r in $req $(drain_requests); do
          case "$r" in
            list) osd_list "$CUR" 5 ;;
            next) target="$(offset_key "$target" 1)" ;;
            prev) target="$(offset_key "$target" -1)" ;;
            *) lookup "$r" >/dev/null && target="$r" ;;
          esac
        done
        [ "$target" != "$CUR" ] && tune_to "$target"
      elif [ -n "$CUR" ] && [ $((SECONDS - TUNE_AT)) -ge "$WATCHDOG_SEC" ] && [ "$RETRIES" -ge 0 ]; then
        if ! kill -0 "$PIXD_PID" 2>/dev/null; then
          echo "    pixd が停止しました。USB を挿し直してから起動し直してください" >&2
          mpv_cmd show-text "チューナーが停止しました（USB を挿し直してください）" 10000
          sleep 3; break
        elif grep -q "in$GEN.fifo'" "$LOGDIR/ffmpeg.log" 2>/dev/null; then
          RETRIES=-1   # 受信できている
        elif [ "$RETRIES" -lt 3 ]; then
          RETRIES=$((RETRIES + 1))
          echo "    受信が始まらないので選局し直します（${RETRIES}回目）"
          tune_to "$CUR" retry
        else
          RETRIES=-1
          mpv_cmd show-text "受信できません: $L_LABEL" 5000
          echo "    受信できませんでした"
        fi
      fi
    done
    MPV_PID=""
    ;;
esac
