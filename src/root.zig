//! 專案共用根模組。
//!
//! 在 Zig 專案裡，`root.zig` 常拿來扮演：
//! - 對內部其他模組提供統一匯入入口
//! - 對外部使用者暴露 package API
//! - 匯總測試入口
//!
//! 這個專案目前偏向「應用程式」而不是「通用 library」，
//! 但仍然保留 `root.zig`，好處是：
//! - `main.zig` 可以保持很薄
//! - `cli.zig` 可以從單一位置拿到共用模組
//! - `zig build test` 可以直接以這個檔案當測試入口
//! - 之後如果要把部分功能抽成可重用 library，會比較容易整理

/// 匯出設定模組。
///
/// 這裡集中放：
/// - `app.json` 載入
/// - `.env` 解析
/// - 環境變數覆寫
/// - 敏感資訊遮罩
pub const config = @import("config.zig");
/// 匯出 DDNS 主流程模組。
///
/// 這裡負責：
/// - 取得 public IP
/// - dedupe 檢查
/// - 更新各家 DDNS provider
pub const ddns = @import("ddns.zig");
/// 匯出 HTTP 文字抓取與預覽輔助模組。
pub const http_text = @import("http_text.zig");
/// 匯出日誌模組。
///
/// 這個模組會接管 `std.log`，並提供檔案 / console 日誌能力。
pub const logging = @import("logging.zig");
/// 匯出 Redis 客戶端包裝模組。
pub const redis = @import("redis.zig");
/// 匯出固定間隔排程器模組。
pub const scheduler = @import("scheduler.zig");

// 匯總整個專案的測試入口。
//
// Zig 的測試系統只要看到被 import 進來的模組內含有 `test "..." { ... }`，
// 就會把那些測試一起收進測試產物裡。
//
// 這裡的設計目的是：
// - 不再另外維護 `src/tests.zig`
// - 讓 `zig build test` 直接從 `src/root.zig` 收集所有單元測試
// - 之後新增模組時，只要在這裡補一行 import 就能納入測試
test {
    // 匯入設定模組，讓 config 相關的 test 被測試系統看見。
    _ = @import("config.zig");
    // 匯入 DDNS 流程模組，收集 ddns 相關測試。
    _ = @import("ddns.zig");
    // 匯入 HTTP 文字工具模組，收集 http_text 相關測試。
    _ = @import("http_text.zig");
    // 匯入日誌模組，收集 logging 相關測試。
    _ = @import("logging.zig");
    // 匯入 Redis 模組，收集 redis 相關測試。
    _ = @import("redis.zig");
    // 匯入排程模組，收集 scheduler 相關測試。
    _ = @import("scheduler.zig");
}
