# DDNS Dashboard Code Review Report

本報告針對 `dynip` 專案中的 HTTP Dashboard 進行完整 Code Review，對比 `docs/DDNS-Dashboard-Development-Guide.md` 設計要求與實際程式碼實作。

---

## 1. 功能符合性（Requirement Compliance）

對比開發文件，各項功能實作狀態如下：

| 功能項目 | 文件要求 | 實作狀態 | 差異說明 |
| :--- | :--- | :--- | :--- |
| **F1：總覽頁面** | 1. 顯示目前公開 IP（來自 `ProcessPublicIpState`）<br>2. 顯示最多 3 張 Provider 狀態卡片<br>3. 未更新前卡片顯示「Initializing...」<br>4. 自動刷新 | **部分實作** | 1. **資料來源不符**：目前公開 IP 是從快照中動態推導出來的，而非讀取 `ddns.zig` 中的私有變數 `process_public_ip_state`（該變數未暴露 API 供外部讀取）。<br>2. **自動刷新時間不符**：JS 輪詢時間硬編碼為 5 秒，而非文件要求的 30 秒（或可配置）。<br>3. 狀態卡片欄位包含 Updated，但在 SSR 階段 Updated 顯示的是原始 Unix 秒數，而非格式化時間，會產生視覺閃爍。 |
| **F2：Provider 狀態卡片** | 依據狀態顯示特定顏色與徽章：<br>- 🔵 initializing (`#64748b`) <br>- ✅ success (`#22c55e`) <br>- ⚠️ retry_deferred (`#f97316`) <br>- ❌ failed (`#ef4444`) <br>- ⬤ disabled (`#6b7280`) <br>- 🔄 updating (`#3b82f6`) | **部分實作** | 1. **狀態顏色混用**：在 `server.zig` CSS 中，`initializing` 與 `retry_deferred` 被強制合併對應到同一個 CSS 變數 `--wait`（`#9a5b13` 橙褐色），並未區分藍灰色與橙色。<br>2. **Hex 顏色不一致**：實際 CSS 採用的 Hex 與設計要求有偏差（例如綠色 `--ok` 為 `#0f7b44`，失敗 `--bad` 為 `#b42318`，更新 `--info` 為 `#175cd3`）。 |
| **F3：詳細資訊側邊欄** | 點擊卡片展開詳細資訊，顯示：<br>- current_ip / desired_ip<br>- status<br>- retry_count<br>- next_retry_at / updated_at (本地時間格式)<br>- last_error | **部分實作** | 1. **版面佈局不符**：實作中並非「側邊欄 (Sidebar)」或「抽屜 (Drawer)」，而是以 full-width 區塊形式插入在卡片下方（`.detail-panel`），在寬螢幕下視覺拉伸過長。<br>2. 欄位內容與格式符合要求。 |
| **F4：JSON API** | 提供 `/api/status`（或 `.json`），讀取處理程序記憶體快照，不連 Redis。 | **部分實作** | 1. **JSON Key 不一致**：API 回傳的 Key 是 `"public_ip"`，而文件 Section 6.3 定義的 Key 是 `"desired_ip"`。<br>2. **遺漏欄位**：回傳的 JSON 根節點完全缺少 `"data_source": "process_memory"` 欄位。 |
| **F5：設定資訊摘要** | `/dashboard/config` 顯示設定（敏感資訊遮罩）。 | **部分實作** | 1. **資訊嚴重遺漏**：實際 Config 頁面僅是簡單的 Key-Value 垂直列表，遺漏了設計稿中的 **Provider 狀態表格**（包含 Enabled、Configured、URL 等）、**主服務更新間隔 (Refresh Interval)** 以及 **資料來源與 Redis 狀態說明**。 |
| **F6：即時狀態更新** | 使用前端 JS 輪詢，每 30 秒自動更新。 | **部分實作** | 1. **硬編碼與頻率過高**：輪詢間隔在前端 JS 被硬編碼為 5 秒（`setInterval(refresh, 5000)`），無法由 `app.json` 配置。<br>2. **缺少控制項**：UI 上缺少設計稿中的 `[⟳ Auto-refresh: ON]` 切換按鈕。 |

### 統計：
* **已完成數量**：0
* **部分完成數量**：6 (F1, F2, F3, F4, F5, F6)
* **未完成數量**：0

---

## 2. UI 與 Wireframe 符合性

對比文件中的 Dashboard Wireframe：

### 缺少或不符的 UI 元件/行為：
1. **Auto-refresh 開關**：缺少 Wireframe 頂部右側的 `[⟳ Auto-refresh: ON]` 互動按鈕，使用者無法暫停輪詢。
2. **Updated/Next 欄位動態切換**：
   - Wireframe 定義在 `failed` 狀態時，卡片第四欄應顯示為 `Next: 16:15`。
   - 實作中卡片第四欄永遠固定顯示為 `Updated`，且在初次載入 (SSR) 時會直接顯示原始 Unix 時間戳秒數（例如 `1781435100`），直到 JS 載入後才被覆寫為本地格式，造成排版閃爍。
3. **詳細資訊區塊 (Detail Panel)**：佈局並非設計稿的右側或 Drawer 浮層，而是滿寬的底部區塊。
4. **Config 頁面表格**：缺少包含 Provider 配置細節與 URL 的 Table 結構。

---

## 3. Jetzig 架構 Review

由於 Zig 0.17 與 Jetzig 現行相依版本的編譯相容性限制，本專案在 `dashboard/` 下保留了 Jetzig scaffold，但實際運行是採用主專案中內建的 `std.http.Server`（即 `src/dashboard/server.zig`）。

### Good Practices
1. **Service 層職責明確**：`src/dashboard/service.zig` 的 `readDisplayData` 和 `classifyDisplayStatus` 成功將「核心 Snapshot」轉換為「UI 顯示狀態」，不與 HTTP Server 的 Request/Response 邏輯混雜。
2. **記憶體快照值複製 (Value-Copy Snapshot)**：`ddns.getProviderSnapshots()` 將執行緒保護限縮在最段時間內，以「值複製」方式回傳 `ProviderSnapshot`，避免 Dashboard 與主排程執行緒產生死鎖。
3. **無堆積配置 (Allocation-Free) 快照**：`ProviderSnapshot` 內部採用固定字元陣列儲存 IP 和 Error 訊息，不產生動態 Heap Memory 分配，避免了記憶體碎片化。

### Potential Problems
1. **使用者空間自旋鎖 (Spinlock)**：
   `ddns.zig` 中的 `lockProcessProviderStates` 實作：
   ```zig
   while (!process_provider_mutex.tryLock()) {
       std.atomic.spinLoopHint();
   }
   ```
   雖然目前 Dashboard server 是單執行緒，但若未來擴充為多執行緒，自旋鎖可能導致極高的 CPU 佔用率。在長期運行的服務中，應改用標準的阻塞互斥鎖（如 `std.Thread.Mutex`）。
2. **阻塞式單執行緒 HTTP 伺服器**：
   `server.zig` 在主執行緒的 `while` 迴圈中同步執行 `handleConnection`，屬於 blocking I/O。如果有瀏覽器發送 Slowloris 惡意慢速請求，或者網路卡頓，整個 Dashboard 將會停止回應。
3. **靜態資源 (Static Assets) 混雜**：
   CSS、HTML 和 JavaScript 均以巨大的多行字串字面量 (string literals) 寫死在 `server.zig` 內。這導致編輯前端程式碼時沒有語法提示，且無法利用瀏覽器靜態檔案快取（因為無法返回 `304 Not Modified`）。

### Refactoring Opportunities
1. **移除/活化 Jetzig Scaffold**：目前 `dashboard/` 子目錄為純 Scaffold，並未參與 build。建議在 Zig 版本相容性解決前，先移除該目錄以保持 codebase 清潔；或者完全改用 Zig 內建 Server 渲染獨立 static files。
2. **前後端分離/範本化**：應將 HTML/CSS/JS 拆分至主專案 `public/` 目錄，透過 HTTP 伺服器讀取檔案並回傳，而非硬編碼於 Zig 原始碼中。

---

## 4. 程式碼品質 Review

### Critical（必須立即修正）
*無*

### Major（重大改善項目）
1. **設定檔欄位命名錯誤 (Typo)**：
   在 [config.zig](file:///D:/Projects/Eddie/dynip/src/base/config.zig#L27) 中，Dynu 設定的欄位被命名為 `dyny`：
   ```zig
   dyny: Dynu = .{},
   ```
   這導致所有調用點如 `service.zig` 的 [readDisplayData](file:///D:/Projects/Eddie/dynip/src/dashboard/service.zig#L54) 與 `server.zig` 均必須寫成 `config.dyny`，嚴重破壞命名一致性。
2. **重複的前端範本程式碼 (DRY Violation)**：
   卡片 UI 結構被實作了兩次：
   - 一次在 Zig SSR：`writeProviderCard`（[server.zig:L345](file:///D:/Projects/Eddie/dynip/src/dashboard/server.zig#L345)）
   - 一次在 JavaScript：`providerCard(p)`（[server.zig:L247](file:///D:/Projects/Eddie/dynip/src/dashboard/server.zig#L247)）
   這導致維護成本加倍，且造成初次渲染與動態重新整理時的欄位格式差異（Unix 秒數 vs 本地時間）。
3. **無限制的 `Allocating` 寫入器**：
   在渲染 HTML 時，使用 `std.ArrayList(u8)` 無限制地追加字串。如果狀態資料中包含超長的 Error 訊息，可能導致記憶體暴漲，缺少寫入長度上限限制。

### Minor（次要改善項目）
1. **自動刷新時間不一致**：前端與 CSS 標示 `5s`，但設計文件要求 `30s` 且應可由 `app.json` 配置。
2. **Provider 數量硬編碼**：`[3]` 的固定陣列長度限制了未來支援更多供應商的彈性。
3. **XSS 潛在風險**：在 [server.zig:L354](file:///D:/Projects/Eddie/dynip/src/dashboard/server.zig#L354) 的 SSR 卡片中，`onclick="showDetail('name')"` 直接輸出 `snap.nameSlice()`。雖然當前的 Provider 名稱均為英文字元（`afraid`, `dynu`, `noip`），但若未來支援動態使用者自訂名稱，此處若含有單引號 `'` 會造成 JS 語法錯誤或潛在 XSS。

---

## 5. 效能與擴充性

1. **N+1 查詢與重複查詢評估**：
   - **完全無 N+1 問題**。Dashboard 僅對主記憶體變數進行複製，完全不存取 Redis 或執行網路 I/O，讀取效能為微秒級。
2. **大量 DDNS 支援度（100、500、1000 筆）**：
   - **目前不支援**。由於實作採用固定長度 `[3]` 的陣列（Afraid, Dynu, No-IP 各佔一個固定的 slot 0, 1, 2），系統完全不具備擴充至多筆/大量動態定義域的架構。若定義域增加，需改用動態切片 (`[]const ProviderSnapshot`) 並在 API 端做分頁或動態迴圈。
3. **Provider 擴充能力**：
   - **擴充性差**。新增一個 Provider 必須修改：
     1. `DdnsProvider` enum (core)
     2. `providerSlot` 對應 (core)
     3. `process_provider_states` 陣列長度 (core)
     4. `service.zig` 內寫死的 `snapshots[0..2]` 對應
     5. `server.zig` 內的渲染迴圈
     此處違反了開閉原則 (Open-Closed Principle)。

---

## 6. 安全性 Review

| 項目 | 安全風險說明 | 風險等級 |
| :--- | :--- | :--- |
| **XSS 風險** | 1. 雖然核心資料如 `last_error` 已經由 `writeHtml` 和 `escapeHtml` 轉義處理。<br>2. 但 [server.zig:L354](file:///D:/Projects/Eddie/dynip/src/dashboard/server.zig#L354) 內嵌在屬性 `showDetail('name')` 的單引號未於 Zig 端進行 JS 轉義，若名稱可控則有語法崩潰與注入風險。 | **Minor (低)** |
| **Input Validation** | Dashboard 僅接受 `GET` 請求，且無 query 參數解析，因此無 injection 風險。 | **None (無)** |
| **CSRF** | Dashboard 為純唯讀狀態面板，無任何狀態變更 API。 | **None (無)** |
| **Sensitive Data 洩漏** | `/dashboard/config` 與 `/api/status` 均正確遮罩了 token 與密碼，僅暴露 enabled、host 和 port。 | **None (無)** |

---

## 7. 文件一致性

1. **README 完全未同步**：
   - `README.md` 與 `README.zh-TW.md` 完全沒有提到 Dashboard 功能，亦未說明如何透過 `app.json` 關閉它，或是預設監聽在 `9003` 連接埠。對終端用戶而言，此背景服務會默默佔用 port 9003 而無從得知。
2. **API 與設計指南偏差**：
   - API 回傳 Key 為 `public_ip`，但開發指南文件標記為 `desired_ip`。
   - API 根節點缺少 `data_source` 欄位。

---

## 8. Review Report Summary

### Executive Summary

* **Overall Score**: **75 / 100**
* **Ready for Production**: **No** (需修正 Typo、文檔不一致與 SSR 時間戳問題)
* **Top 5 Issues**:
  1. **拼寫錯誤 (Typo)**: `config.dyny` 影響代碼可讀性與後續維護。
  2. **README 欠缺說明**: 使用者不知道服務開啟了 9003 Web Port。
  3. **SSR 時間戳顯示錯誤**: 初次載入時 Updated 欄位顯示原始 Unix 秒數，未作時間格式化。
  4. **API 與文件不一致**: API 欄位 `public_ip` 與文件要求之 `desired_ip` 不符，且缺少 `data_source`。
  5. **UI 排版與 Wireframe 有落差**: 卡片顏色混用（Initializing 與 Retry Deferred 均為橙褐色），且缺乏 Auto-refresh 切換按鈕。

---

## Action Items

請依優先順序修正以下項目：

### P0 (必須修正)

1. **修正設定檔拼寫 typo**：
   - **位置**：`src/base/config.zig` 的 `pub const AppConfig` Struct 中，將 `dyny: Dynu = .{},` 修正為 `dynu: Dynu = .{},`。
   - **位置**：同步更新 `src/dashboard/service.zig` 的 `readDisplayData` 與 `src/dashboard/server.zig` 內的所有 `config.dyny` 引用為 `config.dynu`。
2. **修正 SSR 卡片的時間格式化與狀態顯示**：
   - **位置**：`src/dashboard/server.zig` 的 `writeProviderCard`（[server.zig:L345](file:///D:/Projects/Eddie/dynip/src/dashboard/server.zig#L345)）。
   - **說明**：應避免在 SSR HTML 中輸出原始 `snap.updated_at` (i64 Unix timestamp)。應在 Zig 端將其格式化為本地時間字串，或至少讓 JS 載入前卡片 Updated 顯示為 `—`，防止時間顯示為一串長數字。
3. **更新 README 說明文件**：
   - **位置**：`README.md` 與 `README.zh-TW.md`。
   - **說明**：新增 Dashboard 章節，明確列出預設啟用 Web Dashboard（Port 9003），並附上如何在 `app.json` 將 `dashboard.enabled` 設為 `false` 的關閉範例。

### P1 (建議近期修正)

1. **對齊 API 欄位與開發指南**：
   - **位置**：`src/dashboard/server.zig` 的 `renderStatusJson`（[server.zig:L314](file:///D:/Projects/Eddie/dynip/src/dashboard/server.zig#L314)）。
   - **說明**：將 API 根節點的 `"public_ip"` 欄位名稱修改為 `"desired_ip"`，並補上 `"data_source": "process_memory"`。同時更新前端 `refresh()` JS 中對應的解析 Key。
2. **修復卡片顏色不一致問題**：
   - **位置**：`src/dashboard/server.zig` 的 CSS 定義（[server.zig:L399](file:///D:/Projects/Eddie/dynip/src/dashboard/server.zig#L399)）。
   - **說明**：拆分 `.provider.initializing` 與 `.provider.retry_deferred` 的背景顏色設定，讓 `initializing` 使用正確的藍灰色，而非混用橙褐色的 `--wait`。

### P2 (可改善項目)

1. **自旋鎖優化**：
   - **位置**：`src/core/ddns.zig` 的 `lockProcessProviderStates`（[ddns.zig:L719](file:///D:/Projects/Eddie/dynip/src/core/ddns.zig#L719)）。
   - **說明**：將 `std.atomic.Mutex` 自旋鎖改用具備 OS-level thread yielding / blocking 的安全互斥鎖，避免潛在的 CPU 佔用問題。
2. **實作 Auto-refresh 開關**：
   - **位置**：`src/dashboard/server.zig` 的前端 JS 與 HTML。
   - **說明**：補上 `Auto-refresh` 的切換按鈕，允許使用者點擊暫停 `setInterval`。
