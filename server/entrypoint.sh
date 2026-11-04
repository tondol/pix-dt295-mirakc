#!/bin/bash
# コンテナの起動: pixd をバックグラウンドで常駐させてから mirakc を起動する。
# 止めるとき（SIGTERM）は mirakc → 受信の後片付け → pixd の順に止める。pixd が正常に終了しないと
# DT295 が認証済みのセッションを持ったまま残り、次の pixd が boot できず USB の挿し直しが必要になる。
set -u
R="${PIX_RUNTIME_DIR:-/run/pix}"
INSTANCE="${PIX_INSTANCE:-tv}"
LOGDIR="${PIX_LOG_DIR:-/var/log/pix}"
mkdir -p "$R" "$LOGDIR"
chmod 700 "$R"   # pixd/pix-ts は runtime ディレクトリが本人以外に開いていると拒否する
rm -f "$R/last-tune" "$R/stopping" "$R/pixd.pid"   # restart では /run/pix が残る

stamp() { while IFS= read -r l; do echo "$(date '+%F %T.%3N') $l"; done; }

# USB の位置（例: 1-1）は挿す口で変わるので起動のたびに調べる
PORT="$(pixd --list-json | grep -o '"port":"[^"]*"' | head -n 1 | cut -d'"' -f4)"
if [ -z "$PORT" ]; then
  echo "PIX-DT295 が見つかりません:" >&2; pixd --list-json >&2; exit 1
fi
echo "PIX-DT295: usb:$PORT" >&2

LOGSTART="$(cat "$LOGDIR/pixd.log" 2>/dev/null | wc -l)"
# pixd が落ちたら作り直す（落ちた後は USB の挿し直しが必要なことが多い）。停止中は作り直さない
(
  while [ ! -f "$R/stopping" ]; do
    pixd --device "usb:$PORT" --firmware /usr/local/share/pix/dt295.bin --instance "$INSTANCE" --runtime-dir "$R" \
      2> >(stamp | tee -a "$LOGDIR/pixd.log" >&2) &
    echo $! >"$R/pixd.pid"
    wait $!
    [ -f "$R/stopping" ] && break
    echo "pixd が終了しました。5 秒後に再起動します（直らなければ USB を挿し直してください）" >&2
    sleep 5
  done
) &

# ログはボリュームに残るので、今回の起動より後の行だけを見て pixd の準備完了を待つ
for _ in $(seq 100); do tail -n "+$((LOGSTART + 1))" "$LOGDIR/pixd.log" 2>/dev/null | grep -q 'pixd ready' && break; sleep 0.1; done

shutdown() {
  trap '' TERM INT
  echo "停止します: mirakc → 受信の後片付け → pixd" >&2
  touch "$R/stopping"
  kill -TERM "$MIRAKC_PID" 2>/dev/null
  wait "$MIRAKC_PID" 2>/dev/null
  # 受信ラッパー（の見張り）が pix-ts を止め終わるとロックが空く
  flock -w 10 "$R/tuner.lock" true
  if [ -f "$R/pixd.pid" ]; then
    pid="$(cat "$R/pixd.pid")"
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && echo "pixd が止まりません（次回は USB の挿し直しが必要かもしれません）" >&2
  fi
  echo "停止しました" >&2
  exit "${1:-0}"
}
trap shutdown TERM INT

/usr/local/bin/mirakc "$@" &
MIRAKC_PID=$!
wait "$MIRAKC_PID"
rc=$?
# mirakc が自分で終了した場合も pixd を正常に止める（シグナルで抜けた場合は trap が先に動く）
shutdown "$rc"
