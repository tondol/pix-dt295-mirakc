#!/bin/bash
# PIX-DT295 を macOS で使うための pix-userland セットアップ
#   - Homebrew で cmake / libusb / pkg-config / mpv を入れる
#   - pix-userland を取得し、ファームウェア埋め込みでビルドする
#   - 接続中のチューナーを一覧表示する
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_URL="https://github.com/Khronos31/pix-userland.git"
REPO_DIR="$DIR/pix-userland"
PIN_COMMIT="38ef18e"   # 2026-11-02 時点の main（地デジの CAT 待ち廃止を含む。動作確認済みビルド）

# --- Homebrew を探す（~/.homebrew にも対応） ---
BREW=""
for c in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew "$HOME/.homebrew/bin/brew" /usr/local/bin/brew; do
  if [ -n "$c" ] && [ -x "$c" ]; then BREW="$c"; break; fi
done
if [ -z "$BREW" ]; then
  echo "Homebrew が見つかりません。https://brew.sh から入れてから再実行してください。" >&2
  exit 1
fi
eval "$("$BREW" shellenv)"
echo "==> brew: $BREW"

echo "==> 依存パッケージをインストール (cmake libusb pkg-config mpv)"
"$BREW" install cmake libusb pkg-config mpv

# --- ソース取得 ---
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "==> pix-userland を取得"
  git clone "$REPO_URL" "$REPO_DIR"
fi
git -C "$REPO_DIR" fetch --quiet origin
# 以前当てたパッチを戻してから固定コミットへ
git -C "$REPO_DIR" checkout --quiet -- include/dt295_stream.h src/dt295_stream.c src/dt295_routes.c pix-dt295-receiver-adapter.cpp 2>/dev/null || true
git -C "$REPO_DIR" checkout --quiet "$PIN_COMMIT"
echo "==> commit: $(git -C "$REPO_DIR" log --oneline -1)"

# --- pix-tv 独自パッチ（USB 転送サイズを環境変数で変えられるようにする） ---
PATCH="$DIR/dt295-xfer.patch"
if [ -f "$PATCH" ]; then
  echo "==> パッチ適用: $(basename "$PATCH")"
  git -C "$REPO_DIR" apply "$PATCH"
fi

# --- ビルド（DT181/DT295 のファームウェアを pixd に埋め込む） ---
echo "==> ビルド"
cmake -S "$REPO_DIR/core-integration" -B "$REPO_DIR/build/cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DPIX_EMBEDDED_ASSETS=ON \
  -DPIX_DT181_FIRMWARE_FILE="$REPO_DIR/firmware/dt181.bin" \
  -DPIX_DT295_FIRMWARE_FILE="$REPO_DIR/firmware/dt295.bin"
# テスト用ターゲットは macOS でビルドできないものがあるので、本体3コマンドだけをビルド
cmake --build "$REPO_DIR/build/cmake" --target pixd pixctl pix-ts --parallel "$(sysctl -n hw.ncpu)"

BIN="$REPO_DIR/build/cmake"
echo
echo "==> ビルド完了: $BIN/{pixd,pixctl,pix-ts}"
echo "==> 接続中のチューナー:"
"$BIN/pixd" --list-json | python3 -m json.tool
echo
echo "次は  ./tv.sh scan  で受信できる地デジのチャンネルを探してください。"
