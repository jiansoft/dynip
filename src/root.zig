//! 專案核心函式庫入口 (Library Root)。
//!
//! 在 Zig 的慣用佈局中，`root.zig` 是作為 Package 的導出入口。
//! 這讓本專案的邏輯可以被其他 Zig 專案作為模組引用，也作為單元測試的匯總點。

const std = @import("std");

// --- 導出子模組 (Public Modules) ---
// 這樣外部在使用本模組時，可以透過 `@import("dynip").config` 存取。

pub const config = @import("base/config.zig");
pub const ddns = @import("core/ddns.zig");
pub const http = @import("io/http.zig");
pub const logging = @import("io/logging.zig");
pub const redis = @import("io/redis.zig");
pub const scheduler = @import("core/scheduler.zig");

// --- 測試匯總 (Test Suite) ---
// 確保 `zig build test` 能遞迴抓到所有子模組的測試。
test {
    // 這裡使用 inline else 或是單純的載入。
    // 在 Zig 中，這會觸發子模組內的 `test` 區塊編譯。
    _ = config;
    _ = ddns;
    _ = http;
    _ = logging;
    _ = redis;
    _ = scheduler;
}
