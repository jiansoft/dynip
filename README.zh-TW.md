<p align="right">
  <a href="./README.md">English</a> | <a href="./README.zh-TW.md">繁體中文</a>
</p>

# dynip

以 Zig 撰寫的 DDNS 常駐背景服務。

`dynip` 會定期檢查目前的公開 IP，並更新已設定的 DDNS 供應商：

- [Afraid.org](https://freedns.afraid.org/)
- [Dynu](https://www.dynu.com/)
- [No-IP](https://www.noip.com/)
- [Cloudflare DNS](https://www.cloudflare.com/)

它支援分層設定載入、結構化日誌、HTTP 請求追蹤，以及使用 Redis 或程式內記憶體來避免重複更新。

## 功能

- 從 `app.json` 載入設定
- 使用 `.env` 覆蓋設定
- 使用系統環境變數再覆蓋一次
- 以常駐排程模式執行
- 可獨立更新 Cloudflare / Afraid / Dynu / No-IP
- IPv4 與 IPv6 分開查詢；其中一種協定不可用時，不會阻止另一種更新
- 在多個公開 IP 查詢來源之間輪替
- 依日誌等級輸出檔案
- 記錄 HTTP 請求 / 回應日誌
- 使用 Redis 記錄各 DDNS 供應商的獨立狀態
- 自動重試失敗的供應商，不重複更新已經是最新 IP 的供應商

## 快速開始

1. 建立 `app.json` 或 `.env`，並至少啟用一個 DDNS 供應商。
2. 如果需要持久化 provider 狀態與重試紀錄，請啟用 Redis。
3. 啟動服務：

```bash
zig build run
```

明確指定設定檔路徑：

```bash
zig build run -- service --config app.json
```

## DDNS 更新模型

每一輪更新流程如下：

1. 檢查目前是否落在本地時間 `02:00` 到 `02:04` 的維護跳過時段。
2. 從內建的公開 IP 查詢來源取得目前公開 IP。
3. 把這個公開 IP 視為所有已啟用 DDNS 供應商的目標 IP，也就是 `desired_ip`。
4. 當 Redis 啟用時，逐一比對 Redis 裡的供應商狀態。
5. 只更新 `current_ip` 尚未等於 `desired_ip`，且重試等待時間已到期的供應商。
6. 記錄供應商成功或失敗狀態，包含重試次數、下次重試時間與最後錯誤。
7. 當 Redis 關閉時，退回本機記憶體 TTL 防重複更新流程。

範例：

```text
目前公開 IP: 1.2.3.4

Afraid current_ip = 1.2.3.4  -> 略過
Dynu   current_ip = 1.2.3.4  -> 略過
No-IP  current_ip = 5.6.7.8  -> 更新或重試
```

也就是說，某一家供應商失敗時，不會造成其他已成功的供應商被重複更新。

## 專案結構

這個專案目前整理成比較接近 Zig 社群常見的應用程式結構：

- `src/main.zig`：盡量保持最薄的可執行檔入口。它本身不處理太多邏輯，只負責把程式啟動控制權交給 CLI 層。
- `src/cli.zig`：應用程式啟動層。這裡負責解析命令列參數、初始化 logger、安裝 signal handler、載入設定，最後啟動常駐排程器。
- `src/root.zig`：共用模組入口。它會重新匯出主要內部模組，並同時扮演 `zig build test` 的測試匯總入口。
- `src/base/config.zig`：設定載入邏輯。會先讀 `app.json`，再讀 `.env`，最後套用系統環境變數，後者覆蓋前者。
- `src/core/ddns.zig`：DDNS 主流程。包含取得公開 IP、比對 provider 狀態，以及更新各家已啟用的 DDNS 供應商。
- `src/io/redis.zig`：Redis 整合層，負責 DDNS provider 狀態與相容觀察 key。
- `src/core/scheduler.zig`：固定間隔的背景排程器，會持續觸發每一輪更新工作。
- `src/io/logging.zig`：日誌組裝層，負責 logger 狀態、等級過濾與對外 API。實作依職責拆成三個子模組：
  - `src/io/logging/format.zig`：本地時間取得、log 行格式化、console 輸出。
  - `src/io/logging/rotate.zig`：依日期與大小輪轉日誌檔、清除過期日誌。
  - `src/io/logging/seq.zig`：把同一筆 log 以 CLEF 格式送到 Seq。
- `src/io/http.zig`：共用 HTTP 請求與回應日誌輔助。
- `build.zig`：Zig 的建置腳本，負責把 executable、`run` step 與 `test` step 串起來。
- `scripts/build.ps1` / `scripts/build.bat`：偏向 Windows 使用情境的建置輔助腳本。
- `scripts/deploy-armv7.ps1`：把 ARMv7 執行檔一鍵部署到 Raspberry Pi（`/opt/dynip`）。
- `control.sh`：比較偏容器或部署流程的輔助腳本。
- `Dockerfile`：容器映像建置定義。

如果你是從其他語言生態來看，可以先這樣理解：

- `main.zig` 類似程式入口
- `cli.zig` 類似應用啟動層
- `root.zig` 類似共用 package root
- `build.zig` 同時負責建置腳本與任務入口定義

## 執行需求

- Zig `0.17.0-dev` 或更高版本
- 可連線到公開 IP 查詢服務
- 可連線到你啟用的 DDNS 供應商
- 只有在你要用 Redis 避免重複更新時，才需要 Redis

## 設定

設定載入順序如下：

1. `app.json`
2. `.env`
3. 系統環境變數

後面的來源會覆蓋前面的值。

### `app.json` 範例

```json
{
  "cloudflare": {
    "enabled": false,
    "api_token": "",
    "zone_id": "",
    "hostnames": ["home.example.com"],
    "proxied": false,
    "ttl": 1,
    "record_comment": "managed-by:dynip",
    "managed_record_comment": "managed-by:dynip",
    "http_retry_count": 2
  },
  "afraid": {
    "enabled": true,
    "url": "https://freedns.afraid.org",
    "path": "/dynamic/update.php?",
    "token": ""
  },
  "dynu": {
    "enabled": true,
    "url": "https://api.dynu.com/nic/update",
    "username": "",
    "password": ""
  },
  "noip": {
    "enabled": true,
    "url": "https://dynupdate.no-ip.com/nic/update",
    "username": "",
    "password": "",
    "hostnames": []
  },
  "ddns": {
    "refresh_interval_seconds": 60,
    "dedupe_ttl_seconds": 86400,
    "ipv4_provider": "auto",
    "ipv6_provider": "auto",
    "redis": {
      "enabled": true,
      "addr": "localhost:6379",
      "account": "",
      "password": "",
      "db": 0
    }
  },
  "logging": {
    "console_level": "info",
    "file_level": "info",
    "max_age_days": 7,
    "max_size_mb": 10,
    "seq": {
      "enabled": false,
      "level": "warn",
      "server_url": "",
      "api_key": ""
    }
  }
}
```

### 供應商設定格式

### Cloudflare DNS

Cloudflare 使用對目標 zone 具有 DNS Edit 權限的 API Token。每個 hostname 都會各自收斂：IPv4 更新 A record、IPv6 更新 AAAA record；IP 相同時略過；IP 不同時只 PATCH IP content，保留 Cloudflare 端既有 proxy、TTL、comment 與 tags。record 不存在時才使用設定的 proxied、TTL 與 `record_comment` 建立；TTL 設為 1 代表 Cloudflare Automatic。

若多個 DDNS instance 可能管理同一 hostname，請把 `record_comment` 與 `managed_record_comment` 都設定為唯一值，例如 `managed-by:dynip`。selector 會讓本 instance 只更新自己擁有的 record；若找到多筆符合 record，程式會安全停止，不會任意挑第一筆。`http_retry_count` 會對 Cloudflare 暫時性 rate limit（429）、server error（5xx）與傳輸失敗，以指數退避重試。

### 每個 family 獨立的 public IP provider

`ddns.ipv4_provider` 與 `ddns.ipv6_provider` 可各自設定，支援 `auto`（STUN/Cloudflare Trace fallback）、`none`、`stun`、`cloudflare_trace`、`url:<https-url>`、`file:<absolute-path>` 與 `static:<ip>`。IPv4-only 或 IPv6-only 網路可設為 `none`，這是刻意略過，不會被視為 refresh 失敗。`file:` 讀取第一個非空、非註解行；`static:` 適合可重現的測試。

三家 DDNS 供應商統一採用這種欄位格式：

- `enabled`
- `url`
- 各自需要的認證欄位

各供應商特有欄位如下：

- `afraid`: `path`, `token`
- `dynu`: `username`, `password`
- `noip`: `username`, `password`, `hostnames`

### Redis 狀態與重試行為

當 `ddns.redis.enabled = true` 時：

- 希望 provider 收斂到的 public IP 會依 family 分別寫到 `DDNS:DesiredIP:ipv4` 與 `DDNS:DesiredIP:ipv6`
- 每家 provider 每個 family 都有自己的 Redis hash，例如 `DDNS:Provider:cloudflare:ipv4` 與 `DDNS:Provider:cloudflare:ipv6`
- provider hash 會記錄 `current_ip`、`desired_ip`、`status`、`retry_count`、`next_retry_at`、`last_error` 與 `updated_at`
- 失敗 provider 會依 exponential backoff 重試；已成功 provider 會跳過，直到 desired IP 再次變更
- observer 與 dedupe key 也會依 family 隔離，例如 `MyPublicIP:ipv4`、`MyPublicIP:ipv4:1.2.3.4` 與 `MyPublicIP:cloudflare:ipv4`

provider hash 範例：

```text
DDNS:Provider:noip
  current_ip    = 5.6.7.8
  desired_ip    = 1.2.3.4
  status        = failed
  retry_count   = 2
  next_retry_at = 1781435400
  last_error    = UnexpectedNoIpResponse
  updated_at    = 1781435100
```

重試等待時間從 `30` 秒開始，最長退避到 `15` 分鐘。如果公開 IP 又改變，供應商會立刻針對新的 `desired_ip` 嘗試更新，不會被舊 IP 的重試等待時間擋住。

當 `ddns.redis.enabled = false` 時：

- 避免重複更新的狀態只存放在程式本身的記憶體中
- TTL 邏輯與 Redis 模式相同
- 程式重新啟動後，這些狀態就會消失

`ddns.dedupe_ttl_seconds` 仍會控制相容觀察 key 與 desired IP key 的 TTL。provider hash 不設定 TTL，方便保留最後狀態供排查使用。

### 支援的環境變數

#### Cloudflare DNS

- `CLOUDFLARE_ENABLED`
- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ZONE_ID`
- `CLOUDFLARE_HOSTNAMES`（JSON 字串陣列）
- `CLOUDFLARE_PROXIED`
- `CLOUDFLARE_TTL`
- `CLOUDFLARE_RECORD_COMMENT`
- `CLOUDFLARE_MANAGED_RECORD_COMMENT`
- `CLOUDFLARE_HTTP_RETRY_COUNT`

#### [Afraid.org](https://freedns.afraid.org/)

- `AFRAID_ENABLED`
- `AFRAID_URL`
- `AFRAID_PATH`
- `AFRAID_TOKEN`

#### [Dynu](https://www.dynu.com/)

- `DYNU_ENABLED`
- `DYNU_URL`
- `DYNU_USERNAME`
- `DYNU_PASSWORD`

#### [No-IP](https://www.noip.com/)

- `NOIP_ENABLED`
- `NOIP_URL`
- `NOIP_USERNAME`
- `NOIP_PASSWORD`
- `NOIP_HOSTNAMES`

#### DDNS / Redis

- `REDIS_ENABLED`
- `REDIS_ADDR`
- `REDIS_ACCOUNT`
- `REDIS_PASSWORD`
- `REDIS_DB`
- `DDNS_DEDUPE_TTL_SECONDS`
- `DDNS_REFRESH_INTERVAL_SECONDS`
- `DDNS_IPV4_PROVIDER`
- `DDNS_IPV6_PROVIDER`
- `LOG_CONSOLE_LEVEL`
- `LOG_FILE_LEVEL`
- `LOG_MAX_AGE_DAYS`
- `LOG_MAX_SIZE_MB`
- `LOG_SEQ_ENABLED`
- `LOG_SEQ_LEVEL`
- `LOG_SEQ_SERVER_URL`
- `LOG_SEQ_API_KEY`

### `.env` 範例

```dotenv
CLOUDFLARE_ENABLED=true
CLOUDFLARE_API_TOKEN=<cloudflare-api-token>
CLOUDFLARE_ZONE_ID=<cloudflare-zone-id>
CLOUDFLARE_HOSTNAMES=["home.example.com"]
CLOUDFLARE_PROXIED=false
CLOUDFLARE_TTL=1

AFRAID_ENABLED=true
AFRAID_URL=https://freedns.afraid.org
AFRAID_PATH=/dynamic/update.php?
AFRAID_TOKEN=<set-in-env>

DYNU_ENABLED=true
DYNU_URL=https://api.dynu.com/nic/update
DYNU_USERNAME=<set-in-env>
DYNU_PASSWORD=<set-in-env>

NOIP_ENABLED=true
NOIP_URL=https://dynupdate.no-ip.com/nic/update
NOIP_USERNAME=<set-in-env>
NOIP_PASSWORD=<set-in-env>
NOIP_HOSTNAMES=["example.ddns.net","example.zapto.org"]

REDIS_ADDR=127.0.0.1:6379
REDIS_ACCOUNT=<optional>
REDIS_PASSWORD=<set-if-needed>

REDIS_ENABLED=false
DDNS_REFRESH_INTERVAL_SECONDS=60
DDNS_DEDUPE_TTL_SECONDS=86400
DDNS_IPV4_PROVIDER=auto
DDNS_IPV6_PROVIDER=auto

LOG_CONSOLE_LEVEL=info
LOG_FILE_LEVEL=info
LOG_MAX_AGE_DAYS=7
LOG_MAX_SIZE_MB=10
LOG_SEQ_ENABLED=false
LOG_SEQ_LEVEL=warn
```

## 使用方式

### 執行測試

```bash
zig build test
```

如果專案放在 WSL 掛載路徑，例如 `/mnt/d/...`，建議把快取改放 Linux 原生檔案系統：

```bash
zig build test \
  --cache-dir /tmp/dynip_local_cache \
  --global-cache-dir /tmp/dynip_global_cache
```

### 啟動服務

使用預設設定路徑啟動：

```bash
zig build run
```

明確指定設定檔路徑：

```bash
zig build run -- service --config app.json
```

顯示說明：

```bash
zig build run -- --help
```

直接執行編譯後的執行檔：

```bash
dynip service --config app.json
```

## Web Dashboard

此服務內建 Web Dashboard 以便視覺化監控 DDNS 狀態。預設為啟用，並監聽在 `9003` 連接埠。

### 設定

您可以在 `app.json` 的 `"dashboard"` 區塊進行設定：

```json
  "dashboard": {
    "enabled": true,
    "host": "0.0.0.0",
    "port": 9003
  }
```

或使用環境變數覆寫：
- `DASHBOARD_ENABLED=true`
- `DASHBOARD_HOST=0.0.0.0`
- `DASHBOARD_PORT=9003`

如果停用（`"enabled": false`），服務將不會開啟任何 Web 連接埠，僅執行背景 DDNS 排程器。

## 維運與排查

### 檢查 Redis 狀態

查看目前目標 IP：

```bash
redis-cli GET DDNS:DesiredIP
```

查看單一供應商狀態：

```bash
redis-cli HGETALL DDNS:Provider:noip
```

查看相容觀察 key：

```bash
redis-cli GET MyPublicIP
redis-cli GET MyPublicIP:noip
```

### 常見情境

如果某一家供應商失敗，但其他供應商成功，通常會看到：

```text
status=failed
current_ip 不等於 desired_ip
next_retry_at 是未來時間
```

服務會略過已經是最新 IP 的供應商，並在 `next_retry_at` 到期後只重試失敗的供應商。

如果某一家供應商一直沒有更新：

- 確認該供應商已啟用，且必要認證資料都有填
- 查看 `last_error`
- 比對 `current_ip` 與 `desired_ip`
- 確認 `next_retry_at` 是否仍在未來

如果一輪更新中出現大量 Redis 連線 log，代表行為不正常。Redis 啟用時，每一輪更新應該共用同一條 Redis session。

## 日誌

日誌會寫入 `log/`。

檔名格式：

- `log/YYYY-MM-DD_dynip_info.log`
- `log/YYYY-MM-DD_dynip_warn.log`
- `log/YYYY-MM-DD_dynip_error.log`
- `log/YYYY-MM-DD_dynip_debug.log`

目前日誌行為包含：

- 每日依等級分檔
- 換日輪替
- 單檔超過 `max_size_mb`（預設 `10` MB，設為 `<= 0` 代表不依大小輪轉）時輪轉，採 **rename-on-rollover**：
  - **正在寫入的檔案永遠不帶時間戳**，最新日誌固定在 `log/YYYY-MM-DD_dynip_info.log`，
    tail 或 log 收集器只要盯這一個路徑。
  - 超過上限時，先把它改名成 `log/YYYY-MM-DD_dynip_info.09-06-56.log`
    （時間戳是該檔**最後一筆**日誌的時間，代表內容截止到幾點幾分），再開一個同名空檔繼續寫。
  - 同一秒內連續輪轉會加序號（`.09-06-56-1.log`），不會覆蓋既有封存檔。
  - 服務重啟後會接續寫入當天既有的活躍檔，不會另開新檔。
- 自動清除超過 `max_age_days`（預設 `7` 天，設為 `<= 0` 代表不自動刪除）的舊日誌
- 服務啟動時輸出實際載入的設定 JSON
- 記錄各 DDNS 供應商回應摘要
- 記錄 HTTP 請求 / 回應

## 公開 IP 查詢來源

目前內建的公開 IP 查詢來源：

- `STUN` (`stun.l.google.com:19302`) - 基於 UDP 封包的查詢方式
- `Cloudflare Trace` (`https://one.one.one.one/cdn-cgi/trace`) - 基於 HTTPS 的查詢方式

每一輪更新的主要來源會在 STUN 與 Cloudflare Trace 之間輪流切換，以兼顧可靠性與防火牆相容性。

## Windows 建置

在 `cmd.exe`：

```bat
cd /d C:\dynip
scriptsuild.bat
```

在 PowerShell：

```powershell
Set-Location C:\dynip
powershell.exe -ExecutionPolicy Bypass -File .\scripts\build.ps1
```

目前 PowerShell 建置會把經過 `strip` 的 ARM64 與 ARMv7 Linux 執行檔輸出到 `zig-out\bin\`。

## Docker

`control.sh` 目前是以 Docker 使用情境為主的輔助腳本。

常用指令：

```bash
bash control.sh docker_build
bash control.sh docker_start
bash control.sh docker_stop
bash control.sh docker_restart
bash control.sh docker_update
```

目前的假設如下：

- 部署時 `control.sh`、`dynip_linux_arm64`、`dynip_linux_armv7` 在同一層目錄
- `control.sh` 不負責在正式環境端編譯執行檔
- `docker_build` 拿現成的兩份執行檔搭配 `Dockerfile` 打包，`Dockerfile` 會透過 BuildKit 的 `TARGETARCH`/`TARGETVARIANT` 自動選出對應平台（arm64 或 armv7，例如 Raspberry Pi 3）的那一份

預設名稱：

- image: `dynip-image`
- container: `dynip-container`

## 一般模式部署與更新

不使用 Docker、直接在主機上背景執行 binary 時，`control.sh` 提供這幾個指令：

```bash
bash control.sh start     # 依 uname -m 選對應 binary，nohup 背景啟動
bash control.sh stop      # 依 pid file 停止，並等舊程序真的退出
bash control.sh restart
bash control.sh move      # 只把新執行檔就位，不重啟
bash control.sh update    # 完整更新：stop -> move -> start
```

更新流程刻意分成「上傳」與「就位」兩步：

1. 在開發機交叉編譯後，把執行檔 `scp` 到裝置的 `/tmp`（可用 `UPLOAD_BIN_DIR` 改路徑）。
   **不要**直接覆蓋正在執行的檔案，Linux 會回 `Text file busy`（ETXTBSY）。
2. 在裝置上執行 `bash control.sh update`：先停止服務並等它結束，接著把同層的舊執行檔
   改名備份（帶時間戳、並拿掉執行權限），再從 `/tmp` 把新檔搬過來、加上執行權限，最後啟動。

先備份再搬入是為了讓新檔案是全新的 inode，就算舊程序尚未完全結束也不會踩到 ETXTBSY。

執行 `control.sh` 的身分要能寫入它所在的目錄（搬執行檔、寫 pid file 與 `log/` 都在那裡），
且每次都用同一種身分，否則 pid file 與日誌檔的擁有者會混亂。

相關環境變數：

- `UPLOAD_BIN_DIR`：上傳目錄，預設 `/tmp`
- `UPLOAD_BIN_FILE`：直接指定新執行檔的完整路徑，優先於 `UPLOAD_BIN_DIR`
- `STOP_WAIT_SECONDS`：`stop` 等待舊程序結束的秒數上限，預設 `60`
- `STDOUT_LOG_MAX_SIZE_MB`：`start` 前輪轉 `log/general_stdout.log` 的大小門檻，預設 `10`（`0` 停用）
- `STDOUT_LOG_KEEP`：`log/general_stdout.log` 保留的備份份數，預設 `3`

### `log/general_stdout.log` 為什麼會變大

這個檔收的是程式的 stdout/stderr（`start` 的 `nohup ... >>` 重導向），內容和 `log/*.log`
幾乎重複——程式的 console 輸出與檔案日誌本來就是同一批訊息。差別在於 `log/*.log` 由程式
自己輪轉與清理，而這個檔沒有任何人管，只會一直 append，跑幾週就會累積到數十 MB。

`control.sh start` 會在啟動前檢查它，超過 `STDOUT_LOG_MAX_SIZE_MB` 就改名備份，
並只保留最近 `STDOUT_LOG_KEEP` 份。只能在啟動前處理：服務跑起來後，重導向綁的是已開啟的
fd（inode），改名或刪檔都不會讓執行中的程序改寫到新檔。

想從源頭少寫一點，把 `.env` 的 `LOG_CONSOLE_LEVEL` 調成 `warn` 或 `error`；
檔案日誌與 Seq 不受影響，仍由 `LOG_FILE_LEVEL` 與 `LOG_SEQ_LEVEL` 各自控制。
