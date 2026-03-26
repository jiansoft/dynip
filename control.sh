#!/bin/bash

# ==============================================================================
# Stock Zig Control Script
# 只保留 Docker 部署模式
# ==============================================================================

set -e

# `script_dir` 是這支 `control.sh` 自己所在的資料夾。
# 之後其他路徑都會以這個資料夾當基準來組。
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export script_dir

# `docker_binary_name` 是 production 環境實際放在 `control.sh` 同層的檔名。
# 這支腳本現在不負責編譯 binary，
# 而是假設同層已經有這個檔案可以直接拿來做 Docker build。
export docker_binary_name="dynip_linux_arm64"

# Docker image 的名稱。
export docker_image_name="dynip-image"

# Docker container 的名稱。
export docker_container_name="dynip-container"

log() {
  # log 一律走 stderr，避免在 `$(docker_prepare_binary)` 這種 command substitution 裡，
  # 把日誌文字混進真正要回傳的檔案路徑。
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

docker_prepare_binary() {
  local docker_bin_path="${DOCKER_BIN_FILE:-$script_dir/$docker_binary_name}"

  if [ -n "${DOCKER_BIN_FILE:-}" ]; then
    if [ ! -f "$docker_bin_path" ]; then
      log "找不到 DOCKER_BIN_FILE 指定的 binary: $docker_bin_path"
      return 1
    fi

    printf '%s\n' "$docker_bin_path"
    return
  fi

  if [ ! -f "$docker_bin_path" ]; then
    log "錯誤: 找不到與 control.sh 同層的 binary: $docker_bin_path"
    return 1
  fi

  chmod +x "$docker_bin_path"
  log "使用同層目錄中的 binary: $docker_bin_path"
  printf '%s\n' "$docker_bin_path"
}

docker_build() {
  local docker_bin_path
  docker_bin_path="$(docker_prepare_binary)"
  local docker_bin_relative_path
  docker_bin_relative_path="${docker_bin_path#"$script_dir"/}"

  log "開始建立 Docker 映像檔..."
  cd "$script_dir"
  docker build \
    --build-arg BIN_FILE="$docker_bin_relative_path" \
    -t "$docker_image_name" -f Dockerfile .
  log "清理過期的 Docker 資源..."
  docker system prune -f
}

docker_stop() {
  log "停止並移除 Docker 容器..."
  docker rm -f "$docker_container_name" 2>/dev/null || true
  docker ps -a | grep "$docker_container_name" || true
}

docker_start() {
  local docker_log_dir="${DOCKER_LOG_DIR:-$script_dir/log}"

  log "Docker log host path: $docker_log_dir"
  mkdir -p "$docker_log_dir"

  log "啟動 Docker 容器..."
  docker run --name "$docker_container_name" \
    -v="$docker_log_dir:/app/log:rw" \
    -t -d "$docker_image_name"
  docker ps
}

docker_restart() {
  docker_stop
  sleep 1
  docker_start
}

docker_update() {
  docker_build
  docker_restart
}

help() {
  echo "使用方法: $0 {指令}"
  echo "可用指令:"
  echo "  docker_start   - 啟動容器"
  echo "  docker_stop    - 停止並移除容器"
  echo "  docker_restart - 重啟容器"
  echo "  docker_build   - 建立映像檔"
  echo "  docker_update  - 完整更新映像檔並重啟容器"
}

case "$1" in
  docker_build|docker_stop|docker_start|docker_restart|docker_update)
    "$1"
    ;;
  help|--help|-h)
    help
    ;;
  *)
    help
    exit 1
    ;;
esac
