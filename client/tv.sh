#!/bin/bash
# mirakc の地デジを mpv で見る・録画する（macOS / Linux。macOS 標準の bash 3.2 でも動くように書く）
#   接続先は PIX_TV_MIRAKC（既定 http://localhost:40772）。client/tv.conf に書いておける。
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$DIR/tv.conf" ] && . "$DIR/tv.conf"
MIRAKC="${PIX_TV_MIRAKC:-http://localhost:40772}"; MIRAKC="${MIRAKC%/}"
GEOMETRY="${PIX_TV_GEOMETRY:-70%x63%+50%+50%}"
WATCHDOG_SEC="${PIX_TV_WATCHDOG_SEC:-12}"
# 録画先（既定は ~/Movies、無ければホーム）
REC_DIR="${PIX_TV_REC_DIR:-$HOME/Movies}"; [ -d "$REC_DIR" ] || REC_DIR="$HOME"

usage() {
  cat <<EOF
使い方: ./tv.sh [コマンド] [局]
  watch [局]          mpv で視聴（コマンド省略時もこれ）。1〜9・↑↓・◀◀▶▶ で切替、l で局リスト、q で終了
  rec <局> [秒]       録画して $REC_DIR に保存（選んだ局のみ）。秒を省略すると Ctrl+C まで
  list                局一覧
  help                このヘルプ
局は リモコン番号（1）・局名の一部（NHK）・サービス ID で指定。
接続先: $MIRAKC（PIX_TV_MIRAKC で変更）
EOF
}

# 局一覧を TSV（番号 \t mirakc のサービス ID \t 局名 \t 物理ch）で出す。$1 があればそれに合う 1 局だけ
stations() {
  python3 - "$MIRAKC" "${1:-}" <<'PY'
import json, sys, unicodedata, urllib.request
base, arg = sys.argv[1], sys.argv[2]
try:
    svcs = json.load(urllib.request.urlopen(base + "/api/services", timeout=5))
except Exception as e:
    sys.exit("mirakc に接続できません（%s）: %s" % (base, e))
norm = lambda s: unicodedata.normalize("NFKC", s)
tv = [s for s in svcs if s.get("type") == 1]
# 物理チャンネルごとに、サービス ID が最小のもの（メインチャンネル）を代表にする
rep = {}
for s in tv:
    k = (s["channel"]["type"], s["channel"]["channel"])
    if k not in rep or s["serviceId"] < rep[k]["serviceId"]:
        rep[k] = s
st = sorted(rep.values(), key=lambda s: (s.get("remoteControlKeyId") or 99, s["serviceId"]))
if arg:
    a = norm(arg).lower()
    hit = [s for s in st if str(s.get("remoteControlKeyId")) == a] \
       or [s for s in tv if a in (str(s["id"]), str(s["serviceId"]))] \
       or [s for s in st if a in norm(s["name"]).lower()] \
       or [s for s in tv if a in norm(s["name"]).lower()]
    if not hit:
        sys.exit("局が見つかりません: %s（./tv.sh list で一覧）" % arg)
    st = hit[:1]
for s in st:
    print("%s\t%d\t%s\t%s" % (s.get("remoteControlKeyId") or "-", s["id"], norm(s["name"]), s["channel"]["channel"]))
PY
}

CMD="${1:-watch}"
case "$CMD" in
  help|-h|--help) usage; exit 0 ;;
  watch|rec|list) shift ;;
  *) CMD=watch ;;   # ./tv.sh nhk のように局だけ指定
esac

case "$CMD" in
  list)
    stations | awk -F'\t' '{printf("  %-3s T%-3s %-11s %s\n", $1, $4, $2, $3)}'
    ;;
  rec)
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    line="$(stations "$1")" || exit 1
    IFS=$'\t' read -r _ ID NAME _ <<<"$line"
    SEC="${2:-}"
    OUT="$REC_DIR/$(date +%Y%m%d-%H%M%S)-$ID.ts"
    echo "==> $NAME を録画中${SEC:+（${SEC}秒）}（Ctrl+C で終了） → $OUT"
    curl -fsS -o "$OUT" ${SEC:+-m "$SEC"} "$MIRAKC/api/services/$ID/stream"
    rc=$?
    [ "$rc" -eq 28 ] && rc=0   # -m の時間切れは正常終了
    ls -l "$OUT"
    exit "$rc"
    ;;
  watch)
    command -v mpv >/dev/null || { echo "mpv が見つかりません。インストールして PATH を通してください" >&2; exit 1; }
    ALL="$(stations)" || exit 1
    START=0
    if [ $# -ge 1 ]; then
      line="$(stations "$1")" || exit 1
      START="$(echo "$ALL" | awk -F'\t' -v id="$(echo "$line" | cut -f2)" '$2==id{print NR-1; exit}')"
      START="${START:-0}"
    fi
    RUNTIME="$(mktemp -d /tmp/pixtv.XXXX)"; trap 'rm -rf "$RUNTIME"' EXIT
    # 局一覧を mpv の Lua スクリプト（tv.lua）に JSON で渡す
    echo "$ALL" | python3 -c '
import json, sys
print(json.dumps([dict(zip(("key", "id", "name", "ch"), l.rstrip("\n").split("\t"))) for l in sys.stdin if l.strip()], ensure_ascii=False))
' >"$RUNTIME/stations.json"
    LOGDIR="$DIR/logs"; mkdir -p "$LOGDIR"
    echo "==> $MIRAKC から視聴（ログ: $LOGDIR/mpv.log）"
    # keep-open: 切替中は直前のフレームを表示したまま / auto-window-resize=no: 窓サイズを維持
    # probe-info=nostreams: PMT からストリームが分かれば解析待ちをしない（切替を速くする）
    # OSC の ◀◀ / ▶▶ を局の切替に割り当てる。ボタンを有効にするため loop-playlist=inf
    # really-quiet: 途中から受信するので切替直後は必ずデコードエラーが出る。端末には出さず mpv.log にだけ残す
    mpv --idle=yes --force-window=yes --keep-open=always --loop-playlist=inf \
      --auto-window-resize=no --title='${?media-title:${media-title} - }pix-tv' --geometry="$GEOMETRY" \
      --script="$DIR/tv.lua" \
      --script-opts-append="tv-stations=$RUNTIME/stations.json" \
      --script-opts-append="tv-mirakc=$MIRAKC" \
      --script-opts-append="tv-start=$START" \
      --script-opts-append="tv-watchdog=$WATCHDOG_SEC" \
      --script-opts-append="osc-playlist_prev_mbtn_left_command=script-message tv-step prev" \
      --script-opts-append="osc-playlist_next_mbtn_left_command=script-message tv-step next" \
      --really-quiet --log-file="$LOGDIR/mpv.log" --demuxer-lavf-probe-info=nostreams --demuxer-lavf-format=mpegts \
      --cache=yes --demuxer-max-bytes=64MiB
    ;;
esac
