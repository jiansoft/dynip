# Changelog

本檔案記錄 dynip 的重要變更。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。
版本號採 `YY.M.D` 形式的日期版本。

---

## [26.7.26]

建置基準：Zig `0.17.0-dev.1282+c0f9b51d8`，`x86_64-windows.win11_br-gnu`。

### 修正

- **[重要] Windows 上 STUN 公網 IP 查詢自導入以來從未成功過。**

  `utils.setSocketTimeout()` 以 POSIX 的 `timeval` 設定接收逾時：

  ```zig
  const opt_bytes = std.mem.asBytes(&timeout_val);   // timeval{ .sec = 2, .usec = 0 }
  std.posix.system.setsockopt(fd, SOL.SOCKET, SO.RCVTIMEO, opt_bytes.ptr, opt_bytes.len);
  ```

  但 Winsock 的 `SO_RCVTIMEO` 收的是一個 **`DWORD` 毫秒值**，不是 `struct timeval`。
  本 Zig 版本的 `std.posix.timeval` 在 Windows 上定義為（`lib/std/c.zig`）：

  ```zig
  .windows => extern struct { sec: c_long, usec: c_long },   // c_long 為 32-bit → 共 8 bytes
  ```

  於是 `timeval{ .sec = 2 }` 的前 4 個 byte 就是 `2`，Winsock 直接把它當毫秒讀走——
  **原本要的 2 秒變成 2 毫秒**。

  這個 bug 之所以能長期存在，是因為它在每一層都不會發出任何訊號：

  1. Winsock 收到長度不符的 option buffer **不回報錯誤**，`setsockopt` 回傳 0，
     單看回傳值無從察覺單位換算寫錯。
  2. STUN 因此每輪都以 `error.ReceiveFailed` 收場，但 `ip_lookup` 的雙來源設計會
     靜默退回 Cloudflare trace，服務外觀完全正常。
  3. 唯一該攔下它的測試反而把它當成「環境沒網路」而放行：

     ```zig
     // 修正前：ReceiveFailed 被視為可接受的環境問題，測試恆綠
     const ip = ip_lookup.fetchStunIp(...) catch |err| switch (err) {
         error.ReceiveFailed, error.SetSocketTimeoutFailed, ... => return,
         else => return err,
     };
     ```

  現改為依平台換算後再送出，POSIX 路徑不變：

  ```zig
  if (comptime builtin.os.tag == .windows) {
      const milliseconds: u32 = @intCast(timeout_val.sec * 1000 + @divTrunc(timeout_val.usec, 1000));
      return setSocketTimeoutOption(fd, std.mem.asBytes(&milliseconds));
  }
  return setSocketTimeoutOption(fd, std.mem.asBytes(&timeout_val));
  ```

  實測結果：

  | 量測項目 | 修正前 | 修正後 |
  |---|---:|---:|
  | `getsockopt` 讀回的生效逾時 | 2 ms | 2000 ms |
  | `recvfrom` 實際阻塞時間 | 16 ms | 2016 ms |
  | 對 `stun.l.google.com` 的 binding request | **0 / 3 成功**（全 `WSAETIMEDOUT`） | **3 / 3 成功** |

  影響範圍僅限 Windows；Linux／Docker 部署不受此 bug 影響。

- **`zig build test` 每次都會把測試二進位執行兩次，並對正式 Redis 送出兩次 `PING`。**

  `live redis ping returns pong` 測試會連線到 `.env` 指定的雲端 Redis。
  它在 build runner 的 `--listen=-` 模式下讓測試行程以非零碼結束，build runner 因而
  重跑整個二進位；第二次通過，所以最終狀態是 success——但輸出裡永遠夾著一行
  `failed command: ...`，讓真正的測試失敗難以辨識。

  以連續 4 次乾淨建置驗證為確定性行為（非偶發）：跳過該測試後 `failed command` 完全消失。

### 行為變更

- **需要對外網路的測試預設不再執行**，改由環境變數 `DYNIP_LIVE_TESTS=1` 開啟：

  ```bash
  zig build test                        # 56 pass, 2 skip — 不碰網路
  DYNIP_LIVE_TESTS=1 zig build test     # 58 pass — 含 live Redis 與真實 STUN
  ```

  受影響的兩個測試是 `live redis ping returns pong` 與 STUN 查詢測試。
  它們原本讓 `zig build test` 的結果取決於本機網路狀態與一組雲端 Redis 憑證，
  在 CI 或離線開發時必定失敗。

- **STUN 測試改為嚴格斷言**，不再把 `ReceiveFailed` / `SetSocketTimeoutFailed`
  當成可接受的環境問題而通過。這正是上述 Windows bug 得以潛伏的原因；
  現在同類問題再次出現時，開啟 live 測試即會直接失敗。

### 安全性

- Dashboard 的 `writeJsonStringContent()` 補上 `<` → `\u003c` 的跳脫。

  `renderDashboardPage()` 會把 provider 狀態 JSON 直接嵌進 `<script>` 區塊。
  瀏覽器解析 `<script>` 內容時是先掃描字面上的 `</script>` 才交給 JS engine，
  因此任何值只要含有 `</script>` 就能提早關閉標籤，形成 HTML injection：

  ```text
  輸入：  </script><img src=x onerror=alert(1)>
  修正前：</script><img src=x onerror=alert(1)>            ← 逃出 script 區塊
  修正後：\u003c/script>\u003cimg src=x onerror=alert(1)>
  ```

  `\u003c` 在 JSON 與 JS 中都還原成同一個 `<` 字元，**前端讀到的值完全不變**，
  只是不再是能結束標籤的字面內容。`>` 單獨出現無法關閉標籤，故維持原樣。

  目前寫入該 JSON 的欄位（`@errorName` 產生的錯誤名稱、已驗證的 IP 字串、
  固定的 provider 名稱）都不含 `<`，因此**這是防禦性補強而非已遭利用的漏洞**；
  但欄位來源日後若擴充，這層跳脫就是必要的。

### 其他

- `std.ArrayListUnmanaged` → `std.ArrayList`（`local_cache.zig`、`cloudflare.zig`）。
  本 Zig 版本的 `lib/std/std.zig` 已明確標註 `Deprecated; use ArrayList`——
  現行的 `std.ArrayList` 本身就是 unmanaged 版本，兩者是同一個型別。

- 環境變數覆寫表的 `key` 型別由 `[]const u8` 改為 `[:0]const u8`。
  `[:0]` 保證字串結尾多帶一個 null byte（Zig 字串字面值本就符合），
  於是 `key.ptr` 可直接當成 `getenv` 要的 `[*:0]const u8`，
  移除原本為了補 null byte 而寫的 `@ptrCast((key ++ .{0}).ptr)`。

- `.env` 與 process 環境變數兩條覆寫路徑改為共用同一個 `applyOverrideLeaky()`。
  原本各自維護一份 `switch (override.kind)` 轉型邏輯，兩邊有機會對同一個 key
  產生不同行為；現在型別轉換規則只有一份。

  另一項副作用是：process env 路徑原本在 `inline for` 中取得 comptime 的
  `override` 後，又把 key 當成執行期字串傳回去逐一比對一次，
  形成 43 × 43 次多餘的字串比較；現已直接套用。

- `zig fmt` — `src/c.zig`、`src/core/ddns/utils.zig`、`src/core/scheduler.zig`
  先前未通過 `zig fmt --check`，現已全數符合。

- `build.zig.zon` 的 `.version` 由 `"0.16.0-dev.2979+e93834410"` 改為 `"26.7.26"`。
  該欄位宣告的是**本專案**的版本，先前填的卻是建立專案時所用的 Zig 版本字串。
  現與本檔案的日期版本一致。

- `build.zig.zon` 新增 `.minimum_zig_version = "0.17.0-dev.1282+c0f9b51d8"`，
  為「本專案需要哪個 Zig 版本」提供明確出處。

  需留意：Zig `0.17.0-dev.1282` 只會解析這個欄位而**不會強制檢查**本專案——
  實測將其設為 `99.0.0` 後 `zig build` 仍然成功且無任何警告。
  因此它目前是文件性質的宣告，不是一道真正的版本關卡。

### 測試

測試數由 56 增加至 58，其中 2 個為預設跳過的 live 測試。新增：

- **`socket receive timeout is applied with the platform's expected unit`** —
  開一個 UDP socket、設定 2 秒逾時後以 `getsockopt` 讀回生效值並斷言為 `2000`（毫秒）。
  這是唯一能攔下上述 Windows bug 的方式：`setsockopt` 的回傳值本身不帶任何資訊。
  本測試不需對外連線，因此可安全地留在預設測試集中。

- **`dashboard json escaping cannot close the embedded script tag`** —
  以 `</script><img ...>` 作為輸入，斷言輸出中不存在字面上的 `</script>`。

---

## [26.7.19]

### 新增

- Docker 部署支援 arm64 / armv7 多架構建置，Dashboard 靜態資源改以 `@embedFile`
  在編譯期烤進 binary。最終 image 只複製單一執行檔，不再需要一併攜帶資源目錄。

---

## [26.7.11]

### 新增

- Cloudflare 成為原生 DNS provider，直接管理 A / AAAA record，
  並以 record comment 作為 ownership selector，讓多個 instance 可安全共存於同一 zone。
- DDNS provider 與其對應設定改為可組態。
- IPv4 與 IPv6 狀態在 Dashboard 上分開呈現，兩者為獨立的工作單位：
  一族失敗不影響另一族更新。
- 新增 Healthchecks、Uptime Kuma 與通用 webhook 的監控掛鉤。

---

## [26.7.10]

### 變更

- `ddns.zig` 拆分為 `src/core/ddns/` 之下的子套件（types、shared_state、local_cache、
  ip_lookup、providers、cloudflare、notifications、utils）。
- 公網 IP 來源精簡為 STUN 與 Cloudflare trace 兩種並輪替使用，
  移除 6 個備援 HTTP 服務。
- Redis 改為啟動時檢查可達性，不可用時降級為行程內去重而非中止服務。

---

## [26.6.16] 及更早

初始版本與後續迭代，包含 Dashboard、Seq 遠端日誌、Redis provider 狀態機、
Zig 0.17 相容性調整與 Windows locale 處理，詳見 Git 歷史。
