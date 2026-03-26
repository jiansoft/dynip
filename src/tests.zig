//! 匯入所有需要跑單元測試的模組。

test {
    // 只要把含有 `test "..." { ... }` 的模組 import 進來，
    // Zig 測試系統就會看見那些測試。
    _ = @import("config.zig");
    // 這一行讓 config 相關測試被收進來。
    _ = @import("ddns.zig");
    // 這一行讓 ddns 相關測試被收進來。
    _ = @import("http_text.zig");
    // 這一行讓 http_text 相關測試被收進來。
    _ = @import("logging.zig");
    // 這一行讓 logging 相關測試被收進來。
    _ = @import("redis.zig");
    // 這一行讓 Redis 客戶端相關測試被收進來。
    _ = @import("scheduler.zig");
    // 這一行讓 scheduler 相關測試被收進來。
}
