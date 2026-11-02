# mirakc + pix-userland（dt295-xfer.patch 適用）+ 受信ラッパー
# ビルドコンテキストはこの server/ ディレクトリ

# --- pix-userland を Linux でビルド ---
FROM debian:bookworm-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake pkg-config libusb-1.0-0-dev git ca-certificates python3 \
 && rm -rf /var/lib/apt/lists/*
# 上流を更新するときはここを書き換え、dt295-xfer.patch が当たるか確認する
ARG PIX_COMMIT=38ef18e
RUN git clone https://github.com/Khronos31/pix-userland.git /src && git -C /src checkout --quiet "$PIX_COMMIT"
COPY dt295-xfer.patch /tmp/dt295-xfer.patch
RUN git -C /src apply /tmp/dt295-xfer.patch
RUN cmake -S /src/core-integration -B /build -DCMAKE_BUILD_TYPE=Release \
      -DPIX_EMBEDDED_ASSETS=ON \
      -DPIX_DT181_FIRMWARE_FILE=/src/firmware/dt181.bin \
      -DPIX_DT295_FIRMWARE_FILE=/src/firmware/dt295.bin \
 && cmake --build /build --target pixd pixctl pix-ts --parallel "$(nproc)" \
 && mkdir -p /out && cp /build/pixd /build/pixctl /build/pix-ts /out/

# --- mirakc に載せる ---
FROM mirakc/mirakc:debian
RUN apt-get update \
 && apt-get install -y --no-install-recommends libusb-1.0-0 bash procps \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /usr/local/bin/
COPY entrypoint.sh pix-dt295-tuner pix-dt295-scan /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
