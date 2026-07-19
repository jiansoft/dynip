# 第一階段：把 arm64 / armv7 兩個平台的已編譯 binary 都收進來，
# 再依照 BuildKit 自動注入的 TARGETARCH / TARGETVARIANT 選出符合目前建置目標的那一個。
#
# - linux/arm64  → TARGETARCH=arm64（TARGETVARIANT 通常為空）
# - linux/arm/v7 → TARGETARCH=arm，TARGETVARIANT=v7（Raspberry Pi 3 的 armv7l）
#
# 不需要手動指定 --build-arg：不論是在 Pi 上直接 `docker build`，
# 還是用 `docker buildx build --platform linux/arm64,linux/arm/v7` 跨平台建置，
# BuildKit 都會依目標平台自動帶入這兩個值。
# 這個階段需要 shell 才能做條件判斷，所以不能用 `scratch`，
# 但最終產物只有 `/dynip` 這個檔案會被下一階段複製出去，不會影響最終 image 大小。
FROM alpine:3 AS binary
ARG TARGETARCH
ARG TARGETVARIANT
COPY dynip_linux_arm64 /src/dynip_linux_arm64
COPY dynip_linux_armv7 /src/dynip_linux_armv7
RUN set -eu; \
    case "${TARGETARCH}-${TARGETVARIANT}" in \
      arm64-*) cp /src/dynip_linux_arm64 /dynip ;; \
      arm-v7) cp /src/dynip_linux_armv7 /dynip ;; \
      *) echo "不支援的平台: TARGETARCH=${TARGETARCH} TARGETVARIANT=${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    chmod 755 /dynip

# 最終階段：使用 distroless 非 root 映像，讓容器更小也更安全。
# `static` 系列映像本身已內建：
# - `/etc/ssl/certs/ca-certificates.crt`（HTTPS 連線需要的 CA 憑證）
# - `/usr/share/zoneinfo/`（完整時區資料，含 Asia/Taipei）
# - `nonroot` 使用者（UID 65532）
# 所以不需要再借 Debian 裝這些檔案。
FROM gcr.io/distroless/static-debian13:nonroot

# 設定程式執行時的時區與憑證位置。
ENV TZ=Asia/Taipei
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
# 之後程式的相對路徑，例如 `log/`、`.env`、`app.json`，
# 都會以 `/app` 當作目前工作目錄。
WORKDIR /app

# 從第一階段複製已編譯好的 `dynip` binary。
# 這裡順便把檔案 owner 設成 65532:65532，並給執行權限。
COPY --from=binary --chown=65532:65532 --chmod=755 /dynip /app/dynip
# 把執行時需要的設定檔一起放進容器。
COPY --chown=65532:65532 ./.env /app/.env
COPY --chown=65532:65532 ./app.json /app/app.json

# 最終容器一律用非 root 身分執行。
USER 65532:65532

# Dashboard HTTP server 預設監聽 9003；實際 port 仍可由 app.json 或
# DASHBOARD_PORT 環境變數控制。
EXPOSE 9003

# 容器啟動後直接執行 `dynip service --config app.json`。
ENTRYPOINT ["/app/dynip", "service", "--config", "app.json"]
