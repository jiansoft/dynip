# 這個參數讓 `docker build` 可以決定這次要打包哪一個 binary 檔名。
# 如果外部沒有特別指定，就預設使用 production 會放在同層的 `dynip_linux_arm64`。
ARG BIN_FILE=dynip_linux_arm64

# 第一階段：準備 runtime 需要的系統檔案。
# 我們只借用 Debian 把 CA 憑證與時區資料裝好，
# 最後真正的執行映像不會保留 apt。
FROM debian:13-slim AS runtime-assets

# 安裝 HTTPS 連線需要的 CA 憑證，以及台北時區資料。
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/*

# 第二階段：單純把外部提供的已編譯 binary 收進來。
# 這個階段不做編譯，只負責把 `BIN_FILE` 複製成 `/dynip`。
FROM scratch AS binary
ARG BIN_FILE
COPY ${BIN_FILE} /dynip

# 最終階段：使用 distroless 非 root 映像，讓容器更小也更安全。
FROM gcr.io/distroless/static-debian13:nonroot

# 設定程式執行時的時區與憑證位置。
ENV TZ=Asia/Taipei
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
# 之後程式的相對路徑，例如 `log/`、`.env`、`app.json`，
# 都會以 `/app` 當作目前工作目錄。
WORKDIR /app

# 從第一階段複製 CA 憑證與時區資料到最終映像。
COPY --from=runtime-assets /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=runtime-assets /usr/share/zoneinfo/Asia/Taipei /usr/share/zoneinfo/Asia/Taipei
# 從第二階段複製已編譯好的 `dynip` binary。
# 這裡順便把檔案 owner 設成 65532:65532，並給執行權限。
COPY --from=binary --chown=65532:65532 --chmod=755 /dynip /app/dynip
# 把執行時需要的設定檔一起放進容器。
COPY --chown=65532:65532 ./.env /app/.env
COPY --chown=65532:65532 ./app.json /app/app.json

# 最終容器一律用非 root 身分執行。
USER 65532:65532

# 容器啟動後直接執行 `dynip service --config app.json`。
ENTRYPOINT ["/app/dynip", "service", "--config", "app.json"]
