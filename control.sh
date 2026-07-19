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

# Dockerfile 現在會依照 TARGETARCH / TARGETVARIANT 自動選用對應的 binary，
# 所以這兩個檔名都要放在 `control.sh` 同層，讓 Docker build context 可以找到。
# 這支腳本不負責編譯 binary，而是假設同層已經有這些檔案可以直接拿來做 Docker build。
export docker_binary_names=("dynip_linux_arm64" "dynip_linux_armv7")

# Docker image 的名稱。
export docker_image_name="dynip-image"

# Docker container 的名稱。
export docker_container_name="dynip-container"

# 一般模式（不透過 Docker，直接在 host 上執行 binary）用來記錄目前
# 背景執行中程序的 pid，`stop`/`restart` 靠這個檔案找到程序。
export general_pid_file="$script_dir/dynip.pid"

# 一般模式下 binary 自己的 stdout/stderr 導向的檔案。
# 注意：程式本身的日誌另外寫在 `log/*.log`（見 src/io/logging.zig），
# 這裡只是保留 panic 或啟動失敗時來不及進 logger 的輸出。
export general_stdout_log="$script_dir/log/general_stdout.log"

log() {
  # log 一律走 stderr，避免在 `$(docker_prepare_binary)` 這種 command substitution 裡，
  # 把日誌文字混進真正要回傳的檔案路徑。
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

docker_prepare_binary() {
  local name docker_bin_path
  for name in "${docker_binary_names[@]}"; do
    docker_bin_path="$script_dir/$name"
    if [ ! -f "$docker_bin_path" ]; then
      log "錯誤: 找不到與 control.sh 同層的 binary: $docker_bin_path"
      return 1
    fi
    chmod +x "$docker_bin_path"
    log "使用同層目錄中的 binary: $docker_bin_path"
  done
}

docker_build() {
  docker_prepare_binary

  log "開始建立 Docker 映像檔..."
  cd "$script_dir"
  docker build \
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
  local dashboard_host_port="${DASHBOARD_HOST_PORT:-9003}"
  local dashboard_container_port="${DASHBOARD_PORT:-9003}"
  local dashboard_host="${DASHBOARD_HOST:-0.0.0.0}"

  log "Docker log host path: $docker_log_dir"
  log "Dashboard port mapping: ${dashboard_host_port}:${dashboard_container_port}"
  mkdir -p "$docker_log_dir"

  log "啟動 Docker 容器..."
  docker run --name "$docker_container_name" \
    -v="$docker_log_dir:/app/log:rw" \
    -e "DASHBOARD_HOST=$dashboard_host" \
    -e "DASHBOARD_PORT=$dashboard_container_port" \
    -p "${dashboard_host_port}:${dashboard_container_port}" \
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

# 依 `uname -m` 判斷這台機器該用哪一份 binary。
# 對應 build.ps1 產出的檔名：dynip_linux_arm64 / dynip_linux_armv7。
general_detect_binary_name() {
  case "$(uname -m)" in
    aarch64) echo "dynip_linux_arm64" ;;
    armv7l) echo "dynip_linux_armv7" ;;
    *)
      log "錯誤: 不支援的架構: $(uname -m)"
      return 1
      ;;
  esac
}

start() {
  # pid file 存在且該 pid 還活著，代表服務已經在跑，不用重複啟動。
  if [ -f "$general_pid_file" ] && kill -0 "$(cat "$general_pid_file")" 2>/dev/null; then
    log "服務已在執行中 (pid $(cat "$general_pid_file"))"
    return 0
  fi

  local bin_name bin_path
  bin_name="$(general_detect_binary_name)"
  bin_path="$script_dir/$bin_name"
  if [ ! -f "$bin_path" ]; then
    log "錯誤: 找不到與 control.sh 同層的 binary: $bin_path"
    return 1
  fi
  chmod +x "$bin_path"
  mkdir -p "$script_dir/log"

  log "啟動服務（背景執行，登出後不會中止）: $bin_path"
  cd "$script_dir"
  # `nohup` 讓程序忽略登出時的 SIGHUP；`</dev/null` 避免它嘗試讀取已經消失的終端機輸入；
  # `disown` 把它從目前 shell 的 job table 移除，雙重保險避免登出時被牽連關閉。
  nohup "$bin_path" service --config app.json >>"$general_stdout_log" 2>&1 </dev/null &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  echo "$pid" > "$general_pid_file"
  log "已啟動，pid=$pid"
}

stop() {
  if [ ! -f "$general_pid_file" ]; then
    log "找不到 pid file，服務可能未啟動"
    return 0
  fi

  local pid
  pid="$(cat "$general_pid_file")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    log "已送出停止訊號給 pid $pid"
  else
    log "pid $pid 已經不存在，可能是上次未正常關閉"
  fi
  rm -f "$general_pid_file"
}

restart() {
  stop
  sleep 1
  start
}

update() {
  log "更新服務：重新檢查 binary 權限並重啟..."
  restart
}

help() {
  echo "使用方法: $0 {指令}"
  echo "可用指令 (Docker 模式):"
  echo "  docker_start   - 啟動容器"
  echo "  docker_stop    - 停止並移除容器"
  echo "  docker_restart - 重啟容器"
  echo "  docker_build   - 建立映像檔"
  echo "  docker_update  - 完整更新映像檔並重啟容器"
  echo
  echo "可用指令 (一般模式，直接在 host 上背景執行 binary):"
  echo "  start          - 依 uname -m 選擇對應 binary 並在背景啟動（nohup，登出不中止）"
  echo "  stop           - 依 pid file 停止背景執行中的服務"
  echo "  restart        - stop 後再 start"
  echo "  update         - 重新檢查 binary 權限並 restart"
  echo
  echo "Dashboard 環境變數:"
  echo "  DASHBOARD_HOST_PORT - host 對外 port，預設 9003"
  echo "  DASHBOARD_PORT      - container 內 Dashboard port，預設 9003"
  echo "  DASHBOARD_HOST      - container 內綁定位址，預設 0.0.0.0"
}

case "$1" in
  docker_build|docker_stop|docker_start|docker_restart|docker_update|start|stop|restart|update)
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
