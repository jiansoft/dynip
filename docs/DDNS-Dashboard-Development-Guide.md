# DDNS Dashboard 開發執行文件

> 文件版本：v1.1（移除 Redis 依賴，改用 APP 記憶體）  
> 建立日期：2026-06-15  
> 專案：`dynip` — Zig DDNS Background Service  
> 框架：[Jetzig](https://jetzig.dev/) (Zig Web Framework)

---

## 目錄

1. [需求概述](#1-需求概述)
2. [Dashboard 功能規格](#2-dashboard-功能規格)
3. [Wireframe 線稿圖](#3-wireframe-線稿圖)
4. [技術架構與資料流](#4-技術架構與資料流)
5. [Jetzig 路由規劃](#5-jetzig-路由規劃)
6. [預計使用的資料結構與 API](#6-預計使用的資料結構與-api)
7. [後續開發步驟](#7-後續開發步驟)

---

## 1. 需求概述

### 1.1 背景

`dynip` 是一個以 Zig 撰寫的 DDNS 常駐背景服務，支援三家 DDNS 供應商：
- **Afraid.org** (provider key: `afraid`)
- **Dynu** (provider key: `dynu`)
- **No-IP** (provider key: `noip`)

服務定期（預設 60 秒）抓取公開 IP，並將 IP 更新到各已啟用的 DDNS 供應商。
`ddns.zig` 核心模組在每次更新後，會記錄每個 provider 的完整狀態：

```text
ProviderState:
  current_ip    = 1.2.3.4       // 最後一次成功更新的 IP
  desired_ip    = 1.2.3.4       // 本輪目標 IP
  status        = success | failed
  retry_count   = 0
  next_retry_at = <unix timestamp>
  last_error    = <error string or empty>
  updated_at    = <unix timestamp>
```

當 Redis 啟用時，這些狀態也會同步持久化到 Redis Hash（`DDNS:Provider:{name}`）。

### 1.2 問題

目前所有狀態只能透過 `redis-cli` 或日誌查詢，缺乏可視化工具。

### 1.3 目標

使用 **Jetzig** 開發一個 Web Dashboard，整合在 `dynip` 專案中（或作為獨立 sub-project）。

### 1.4 設計原則（v1.1 更新）

> **Dashboard 資料來源改為 APP 記憶體，移除對 Redis 的直接依賴。**

| 項目 | 設計決策 |
|------|----------|
| 資料來源 | `ddns.zig` 對外暴露的 `getProviderSnapshots()` — 讀取 process-level 記憶體 |
| Redis 角色 | 保持 DDNS 主流程的持久化用途；**Dashboard 不直接連 Redis** |
| 優點 | Dashboard 不需要知道 Redis 設定；Redis 停用時 Dashboard 仍可正常顯示 |
| 限制 | 狀態在服務重啟後歸零（記憶體清空）；只反映本次啟動後的狀態 |

### 1.5 非功能需求

| 項目 | 要求 |
|------|------|
| 響應速度 | 頁面首次載入 < 500ms |
| 狀態刷新 | 輪詢間隔 ≤ 30 秒（可配置） |
| 部署方式 | 同 `dynip` 服務一起啟動，或獨立啟動 |
| 認證 | 初版不需要，後期可加基本 HTTP Auth |
| Redis 依賴 | Dashboard **不**依賴 Redis；資料來自 `ddns.getProviderSnapshots()` |

---

## 2. Dashboard 功能規格

### 2.1 功能列表

#### F1：總覽頁面（`/dashboard`）
- 顯示目前公開 IP（來自 process-level `ProcessPublicIpState`）
- 顯示所有 provider 的摘要狀態卡片（最多 3 張）
- 每張狀態卡片含有：provider 名稱、當前 IP、狀態顏色、重試次數
- 自動刷新（輪詢 `/api/status` JSON API）
- **服務剛啟動尚未跑過第一輪時，卡片顯示「Initializing...」**

#### F2：Provider 狀態卡片

| 狀態 | 顏色 | 觸發條件 |
|------|------|----------|
| 🔵 初始化中 (initializing) | 藍灰色 `#64748b` | `initialized == false`（服務剛啟動） |
| ✅ 正常 (success) | 綠色 `#22c55e` | `status == "success"` 且 `current_ip == desired_ip` |
| ⚠️ 重試等待 (retry_deferred) | 橙色 `#f97316` | `status == "failed"` 且 `next_retry_at > now` |
| ❌ 失敗 (failed) | 紅色 `#ef4444` | `status == "failed"` 且 retry backoff 已過期或 retry 次數過多 |
| ⬤ 停用 (disabled) | 灰色 `#6b7280` | provider 未在 `app.json` 啟用 |
| 🔄 更新中 (updating) | 藍色 `#3b82f6` | `desired_ip != current_ip`（收斂中） |

#### F3：詳細資訊側邊欄

點擊任一 provider 卡片後，右側或底部展開詳細資訊：
- `current_ip` / `desired_ip`
- `status`
- `retry_count`
- `next_retry_at`（格式化為本地時間）
- `last_error`（若有）
- `updated_at`（格式化為本地時間）

#### F4：JSON API（`/api/status`）

提供機器可讀的 JSON 狀態端點，**資料來源為 `ddns.getProviderSnapshots()`，不連 Redis**。

#### F5：設定資訊摘要（`/dashboard/config`）

顯示目前載入的設定（敏感資訊遮罩）。

#### F6：即時狀態更新

使用前端 JavaScript 輪詢 `/api/status`，每 30 秒自動更新卡片狀態。

---

## 3. Wireframe 線稿圖

### 3.1 主要 Dashboard 頁面（`/dashboard`）

```
┌─────────────────────────────────────────────────────────────────────┐
│  HEADER                                                             │
│  ┌──────────────────────────┐  ┌─────────────────────────────────┐  │
│  │  🌐 dynip Dashboard      │  │  📡 Public IP: 1.2.3.4          │  │
│  │  DDNS 監控中心            │  │  Last Updated: 2026-06-15 16:00 │  │
│  └──────────────────────────┘  └─────────────────────────────────┘  │
│  [Dashboard] [Config]                   ● Memory Store: Active      │
└─────────────────────────────────────────────────────────────────────┘
│                                                                     │
│  PROVIDER STATUS CARDS                         [⟳ Auto-refresh: ON] │
│                                                                     │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌────────────────┐
│  │ ✅ AFRAID.ORG       │  │ ✅ DYNU             │  │ ❌ NO-IP       │
│  │─────────────────────│  │─────────────────────│  │──────────────│
│  │ Status: Success     │  │ Status: Success     │  │ Status: Failed │
│  │ IP: 1.2.3.4         │  │ IP: 1.2.3.4         │  │ IP: 5.6.7.8   │
│  │ Retry: 0            │  │ Retry: 0            │  │ Retry: 2      │
│  │ Updated: 16:00:05   │  │ Updated: 16:00:05   │  │ Next: 16:15   │
│  │  [View Details]     │  │  [View Details]     │  │ [View Details] │
│  └─────────────────────┘  └─────────────────────┘  └────────────────┘
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────────┐
│  │  ℹ️  Note: State is from process memory.                        │
│  │     Restarting the service will reset all counters.             │
│  └─────────────────────────────────────────────────────────────────┘
│                                                                     │
│  DETAIL PANEL（點擊卡片後展開）                                       │
│  ┌─────────────────────────────────────────────────────────────────┐
│  │  📋 No-IP — 詳細狀態                          [✕ Close]        │
│  │  ─────────────────────────────────────────────────────────────  │
│  │  current_ip    │  5.6.7.8                                      │
│  │  desired_ip    │  1.2.3.4                ← IP mismatch ⚠️       │
│  │  status        │  failed                                        │
│  │  retry_count   │  2                                             │
│  │  next_retry_at │  2026-06-15 16:15:00 (in 14 min 32 sec)       │
│  │  last_error    │  UnexpectedNoIpResponse                        │
│  │  updated_at    │  2026-06-15 16:00:05                           │
│  └─────────────────────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────────┘
│  FOOTER                                                             │
│  dynip v1.x  |  Jetzig Dashboard  |  Data source: Process Memory   │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 服務剛啟動時的卡片樣式

```
┌─────────────────────────────────┐
│  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░   │  ← 藍灰色頂部色帶
│  🔵 AFRAID.ORG                  │
│─────────────────────────────────│
│  Status     ● Initializing...   │
│  Current IP  —                  │
│  Retry       0                  │
│  Note        Waiting for first  │
│              update cycle       │
└─────────────────────────────────┘
```

### 3.3 設定摘要頁面（`/dashboard/config`）

```
┌─────────────────────────────────────────────────────────────────────┐
│  設定摘要                                                            │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ Provider     │ Enabled │ Configured │ URL                    │   │
│  │──────────────│─────────│────────────│───────────────────────│   │
│  │ Afraid.org   │ true    │ ✅ Yes      │ freedns.afraid.org     │   │
│  │ Dynu         │ true    │ ✅ Yes      │ api.dynu.com           │   │
│  │ No-IP        │ true    │ ✅ Yes      │ dynupdate.no-ip.com    │   │
│  │──────────────│─────────│────────────│───────────────────────│   │
│  │ Refresh Interval  │ 60s                                      │   │
│  │ Redis enabled     │ false  (Dashboard does not use Redis)    │   │
│  │ Data Source       │ Process Memory                          │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.4 行動裝置版面（RWD，寬度 < 768px）

```
┌──────────────────────┐
│  🌐 dynip Dashboard  │
│  IP: 1.2.3.4  ≡ menu │
└──────────────────────┘
│  ✅ AFRAID.ORG       │
│  Success | 1.2.3.4   │
│  Updated: 16:00      │
│  [Details]           │
│──────────────────────│
│  ✅ DYNU             │
│  Success | 1.2.3.4   │
│  Updated: 16:00      │
│  [Details]           │
│──────────────────────│
│  ❌ NO-IP            │
│  Failed | 5.6.7.8    │
│  Next retry: 16:15   │
│  [Details]           │
└──────────────────────┘
```

---

## 4. 技術架構與資料流

### 4.1 整體架構（v1.1：APP 記憶體作為 Dashboard 資料來源）

```
┌──────────────────────────────────────────────────────────────┐
│                         Browser                              │
│  Dashboard UI (HTML + Vanilla JS)                            │
│  - 首次載入：GET /dashboard → Zmpl 模板渲染                  │
│  - 定時輪詢：GET /api/status.json → JSON 更新 DOM           │
└───────────────────────────┬──────────────────────────────────┘
                            │ HTTP
┌───────────────────────────▼──────────────────────────────────┐
│                  Jetzig HTTP Server                           │
│   GET /dashboard        → views/dashboard/index.zig          │
│   GET /dashboard/config → views/dashboard/config.zig         │
│   GET /api/status       → views/api/status.zig               │
└───────────────────────────┬──────────────────────────────────┘
                            │ 呼叫
┌───────────────────────────▼──────────────────────────────────┐
│              Dashboard Service Layer                         │
│              src/dashboard/service.zig                       │
│  readSnapshot() → 呼叫 ddns.getProviderSnapshots()           │
│                   取得 [3]ProviderSnapshot（不連 Redis）      │
└───────────────────────────┬──────────────────────────────────┘
                            │ 讀取（不需要網路）
┌───────────────────────────▼──────────────────────────────────┐
│         Process-level In-Memory State Store                  │
│         ddns.zig 維護的全域變數                               │
│                                                              │
│  process_provider_states: [3]ProcessProviderState            │
│  ┌──────────────┬───────────┬────────────┐                   │
│  │ afraid       │ dynu      │ noip       │  ← 固定 3 個 slot  │
│  │ current_ip   │ ...       │ ...        │                   │
│  │ status       │           │            │                   │
│  │ retry_count  │           │            │                   │
│  │ ...          │           │            │                   │
│  └──────────────┴───────────┴────────────┘                   │
│                                                              │
│  pub fn getProviderSnapshots() [3]ProviderSnapshot           │
│  （值語意複製，呼叫端不需釋放記憶體）                          │
└───────────────────────────▲──────────────────────────────────┘
                            │ 每次更新後雙寫
┌───────────────────────────┴──────────────────────────────────┐
│              DDNS Core（ddns.zig）                            │
│  每輪 refresh 後：                                            │
│  - 成功 → memoryWriteProviderSuccess()                       │
│  - 失敗 → memoryWriteProviderFailure()                       │
│                                          ┌──────────────┐   │
│  Redis 啟用時，同時也寫入：               │  Redis       │   │
│  → saveProviderSuccess() → HSET          │  （可選）    │   │
│  → saveProviderFailure() → HSET          └──────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

### 4.2 資料流

**初始頁面載入：**
```
Browser  GET /dashboard
  → Jetzig Router
  → views/dashboard/index.zig::index()
    → dashboard/service.readSnapshot()
      → ddns.getProviderSnapshots()  // 讀 process-level 記憶體，無 I/O
    → request.data(.object) 填入 3 個 provider 快照
  → Zmpl 模板渲染 index.zmpl
  → 回傳 HTML（含靜態狀態）
```

**前端定時輪詢（每 30 秒）：**
```
Browser  fetch('/api/status.json')
  → views/api/status.zig::index()
    → ddns.getProviderSnapshots()  // 同上，讀記憶體
    → 填入 Jetzig data object
  → Jetzig 自動回傳 JSON
  → 前端 JS 解析 → 更新 DOM 卡片
```

**DDNS 更新後的狀態同步：**
```
scheduler.runForever() 每 N 秒觸發
  → ddns.refresh()
    → updateDdnsServices() 或 refreshWithRedisProviderState()
      → 各 provider API 呼叫
      → 成功 → memoryWriteProviderSuccess()  // 寫 process 記憶體
               saveProviderSuccess()          // 若 Redis 啟用，也寫 Redis
      → 失敗 → memoryWriteProviderFailure()  // 寫 process 記憶體
               saveProviderFailure()          // 若 Redis 啟用，也寫 Redis
```

### 4.3 模組職責

| 模組 | 路徑 | 職責 |
|------|------|------|
| Memory State Store | `src/core/ddns.zig` | `ProcessProviderState` 全域陣列、`getProviderSnapshots()` 公開 API |
| Dashboard View | `src/app/views/dashboard/index.zig` | 首頁 HTML 渲染 |
| Config View | `src/app/views/dashboard/config.zig` | 設定摘要頁渲染 |
| Status API | `src/app/views/api/status.zig` | JSON 狀態 API |
| Dashboard Template | `src/app/views/dashboard/index.zmpl` | HTML 模板 |
| Config Template | `src/app/views/dashboard/config.zmpl` | 設定頁模板 |
| Layout Template | `src/app/views/layouts/application.zmpl` | 共用 Header/Footer |
| Dashboard Service | `src/dashboard/service.zig` | 呼叫 `ddns.getProviderSnapshots()`、整理展示資料 |
| Static JS | `public/dashboard.js` | 前端輪詢邏輯 |
| Static CSS | `public/dashboard.css` | 深色主題樣式 |

### 4.4 狀態判斷邏輯

```
fn classifyDisplayStatus(snapshot, now) -> DisplayStatus {
    if !snapshot.initialized                              → initializing
    if snapshot.status == ""                              → initializing
    if snapshot.status == "success"
       AND snapshot.current_ip == snapshot.desired_ip     → success
    if snapshot.status == "failed"
       AND snapshot.next_retry_at > now                   → retry_deferred
    if snapshot.status == "failed"                        → failed
    if snapshot.desired_ip != snapshot.current_ip         → updating
    default                                               → success
}
```

### 4.5 記憶體 vs Redis 角色對比

| 功能 | 記憶體（Process State） | Redis |
|------|------------------------|-------|
| Dashboard 資料來源 | ✅ 主要來源 | ❌ 不直接使用 |
| DDNS 防重複更新 | ✅ 本機 TTL dedup | ✅ 可選，持久化 |
| 服務重啟後保留 | ❌ 清空 | ✅ 保留 |
| 需要網路連線 | ❌ 不需要 | ✅ 需要 |
| Provider 狀態機 reconcile | ✅（無 Redis 時）| ✅（Redis 啟用時） |

---

## 5. Jetzig 路由規劃

### 5.1 路由對應表

Jetzig 採用**檔案系統路由**，只要把 `*.zig` 放在正確路徑，路由自動生成。

| HTTP Method | URL Path | 對應檔案 | 回傳格式 |
|-------------|----------|----------|----------|
| GET | `/dashboard` | `src/app/views/dashboard/index.zig` | HTML |
| GET | `/dashboard.json` | 同上 | JSON |
| GET | `/dashboard/config` | `src/app/views/dashboard/config.zig` | HTML |
| GET | `/api/status` | `src/app/views/api/status.zig` | JSON |
| GET | `/api/status.json` | 同上 | JSON |

### 5.2 路由目錄結構

```
src/
└── app/
    └── views/
        ├── dashboard/
        │   ├── index.zig      ← GET /dashboard
        │   ├── index.zmpl
        │   ├── config.zig     ← GET /dashboard/config
        │   └── config.zmpl
        ├── api/
        │   └── status.zig     ← GET /api/status
        └── layouts/
            └── application.zmpl
```

### 5.3 Jetzig View 範例（`/api/status`）

```zig
// src/app/views/api/status.zig
const jetzig = @import("jetzig");
const ddns = @import("../../core/ddns.zig");
const service = @import("../../dashboard/service.zig");

pub fn index(request: *jetzig.Request) !jetzig.View {
    var root = try request.data(.object);

    // 讀取 process-level 記憶體，不連 Redis
    const snapshots = ddns.getProviderSnapshots();
    const now_seconds = std.time.timestamp();

    try root.put("desired_ip", service.resolveDesiredIp(snapshots));
    try root.put("data_source", "process_memory");

    var providers_array = try root.array("providers");
    for (snapshots) |snap| {
        if (!snap.initialized and snap.name_len == 0) continue; // 未設定的 slot

        var obj = try providers_array.object();
        try obj.put("name", snap.nameSlice());
        try obj.put("initialized", snap.initialized);
        try obj.put("current_ip", snap.currentIpSlice());
        try obj.put("desired_ip", snap.desiredIpSlice());
        try obj.put("status", snap.statusSlice());
        try obj.put("display_status",
            @tagName(service.classifyDisplayStatus(snap, now_seconds)));
        try obj.put("retry_count", snap.retry_count);
        try obj.put("next_retry_at", snap.next_retry_at);
        try obj.put("last_error", snap.lastErrorSlice());
        try obj.put("updated_at", snap.updated_at);
    }

    return request.render(.ok);
}
```

### 5.4 Zmpl 模板範例（Provider 卡片）

```zmpl
@// src/app/views/dashboard/index.zmpl
@for (providers) |provider| {
  <div class="provider-card status-{{provider.display_status}}"
       id="card-{{provider.name}}">
    <div class="status-strip"></div>
    <div class="card-header">
      <span class="provider-name">{{provider.name}}</span>
      <span class="status-badge">{{provider.display_status}}</span>
    </div>
    <div class="card-body">
      <div class="field">
        <span class="label">Current IP</span>
        <span class="value mono">
          @if (provider.initialized) { {{provider.current_ip}} }
          @else { — }
        </span>
      </div>
      <div class="field">
        <span class="label">Retry Count</span>
        <span class="value">{{provider.retry_count}}</span>
      </div>
      <div class="field">
        <span class="label">Updated</span>
        <span class="value">{{provider.updated_at_formatted}}</span>
      </div>
    </div>
    <button class="detail-btn"
            onclick="showDetail('{{provider.name}}')">View Details →</button>
  </div>
}
```

---

## 6. 預計使用的資料結構與 API

### 6.1 `ddns.zig` 對外公開 API（核心擴充）

#### `ProviderSnapshot`（公開型別）

```zig
// src/core/ddns.zig

/// 對外公開的 provider 狀態快照（值語意，複製自 process-level 記憶體）。
/// 所有字串欄位都使用固定 buffer，不需要釋放記憶體，也不依賴 Redis。
pub const ProviderSnapshot = struct {
    name: [8]u8,        name_len: usize,
    initialized: bool,  // false = 服務剛啟動，尚無更新紀錄

    current_ip: [64]u8, current_ip_len: usize,
    desired_ip: [64]u8, desired_ip_len: usize,
    status: [16]u8,     status_len: usize,   // "success" | "failed" | ""

    retry_count:   u32,
    next_retry_at: i64,   // Unix 秒數；0 = 可立刻重試

    last_error: [128]u8, last_error_len: usize,
    updated_at: i64,      // Unix 秒數；0 = 從未寫入

    // 便利方法
    pub fn nameSlice(self: *const ProviderSnapshot) []const u8 { ... }
    pub fn currentIpSlice(self: *const ProviderSnapshot) []const u8 { ... }
    pub fn desiredIpSlice(self: *const ProviderSnapshot) []const u8 { ... }
    pub fn statusSlice(self: *const ProviderSnapshot) []const u8 { ... }
    pub fn lastErrorSlice(self: *const ProviderSnapshot) []const u8 { ... }
};
```

#### `getProviderSnapshots()`（公開函式）

```zig
/// 取得目前行程內所有 provider 的狀態快照（固定回傳 3 筆）。
///
/// - 只讀取 process-level 記憶體，不連 Redis，無 I/O。
/// - 回傳值語意的 [3]ProviderSnapshot，呼叫端不需釋放。
/// - 槽位順序：[0]=afraid, [1]=dynu, [2]=noip。
/// - 若某 provider 尚未有任何更新紀錄，initialized == false，
///   對應欄位均為零值，呼叫端自行判斷是否顯示。
pub fn getProviderSnapshots() [3]ProviderSnapshot { ... }
```

#### 內部寫入函式（私有）

```zig
// 在每次 provider 更新後呼叫：
fn memoryWriteProviderSuccess(provider, ip, now_seconds) void { ... }
fn memoryWriteProviderFailure(provider, desired_ip, retry_count,
                              next_retry_at, last_error, now_seconds) void { ... }
```

#### 呼叫時機

| 路徑 | 成功時 | 失敗時 |
|------|--------|--------|
| Redis 啟用：`reconcileProvider()` | `saveProviderSuccess()` 內部呼叫 `memoryWriteProviderSuccess()` | `saveProviderFailure()` 內部呼叫 `memoryWriteProviderFailure()` |
| Redis 停用：`updateDdnsServices()` | 直接呼叫 `memoryWriteProviderSuccess()` | 直接呼叫 `memoryWriteProviderFailure()` |

### 6.2 Dashboard Service Layer

```zig
// src/dashboard/service.zig

pub const DisplayStatus = enum {
    initializing,   // initialized == false（服務剛啟動）
    success,        // IP 已同步
    failed,         // 失敗（retry backoff 已過期）
    retry_deferred, // 失敗，正在等待 backoff
    updating,       // IP 不同步，嘗試收斂中
    disabled,       // provider 未啟用（enabled == false）
};

pub const ProviderDisplayData = struct {
    snapshot: ddns.ProviderSnapshot,
    display_status: DisplayStatus,
    enabled: bool,  // 來自 AppConfig
};

/// 從 ddns.getProviderSnapshots() 取得原始快照，
/// 再結合 AppConfig 的 enabled 旗標，組出展示用資料。
pub fn readDisplayData(config: config_mod.AppConfig) [3]ProviderDisplayData {
    const snapshots = ddns.getProviderSnapshots();
    const now = currentUnixSeconds();
    return .{
        buildDisplayData(snapshots[0], config.afraid.enabled, now),
        buildDisplayData(snapshots[1], config.dyny.enabled, now),
        buildDisplayData(snapshots[2], config.noip.enabled, now),
    };
}

/// 從三個 provider 的 current_ip 中選出最新的一個作為「當前公開 IP」顯示。
pub fn resolveDesiredIp(snapshots: [3]ddns.ProviderSnapshot) []const u8 { ... }

/// 根據快照欄位值判斷 DisplayStatus。
pub fn classifyDisplayStatus(
    snap: ddns.ProviderSnapshot,
    now_seconds: i64,
) DisplayStatus { ... }
```

### 6.3 JSON API 回應格式（`GET /api/status.json`）

```json
{
  "data_source": "process_memory",
  "desired_ip": "1.2.3.4",
  "providers": [
    {
      "name": "afraid",
      "initialized": true,
      "current_ip": "1.2.3.4",
      "desired_ip": "1.2.3.4",
      "status": "success",
      "display_status": "success",
      "retry_count": 0,
      "next_retry_at": 0,
      "last_error": "",
      "updated_at": 1781435100
    },
    {
      "name": "dynu",
      "initialized": true,
      "current_ip": "1.2.3.4",
      "desired_ip": "1.2.3.4",
      "status": "success",
      "display_status": "success",
      "retry_count": 0,
      "next_retry_at": 0,
      "last_error": "",
      "updated_at": 1781435100
    },
    {
      "name": "noip",
      "initialized": true,
      "current_ip": "5.6.7.8",
      "desired_ip": "1.2.3.4",
      "status": "failed",
      "display_status": "retry_deferred",
      "retry_count": 2,
      "next_retry_at": 1781436300,
      "last_error": "UnexpectedNoIpResponse",
      "updated_at": 1781435100
    }
  ]
}
```

> **注意：** `v1.1` 移除了 `redis_connected` 欄位，改用 `data_source: "process_memory"` 表示資料來源。

### 6.4 前端 JavaScript 輪詢邏輯

```javascript
// public/dashboard.js

const REFRESH_INTERVAL_MS = 30_000;

const STATUS_CONFIG = {
  initializing:   { label: '🔵 Initializing', class: 'status-init'    },
  success:        { label: '✅ Success',       class: 'status-success' },
  failed:         { label: '❌ Failed',        class: 'status-failed'  },
  retry_deferred: { label: '⚠️ Retry Wait',   class: 'status-retry'   },
  updating:       { label: '🔄 Updating',      class: 'status-update'  },
  disabled:       { label: '⬤ Disabled',      class: 'status-off'     },
};

async function fetchStatus() {
  try {
    const resp = await fetch('/api/status.json');
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    document.getElementById('desired-ip').textContent =
      data.desired_ip || 'N/A';
    document.getElementById('data-source').textContent =
      data.data_source || '—';
    for (const p of data.providers) updateProviderCard(p);
  } catch (err) {
    console.error('Failed to fetch status:', err);
  }
}

function updateProviderCard(p) {
  const card = document.getElementById(`card-${p.name}`);
  if (!card) return;
  const cfg = STATUS_CONFIG[p.display_status] ?? STATUS_CONFIG.disabled;
  card.className = `provider-card ${cfg.class}`;
  card.querySelector('.status-badge').textContent = cfg.label;
  card.querySelector('.current-ip').textContent =
    p.initialized ? (p.current_ip || 'N/A') : '—';
  card.querySelector('.retry-count').textContent = p.retry_count;
  // ...
}

fetchStatus();
setInterval(fetchStatus, REFRESH_INTERVAL_MS);
```

### 6.5 CSS 狀態顏色系統

```css
:root {
  --color-init:    #64748b;   /* 藍灰 — 初始化中 */
  --color-success: #22c55e;   /* 綠   — 成功 */
  --color-failed:  #ef4444;   /* 紅   — 失敗 */
  --color-retry:   #f97316;   /* 橙   — 等待重試 */
  --color-update:  #3b82f6;   /* 藍   — 更新中 */
  --color-off:     #6b7280;   /* 灰   — 停用 */
}

.status-strip { height: 4px; border-radius: 4px 4px 0 0; }
.status-init    .status-strip { background: var(--color-init);    }
.status-success .status-strip { background: var(--color-success); }
.status-failed  .status-strip { background: var(--color-failed);  }
.status-retry   .status-strip { background: var(--color-retry);   }
.status-update  .status-strip { background: var(--color-update);  }
.status-off     .status-strip { background: var(--color-off);     }
```

---

## 7. 後續開發步驟

### Phase 0：環境準備（先決條件）

- [ ] 確認 Zig 版本與 Jetzig 相容
- [ ] 安裝 `jetzig` CLI 工具
- [ ] 決定 Dashboard 整合方式（獨立子目錄 `dashboard/` 或整合進主專案）
- [ ] 確認 Dashboard 監聽 port（建議 `8080`）

### Phase 1：Jetzig 專案初始化

- [ ] 在 `dynip/dashboard/` 初始化 Jetzig app（`jetzig init`）
- [ ] 配置 `build.zig.zon` 引入 Jetzig dependency
- [ ] 在 `build.zig` 讓 Dashboard 可以 `@import` `src/core/ddns.zig`
- [ ] 驗證 `zig build dashboard` 可啟動 Jetzig 開發伺服器

### Phase 2a：核心擴充（`ddns.zig`）

> **這個 Phase 改動 `dynip` 主體程式，不動 Jetzig 部分。**

- [ ] 在 `ddns.zig` 新增 `ProcessProviderState` struct（固定 buffer，無 heap）
- [ ] 新增 `process_provider_states: [3]ProcessProviderState` 全域變數
- [ ] 新增 `process_provider_mutex: std.atomic.Mutex` 保護全域陣列
- [ ] 實作 `memoryWriteProviderSuccess()` / `memoryWriteProviderFailure()` 私有函式
- [ ] 在 `saveProviderSuccess()` 末尾呼叫 `memoryWriteProviderSuccess()`（Redis 路徑）
- [ ] 在 `saveProviderFailure()` 末尾呼叫 `memoryWriteProviderFailure()`（Redis 路徑）
- [ ] 在 `updateDdnsServices()` 成功/失敗分支呼叫對應的 memory write（非 Redis 路徑）
- [ ] 對外公開 `ProviderSnapshot` 型別與 `getProviderSnapshots()` 函式
- [ ] 單元測試 `getProviderSnapshots()` 的 mutex 安全性與複製語意

### Phase 2b：Dashboard Service Layer

- [ ] 建立 `src/dashboard/service.zig`
- [ ] 實作 `DisplayStatus` enum（含 `initializing` / `disabled` 狀態）
- [ ] 實作 `classifyDisplayStatus(snap, now)` — 純邏輯，無 I/O
- [ ] 實作 `readDisplayData(config)` — 呼叫 `ddns.getProviderSnapshots()`
- [ ] 實作 `resolveDesiredIp(snapshots)` — 從快照選出最新公開 IP
- [ ] 單元測試 `classifyDisplayStatus()` 各種邊界情境

### Phase 3：JSON API 實作

- [ ] 建立 `src/app/views/api/status.zig`
- [ ] 呼叫 `service.readDisplayData()` 填入 Jetzig data object
- [ ] 回傳 `data_source: "process_memory"` 欄位
- [ ] 測試 `GET /api/status.json` 回傳正確 JSON 格式
- [ ] 確認服務剛啟動時（initialized == false）的回傳格式正確

### Phase 4：HTML 頁面與模板

- [ ] Layout template：Header（Logo、Nav、Public IP badge）、Footer（Data source 標示）
- [ ] Dashboard index view + template（三欄卡片 + detail panel）
  - 加入「Data source: Process Memory」資訊說明欄
  - 加入「Initializing...」狀態的特殊顯示
- [ ] Config view + template（設定摘要表格，顯示 Redis 是否啟用但說明 Dashboard 不直接連）

### Phase 5：前端互動

- [ ] `public/dashboard.js`：輪詢、DOM 更新、detail panel、倒數計時器
- [ ] `public/dashboard.css`：深色主題、6 種狀態顏色（含 initializing / disabled）、RWD

### Phase 6：整合與測試

- [ ] 整合測試：同時啟動 `dynip` + Dashboard HTTP server
- [ ] 驗證第一輪更新完成後卡片從「Initializing」切換到正確狀態
- [ ] 測試 Redis 停用（`redis.enabled = false`）時 Dashboard 仍正常顯示
- [ ] 跨瀏覽器測試（Chrome / Firefox / Edge）
- [ ] 行動裝置 RWD 測試

### Phase 7：部署整合

- [ ] 決定啟動方式（獨立 binary / `dynip dashboard` subcommand）
- [ ] 更新 `Dockerfile`、`control.sh`
- [ ] 更新 `README.zh-TW.md`（加入 Dashboard 說明）

### Phase 8（進階選項）

- [ ] SSE（Server-Sent Events）替換輪詢
- [ ] HTTP Basic Auth 保護 Dashboard
- [ ] 日誌尾部串流（`/dashboard/logs`）
- [ ] 手動觸發更新按鈕（POST `/api/trigger`）
- [ ] 服務重啟後從 Redis 載入歷史狀態（optional，若 Redis 已啟用）

---

## 附錄

### A. 重要設計決策紀錄（ADR）

**ADR-001：Dashboard 資料來源改為 APP 記憶體**

- **決策**：Dashboard 不直接連 Redis，改讀 `ddns.getProviderSnapshots()`
- **理由**：
  1. 降低 Dashboard 的部署複雜度（不需要 Redis 連線設定）
  2. Redis 停用時 Dashboard 仍可運作
  3. Dashboard 的職責是「展示目前狀態」，而非「持久化查詢」
- **取捨**：服務重啟後記憶體狀態歸零，須等下一輪更新後才有資料顯示

### B. 目錄結構（完整）

```
dynip/
├── src/
│   ├── core/
│   │   └── ddns.zig          ← 新增 ProcessProviderState、getProviderSnapshots()
│   └── dashboard/            ← 新增目錄
│       └── service.zig        ← Dashboard service layer
└── dashboard/                ← Jetzig 子專案（或整合進主 build.zig）
    ├── build.zig
    ├── build.zig.zon
    ├── src/
    │   ├── main.zig
    │   └── app/
    │       └── views/
    │           ├── layouts/application.zmpl
    │           ├── dashboard/
    │           │   ├── index.zig + index.zmpl
    │           │   └── config.zig + config.zmpl
    │           └── api/
    │               └── status.zig
    └── public/
        ├── dashboard.js
        └── dashboard.css
```

### C. Provider 狀態機圖（更新）

```
    服務啟動
        │
        ▼
   ┌──────────────┐
   │ initializing │  initialized == false，等待第一輪 refresh
   └──────────────┘
        │ 第一輪 refresh 跑完
        ▼
   ┌──────────┐   API 成功，IP 收斂   ┌─────────┐
   │ updating ├──────────────────────►│ success │
   └──────────┘                       └────┬────┘
        ▲                                  │ desired_ip 改變
        └──────────────────────────────────┘

   API 失敗
        │
        ▼                        next_retry_at 未到期
   ┌──────────┐  ──────────────────────────────────► ┌──────────────────┐
   │  failed  │                                       │  retry_deferred  │
   └──────────┘  ◄──────────────────────────────────  └──────────────────┘
        ▲              backoff 到期，重試仍失敗
        └─────────────────────────────────────────────────────────────────
```

---

> **下一步確認事項：**
>
> 1. **Phase 2a（核心擴充）可以開始嗎？** 即在 `ddns.zig` 加入 in-memory state store。
> 2. **整合方式**：Dashboard 獨立子目錄（`dashboard/`）還是整合進主 `build.zig`？
> 3. **監聽 Port**：建議預設 `8080`，是否符合您的部署環境？
