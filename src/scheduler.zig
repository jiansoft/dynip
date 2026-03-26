//! DDNS 排程器。

/// 匯入 Zig 標準函式庫。
///
/// 排程器會用到 sleep、log 與基本型別工具。
const std = @import("std");
/// 匯入 DDNS 主流程模組。
///
/// 每一輪排程醒來之後，真正執行更新的就是 `ddns.refresh(...)`。
const ddns = @import("ddns.zig");
/// 匯入設定模組。
///
/// 排程器需要知道 refresh 間隔秒數與 Redis 設定。
const config_mod = @import("config.zig");

/// 以固定間隔重複執行 DDNS refresh。
pub fn runForever(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.AppConfig,
) !void {
    // 如果設定裡把秒數寫成 0，
    // 就退回預設值 60 秒，避免 service 變成不合理的超高速輪詢。
    const interval_seconds = if (config.ddns.refresh_interval_seconds == 0)
        @as(u64, 60)
    else
        config.ddns.refresh_interval_seconds;

    // service 啟動時先記一筆日誌，
    // 讓你知道目前排程間隔與 Redis 目標位置。
    std.log.info(
        "ddns scheduler started: interval={d}s, redis_enabled={}, redis_addr={s}, redis_db={d}",
        .{
            interval_seconds,
            config.ddns.redis.enabled,
            config.ddns.redis.addr,
            config.ddns.redis.db,
        },
    );

    // `while (true)` 代表無限迴圈。
    // 對常駐 service 來說，這就是「一直跑下去」的核心。
    while (true) {
        // 嘗試做一次 DDNS refresh。
        // 這裡故意把成功結果丟掉，因為排程器只在乎「有沒有錯」。
        _ = ddns.refresh(allocator, io, config) catch |err| {
            // 如果 refresh 失敗，先記錄錯誤。
            std.log.err("scheduled ddns refresh failed: {}", .{err});

            // 失敗後先短暫睡 5 秒，避免錯誤狀況下瘋狂重試。
            try io.sleep(.fromSeconds(5), .awake);

            // `continue` 代表直接進入下一輪 while 迴圈。
            continue;
        };

        // 如果這一輪成功，就按照正常設定的間隔等待下一次。
        try io.sleep(.fromSeconds(@intCast(interval_seconds)), .awake);
    }
}
