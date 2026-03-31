//! 可執行檔入口。
//!
//! 常見 Zig 專案會把 `src/main.zig` 保持得很薄，
//! 真正的 CLI / 應用流程則放到其他模組。

/// 匯入 Zig 標準函式庫。
///
/// 這個檔案本身只會用到 `std.process.Init`，
/// 但照慣例還是先把 `std` 匯入進來。
const std = @import("std");
/// 匯入真正負責 CLI 啟動流程的模組。
///
/// `main.zig` 只會把工作轉交給它。
const cli = @import("cli.zig");

/// `std_options` 是 Zig 提供的特殊常數名稱。
///
/// 只要主模組把它公開出去，Zig 標準庫在處理 `std.log` 等功能時，
/// 就會使用這份設定。
///
/// 這裡直接沿用 `cli.zig` 定義好的版本，
/// 這樣可執行檔的 log 行為會和 CLI 啟動流程保持一致。
pub const std_options = cli.std_options;

/// 程式主入口。
///
/// Zig 在啟動時會把程序需要的初始化資源包成 `std.process.Init`，
/// 交給這個函式。
///
/// 這個檔案刻意不做太多事情，只保留一層薄薄的轉呼叫，
/// 讓：
/// - `main.zig` 本身維持簡潔
/// - 真正的 CLI 邏輯集中在 `cli.zig`
/// - 之後要測試或重構 CLI 流程時比較容易
pub fn main(init: std.process.Init) !void {
    // 直接把初始化資源轉交給 CLI 模組。
    try cli.main(init);
}
