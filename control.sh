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

# 開發機交叉編譯好的執行檔上傳到這裡（scp 到 /tmp），`move` 再從這裡搬到 script_dir。
#
# 為什麼不直接 scp 覆蓋執行中的檔案：Linux 會對執行中的檔案回 "Text file busy"
# (ETXTBSY)，覆蓋會失敗。先傳到 /tmp、停掉服務後再搬過去，才是安全的順序。
export upload_dir="${UPLOAD_BIN_DIR:-/tmp}"

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
# 對應 scripts/build.ps1 產出的檔名：dynip_linux_arm64 / dynip_linux_armv7。
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

# 啟動前輪轉 general_stdout.log，避免它無上限成長。
#
# 這個檔收的是程式的 stdout/stderr（下面 nohup 的重導向），內容和 `log/*.log`
# 幾乎重複 —— 程式的 console 輸出與檔案日誌是同一批訊息。差別在於 `log/*.log`
# 由程式自己輪轉與清理，這個檔卻沒有任何人管，只會一直 append。
#
# 只能在啟動前處理：服務跑起來之後，重導向綁的是已開啟的 fd（inode），
# 這裡改名或刪檔都不會讓執行中的程序改寫到新檔。
# 想從源頭少寫一點，請把 `.env` 的 LOG_CONSOLE_LEVEL 調成 warn 或 error。
rotate_stdout_log() {
  local max_mb="${STDOUT_LOG_MAX_SIZE_MB:-10}"
  local keep="${STDOUT_LOG_KEEP:-3}"
  local max_bytes size backup old

  # 0 或負數代表停用這個輪轉。
  [ "$max_mb" -gt 0 ] 2>/dev/null || return 0
  [ -f "$general_stdout_log" ] || return 0

  max_bytes=$((max_mb * 1024 * 1024))
  size="$(stat -c %s "$general_stdout_log" 2>/dev/null || echo 0)"
  [ "$size" -gt "$max_bytes" ] || return 0

  backup="$general_stdout_log.$(date "+%Y%m%d-%H%M%S")"
  mv "$general_stdout_log" "$backup"
  log "general_stdout.log 已達 $((size / 1024 / 1024)) MB，備份為 $(basename "$backup")"

  # 只保留最近 $keep 份備份，其餘刪掉。
  #
  # 依「檔名的時間戳」排序而不是 mtime：備份是用 mv 改名，mtime 保留的是原檔
  # 最後一次寫入的時間，不是備份當下的時間，拿 mtime 排會把剛備份的檔排錯位置。
  # 檔名格式 %Y%m%d-%H%M%S 單調遞增，字典序反排即是由新到舊。
  ls -1 "$general_stdout_log".* 2>/dev/null | sort -r | tail -n "+$((keep + 1))" | while read -r old; do
    rm -f "$old"
    log "已刪除過舊的 stdout 備份: $(basename "$old")"
  done
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
  rotate_stdout_log

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
    wait_for_exit "$pid"
  else
    log "pid $pid 已經不存在，可能是上次未正常關閉"
  fi
  rm -f "$general_pid_file"
}

# 等舊程序真的退出再返回。
#
# 沒有這一步的話，`update` 可能在舊程序還活著時就把新的啟起來變成雙實例，
# 兩個實例會同時更新 DDNS 供應商並互相覆蓋 Redis 狀態。
wait_for_exit() {
  local pid="$1"
  local waited=0
  local limit="${STOP_WAIT_SECONDS:-60}"

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      log "pid $pid 已等待 ${limit}s 仍未結束，請確認後手動處理（kill -9 $pid）"
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
    # 每 10 秒回報一次，讓等待過程看得出還在進行中。
    if [ $((waited % 10)) -eq 0 ]; then
      log "等待 pid $pid 結束中... (${waited}s)"
    fi
  done

  log "pid $pid 已結束（耗時 ${waited}s）"
}

restart() {
  stop
  sleep 1
  start
}

# 把上傳的新執行檔搬到 control.sh 同層並就位。
#
# 來源優先序：
#   1. UPLOAD_BIN_FILE 指定的完整路徑
#   2. 上傳目錄（預設 /tmp）底下的同名檔案 —— 開發機交叉編譯後 scp 到這裡
#
# 刻意不接受 `zig-out/bin/dynip` 這種本機編譯產物：這支腳本不負責在正式環境端
# 編譯，而且那個檔名沒有架構後綴，搬過來等於是「假設」它就是這台機器的架構。
move() {
  local bin_name dest_path src_path backup_name
  bin_name="$(general_detect_binary_name)"
  # 部署到跟 control.sh 同一層，跟 docker_build 及 start() 找執行檔的位置一致。
  dest_path="$script_dir/$bin_name"

  if [ -n "$UPLOAD_BIN_FILE" ]; then
    src_path="$UPLOAD_BIN_FILE"
  elif [ -f "$upload_dir/$bin_name" ]; then
    src_path="$upload_dir/$bin_name"
  else
    log "錯誤: 找不到可部署的執行檔"
    log "請先將交叉編譯好的 $bin_name 上傳到 $upload_dir/（或用 UPLOAD_BIN_FILE 指定路徑）"
    return 1
  fi

  backup_name="$bin_name.$(date "+%Y%m%d-%H%M%S")"

  # 舊檔案存在則備份。先把舊檔改名移走，新檔才是建立全新的 inode，
  # 就算舊程序還沒完全結束也不會踩到 ETXTBSY。
  # 備份檔拿掉執行權限，避免日後誤把舊版本啟起來。
  if [ -f "$dest_path" ]; then
    mv "$dest_path" "$script_dir/$backup_name"
    chmod -x "$script_dir/$backup_name"
    log "舊執行檔已備份為 $backup_name"
  fi

  mv "$src_path" "$dest_path"
  chmod +x "$dest_path"
  log "檔案部署成功: $dest_path（來源 $src_path）"
}

# 完整更新：停止 → 新執行檔就位 → 啟動。
#
# 執行檔在開發機交叉編譯後上傳到 $upload_dir，裝置端不編譯，
# 所以 update 只做「停止 → 就位 → 啟動」。
update() {
  stop
  sleep 1
  move
  sleep 1
  start
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
  echo "  move           - 將上傳的執行檔就位（來源：UPLOAD_BIN_FILE > $upload_dir/）"
  echo "  update         - 完整更新 (stop + move + start)"
  echo
  echo "部署相關環境變數:"
  echo "  UPLOAD_BIN_DIR      - 上傳目錄，預設 /tmp"
  echo "  UPLOAD_BIN_FILE     - 直接指定新執行檔的完整路徑（優先於 UPLOAD_BIN_DIR）"
  echo "  STOP_WAIT_SECONDS   - stop 等待舊程序結束的秒數上限，預設 60"
  echo "  STDOUT_LOG_MAX_SIZE_MB - start 前輪轉 general_stdout.log 的大小門檻，預設 10（0 停用）"
  echo "  STDOUT_LOG_KEEP     - general_stdout.log 保留的備份份數，預設 3"
  echo
  echo "Dashboard 環境變數:"
  echo "  DASHBOARD_HOST_PORT - host 對外 port，預設 9003"
  echo "  DASHBOARD_PORT      - container 內 Dashboard port，預設 9003"
  echo "  DASHBOARD_HOST      - container 內綁定位址，預設 0.0.0.0"
}

case "$1" in
  docker_build|docker_stop|docker_start|docker_restart|docker_update|start|stop|restart|move|update)
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
