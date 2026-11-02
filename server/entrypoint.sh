#!/bin/bash
# コンテナの起動: pixd をバックグラウンドで常駐させてから mirakc を起動する
set -u
R="${PIX_RUNTIME_DIR:-/run/pix}"
INSTANCE="${PIX_INSTANCE:-tv}"
LOGDIR="${PIX_LOG_DIR:-/var/log/pix}"
mkdir -p "$R" "$LOGDIR"
chmod 700 "$R"   # pixd/pix-ts は runtime ディレクトリが本人以外に開いていると拒否する
rm -f "$R/last-tune"

# USB の位置（例: 1-1）は挿す口で変わるので起動のたびに調べる
PORT="$(pixd --list-json | grep -o '"port":"[^"]*"' | head -n 1 | cut -d'"' -f4)"
if [ -z "$PORT" ]; then
  echo "PIX-DT295 が見つかりません:" >&2; pixd --list-json >&2; exit 1
fi
echo "PIX-DT295: usb:$PORT" >&2

LOGSTART="$(cat "$LOGDIR/pixd.log" 2>/dev/null | wc -l)"
# pixd が落ちたら作り直す（落ちた後は USB の挿し直しが必要なことが多い）
(
  while :; do
    pixd --device "usb:$PORT" --instance "$INSTANCE" --runtime-dir "$R" 2>&1 \
      | while IFS= read -r l; do echo "$(date '+%F %T.%3N') $l"; done | tee -a "$LOGDIR/pixd.log" >&2
    echo "pixd が終了しました。5 秒後に再起動します（直らなければ USB を挿し直してください）" >&2
    sleep 5
  done
) &

# ログはボリュームに残るので、今回の起動より後の行だけを見て pixd の準備完了を待つ
for _ in $(seq 100); do tail -n "+$((LOGSTART + 1))" "$LOGDIR/pixd.log" 2>/dev/null | grep -q 'pixd ready' && break; sleep 0.1; done

exec /usr/local/bin/mirakc "$@"
