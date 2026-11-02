#!/bin/bash
# server/ を ssh 先へ送り、docker compose で（再）起動する。
#   ./deploy.sh <ssh ホスト> [配置先ディレクトリ]
#   例: ./deploy.sh nas /volume1/docker/pix-dt295-mirakc
# 手元に config.yml があればそれも送る。無ければ ssh 先の config.yml を使う（無ければひな形から作る）。
set -euo pipefail
HOST="${1:?使い方: ./deploy.sh <ssh ホスト> [配置先ディレクトリ]}"
DEST="${2:-pix-dt295-mirakc}"
cd "$(dirname "$0")"

echo "==> $HOST:$DEST へ転送"
FILES="Dockerfile compose.yaml config.example.yml dt295-xfer.patch entrypoint.sh pix-dt295-tuner pix-dt295-scan"
[ -f config.yml ] && FILES="$FILES config.yml"
# shellcheck disable=SC2086
COPYFILE_DISABLE=1 tar czf - $FILES \
  | ssh "$HOST" "mkdir -p '$DEST' && tar xzf - -C '$DEST'"

echo "==> ビルドして起動"
# Synology などは非対話 ssh の PATH に docker が無いので /usr/local/bin を足す
ssh "$HOST" "export PATH=/usr/local/bin:\$PATH; cd '$DEST' \
  && { [ -f config.yml ] || { cp config.example.yml config.yml; echo '    config.yml をひな形から作りました。channels を編集してください'; }; } \
  && docker compose up -d --build"
echo "==> 完了: ssh $HOST 'cd $DEST && docker compose logs -f'"
