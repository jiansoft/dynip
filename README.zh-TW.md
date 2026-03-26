<p align="right">
  <a href="./README.md">English</a> | <a href="./README.zh-TW.md">繁體中文</a>
</p>

# dynip

以 Zig 撰寫的 DDNS 常駐背景服務。

`dynip` 會定期檢查目前的公網 IP，並更新已設定的 DDNS 供應商：

- Afraid.org
- Dynu
- No-IP

它支援分層設定載入、結構化日誌、HTTP 請求追蹤，以及使用 Redis 或行程內記憶體的去重控制。

## 功能

- 從 `app.json` 載入設定
- 使用 `.env` 覆蓋設定
- 使用系統環境變數再覆蓋一次
- 以常駐排程模式執行
- 可獨立更新 Afraid / Dynu / No-IP
- 在多個 public IP 來源站之間輪替
- 依日誌等級輸出檔案
- 記錄 HTTP request / response 日誌
- 以 Redis 或本機記憶體做更新去重

## 運作方式

每一輪 refresh 流程如下：

1. 檢查目前是否落在本地時間 `02:00` 到 `02:04` 的維護略過時段。
2. 從內建的 public IP 來源站取得目前公網 IP。
3. 依照 `MyPublicIP:{ip}` 格式建立 dedupe key。
4. 當 `ddns.redis.enabled = true` 時查 Redis，否則改查本機記憶體 TTL cache。
5. 如果 key 已存在，就略過這次更新。
6. 更新所有已啟用且認證資料完整的 DDNS 供應商。
7. 只要至少一個供應商更新成功，就把 key 寫入 dedupe cache。

## 專案結構

- `src/main.zig`: CLI 入口
- `src/config.zig`: 設定載入、`.env` 解析、環境變數覆寫
- `src/ddns.zig`: DDNS refresh 主流程與供應商更新邏輯
- `src/redis.zig`: Redis client 包裝
- `src/scheduler.zig`: 固定間隔排程器
- `src/logging.zig`: 檔案日誌與輪替
- `src/tests.zig`: 測試入口
- `build.zig`: 建置定義
- `build.ps1`: Windows release 建置腳本
- `build.bat`: Windows batch wrapper
- `control.sh`: 偏向 Docker 流程的輔助腳本
- `Dockerfile`: 容器映像建置檔

## 執行需求

- Zig `0.16.0-dev.2979+e93834410` 或相近可相容的 dev 版本
- 可連線到 public IP 查詢服務
- 可連線到你啟用的 DDNS 供應商
- 只有在你要用 Redis 去重時，才需要 Redis

## 設定

設定載入順序如下：

1. `app.json`
2. `.env`
3. 系統環境變數

後面的來源會覆蓋前面的值。

### `app.json` 範例

```json
{
  "afraid": {
    "enabled": true,
    "url": "https://freedns.afraid.org",
    "path": "/dynamic/update.php?",
    "token": ""
  },
  "dyny": {
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
    "redis": {
      "enabled": true,
      "addr": "localhost:6379",
      "account": "",
      "password": "",
      "db": 0
    }
  }
}
```

### 供應商設定格式

三家 DDNS 供應商統一採用這種欄位風格：

- `enabled`
- `url`
- 各自需要的認證欄位

各供應商特有欄位如下：

- `afraid`: `path`, `token`
- `dyny`: `username`, `password`
- `noip`: `username`, `password`, `hostnames`

### Redis 去重

當 `ddns.redis.enabled = true` 時：

- 去重狀態存放在 Redis
- key 格式為 `MyPublicIP:{ip}`
- 目前最新 public IP 也會同步寫到 `MyPublicIP`
- 更新成功後會用 `SETEX` 寫入 key

當 `ddns.redis.enabled = false` 時：

- 去重狀態只存放在本機行程記憶體
- TTL 邏輯與 Redis 模式相同
- 行程重啟後去重狀態會消失

### 支援的環境變數

#### Afraid

- `AFRAID_ENABLED`
- `AFRAID_URL`
- `AFRAID_PATH`
- `AFRAID_TOKEN`

#### Dynu

- `DYNU_ENABLED`
- `DYNU_URL`
- `DYNU_USERNAME`
- `DYNU_PASSWORD`

#### No-IP

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

### `.env` 範例

```dotenv
AFRAID_ENABLED=true
AFRAID_URL=https://freedns.afraid.org
AFRAID_PATH=/dynamic/update.php?
AFRAID_TOKEN=your-afraid-token

DYNU_ENABLED=true
DYNU_URL=https://api.dynu.com/nic/update
DYNU_USERNAME=your-dynu-username
DYNU_PASSWORD=your-dynu-password

NOIP_ENABLED=true
NOIP_URL=https://dynupdate.no-ip.com/nic/update
NOIP_USERNAME=your-noip-username
NOIP_PASSWORD=your-noip-password
NOIP_HOSTNAMES=["example.ddns.net","example.zapto.org"]

REDIS_ENABLED=false
DDNS_REFRESH_INTERVAL_SECONDS=60
DDNS_DEDUPE_TTL_SECONDS=86400
```

## 使用方式

### 執行測試

```bash
zig build test
```

如果專案放在 WSL 掛載路徑，例如 `/mnt/d/...`，建議把 cache 改放 Linux 原生檔案系統：

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

直接執行編譯後的 binary：

```bash
dynip service --config app.json
```

## 日誌

日誌會寫入 `log/`。

檔名格式：

- `log/YYYY-MM-DD_dynip_info.log`
- `log/YYYY-MM-DD_dynip_warn.log`
- `log/YYYY-MM-DD_dynip_error.log`
- `log/YYYY-MM-DD_dynip_debug.log`

目前日誌行為包含：

- 每日依等級分檔
- 換日 rollover
- 單檔超過 `10 MB` 會切 generation suffix
- 自動清除超過 `7` 天的舊日誌
- service 啟動時輸出實際載入的設定 JSON
- 記錄各 DDNS 供應商回應摘要
- 記錄 HTTP request / response

## Public IP 來源

目前內建的 public IP lookup 來源：

- `https://api.ipify.org`
- `https://ipconfig.io/ip`
- `https://ipinfo.io/ip`
- `https://ipv4.seeip.org`
- `https://api.myip.com`
- `https://api.bigdatacloud.net/data/client-ip`

每輪 refresh 不會永遠從同一個來源開始，而是會輪流切換起始站點。

## Windows 建置

在 `cmd.exe`：

```bat
cd /d D:\Project\Eddie\stock_zig
build.bat
```

在 PowerShell：

```powershell
Set-Location D:\Project\Eddie\stock_zig
powershell.exe -ExecutionPolicy Bypass -File .\build.ps1
```

目前 PowerShell build 會把 strip 過的 ARM64 Linux binary 輸出到 `zig-out\bin\`。

## Docker

`control.sh` 目前偏向 Docker 使用情境。

常用指令：

```bash
bash control.sh docker_build
bash control.sh docker_start
bash control.sh docker_stop
bash control.sh docker_restart
bash control.sh docker_update
```

目前的假設如下：

- 部署時 `control.sh` 和 `dynip_linux_arm64` 在同一層目錄
- `control.sh` 不負責在 production 端編譯 binary
- `docker_build` 直接拿現成 binary 搭配 `Dockerfile` 打包

預設名稱：

- image: `dynip-image`
- container: `dynip-container`
