//! DDNS 排程器。

/// 匯入 Zig 標準函式庫。
///
/// 排程器會用到 sleep、log 與基本型別工具。
const std = @import("std");
/// 匯入 DDNS 主流程模組。
///
/// 每一輪排程醒來之後，真正執行更新的就是 `ddns` 模組裡的 `refresh(...)`。
const ddns = @import("ddns.zig");
/// 匯入設定模組。
///
/// 排程器需要知道更新間隔秒數與 Redis 設定。
const config_mod = @import("config.zig");

/// 由外部控制的停止旗標。
///
/// `main` 會在收到 SIGINT / SIGTERM 時更新這個旗標，
/// 排程器則在兩輪 refresh 之間與 sleep 期間輪詢它。
pub const StopToken = struct {
    // 這裡保存的是外部傳進來的 atomic 布林旗標位址。
    // 用指標而不是直接存值，才能和 `main` 共享同一份狀態。
    requested: *const std.atomic.Value(bool),

    /// 回傳目前是否已收到停止請求。
    pub fn isRequested(self: StopToken) bool {
        // 用 `.load(.monotonic)` 讀取 atomic 布林值，
        // 這樣多執行路徑之間讀寫才不會形成 data race。
        return self.requested.load(.monotonic);
    }
};

/// 以固定間隔重複執行 DDNS 更新。
///
/// 當 `stop_token` 為 `null` 時會持續執行；
/// 當 `stop_token` 存在且被設成 stop 時，會在安全邊界結束循環。
pub fn runForever(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.AppConfig,
    stop_token: ?StopToken,
) !void {
    // 如果設定裡把秒數寫成 0，
    // 就退回預設值 60 秒，避免服務變成不合理的超高速輪詢。
    // 這裡用三元式寫法，是為了把「0 視為未設定」的規則集中在一行表達。
    const interval_seconds = if (config.ddns.refresh_interval_seconds == 0)
        // 真的沒設定時就退回 60 秒，避免服務變成超高速輪詢。
        @as(u64, 60)
        // 否則就使用設定檔裡指定的秒數。
    else
        config.ddns.refresh_interval_seconds;

    // 服務啟動時先記一筆日誌，
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

    // 建立一個 HTTP 客戶端，整個服務生命週期重複使用它。
    // 這可以避免每一輪 refresh 都重新初始化 TLS 狀態（rescanning CA certificates）。
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    // `while (true)` 代表無限迴圈。
    // 對常駐服務來說，這就是「一直跑下去」的核心。
    while (true) {
        // 每輪開始前先檢查一次是否有人要求停止，
        // 這樣可以在開始新工作前安全退出。
        if (isStopRequested(stop_token)) {
            // 寫一筆日誌，表示這次離開不是錯誤，而是收到關閉要求。
            std.log.info("ddns scheduler received shutdown request", .{});
            // 直接 return，讓上層 `main` 繼續做後續收尾。
            return;
        }

        // 嘗試做一次 DDNS 更新。
        // 這裡故意把成功結果丟掉，因為排程器只在乎「有沒有錯」。
        _ = ddns.refresh(allocator, io, &client, config) catch |err| {
            // 如果更新失敗，先記錄錯誤。
            std.log.err("scheduled ddns refresh failed: {}", .{err});

            // 失敗後先短暫睡 5 秒，避免錯誤狀況下瘋狂重試。
            try sleepUntilNextRun(io, 5, stop_token);

            // `continue` 代表直接進入下一輪 while 迴圈。
            continue;
        };

        // 如果這一輪成功，就按照正常設定的間隔等待下一次。
        try sleepUntilNextRun(io, interval_seconds, stop_token);
    }
}

/// 統一處理 optional stop token 的查詢。
///
/// 沒有提供 token 時，一律視為沒有停止請求。
fn isStopRequested(stop_token: ?StopToken) bool {
    // 如果真的有提供 stop token，
    // 就呼叫它自己的 `isRequested()` 來查詢狀態。
    // 如果沒有提供 stop token，代表這次排程不支援外部停止，
    // 所以直接回傳 false。
    return if (stop_token) |token| token.isRequested() else false;
}

/// 用較短的 sleep 切片輪詢停止旗標，避免 shutdown 卡在長 sleep。
///
/// 這能讓 scheduler 在等待下一輪 refresh 時，
/// 也能在 1 秒內響應停止請求。
fn sleepUntilNextRun(
    io: std.Io,
    total_seconds: u64,
    stop_token: ?StopToken,
) !void {
    // 先把總共要睡多久記在 `remaining`，
    // 後面每醒來一次就把它遞減。
    var remaining = total_seconds;
    // 只要還有剩餘秒數，就持續分段 sleep。
    while (remaining != 0) {
        // 每次 sleep 前都先檢查一次停止旗標，
        // 這樣不用等整段 sleep 跑完才能停。
        if (isStopRequested(stop_token)) return;

        // 一次最多只睡 1 秒，
        // 這就是「可較快響應 shutdown」的關鍵。
        const chunk_seconds = @min(remaining, 1);
        // 真的睡這一小段時間。
        try io.sleep(.fromSeconds(@intCast(chunk_seconds)), .awake);
        // 睡完後把剩餘秒數扣掉，
        // 下一輪就知道還要不要繼續等。
        remaining -= chunk_seconds;
    }
}

test "stop token reflects atomic shutdown flag" {
    var requested = std.atomic.Value(bool).init(false);
    const token = StopToken{ .requested = &requested };

    try std.testing.expect(!token.isRequested());
    requested.store(true, .monotonic);
    try std.testing.expect(token.isRequested());
}
