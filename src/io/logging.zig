//! 檔案與 console 日誌的組裝層。
//!
//! 這個模組負責把 `std.log.info(...)`、`std.log.err(...)` 這類 Zig 標準日誌，
//! 接到本專案自己的檔案、console 與 Seq 輸出。
//!
//! 給初學者看的重點：
//! - `//!` 是「檔案或模組等級」的 Zigdoc，通常用來說明整份檔案的用途。
//! - `///` 是「下一個宣告」的 Zigdoc，通常用來說明函式、常數、struct 或欄位。
//! - 一般 `//` 是實作註解，適合說明某一行為什麼要這樣寫。
//!
//! 實作依職責拆成三個子模組，這個檔只做組裝與對外 API：
//! - `logging/format.zig`：本地時間取得、log 行格式化、console 輸出。
//! - `logging/rotate.zig`：依日期與大小輪轉檔案、清除過期日誌。
//! - `logging/seq.zig`：把同一筆 log 以 CLEF 格式送到 Seq。
//!
//! 這一層做的事：
//! - 依日誌等級分成 `info`、`warn`、`error`、`debug` 四個檔案，各自一個 `Rotate`。
//! - 用 runtime 等級分別過濾 console、檔案與 Seq 輸出。
//! - 同一筆 log 同時寫入檔案與 console，方便開發時直接看終端機。
//! - 使用 Zig 0.16 的 `std.Io` API，不再使用舊版 std.fs API。

const std = @import("std");

/// 匯入設定模組，讓 logger 能接收日誌等級與 Seq 相關設定。
const config_mod = @import("../base/config.zig");

/// 時間取得與 log 行格式化。
const format_mod = @import("logging/format.zig");

/// 檔案輪轉與過期清理。
const rotate_mod = @import("logging/rotate.zig");

/// Seq 遠端日誌推送。
const seq_mod = @import("logging/seq.zig");

// 讓子模組的測試也被 `zig build test` 收進來。
test {
    _ = format_mod;
    _ = rotate_mod;
    _ = seq_mod;

    // Zig 是惰性分析：沒有被引用到的函式不會做語意檢查。
    // `Logger` 與這裡的公開 API 只有 exe 路徑（`cli.zig`）才會用到，
    // 少了這一行，「子模組成員忘了標 pub」這種錯誤只會在 `zig build` 時炸，
    // `zig build test` 反而是綠的。refAllDecls 會把本檔所有公開宣告拉進來分析。
    std.testing.refAllDecls(@This());
}

/// 日誌資料夾名稱；實作在 `logging/rotate.zig`，這裡重新匯出維持既有呼叫方式。
pub const default_log_dir = rotate_mod.default_log_dir;

/// 日誌檔名中的服務名稱；同時作為送往 Seq 的 `Service` 欄位。
pub const default_log_name = rotate_mod.default_log_name;

/// 由檔名解析日期，供外部工具沿用同一套規則。
pub const parseLogDateFromFilename = rotate_mod.parseLogDateFromFilename;

/// 計算日期距離基準點的天數。
pub const daysSinceEpoch = rotate_mod.daysSinceEpoch;

/// 直接輸出一行錯誤到 console，logger 尚未初始化時也能用。
pub const errorConsoleFmt = format_mod.errorConsoleFmt;

/// runtime 可設定的最低日誌等級。
const RuntimeLogLevel = enum {
    debug,
    info,
    warn,
    err,
};

/// 全域 logger 的主要狀態。
///
/// 一個 `Logger` 持有四個 `Rotate`，也就是四種 log level 各一個檔案輪替器。
const Logger = struct {
    /// Zig 0.16 的 IO 介面。
    ///
    /// 檔案讀寫、sleep、網路等操作都會透過它執行。
    io: std.Io,
    /// 保護檔案寫入的 mutex。
    ///
    /// 如果未來有多個 thread 或 async 路徑同時打 log，這把鎖可以避免日誌行互相交錯。
    mutex: std.Io.Mutex = .init,
    /// info 等級的檔案輪替器。
    info_rotate: rotate_mod.Rotate = rotate_mod.Rotate.init("info"),
    /// warn 等級的檔案輪替器。
    warn_rotate: rotate_mod.Rotate = rotate_mod.Rotate.init("warn"),
    /// error 等級的檔案輪替器。
    error_rotate: rotate_mod.Rotate = rotate_mod.Rotate.init("error"),
    /// debug 等級的檔案輪替器。
    debug_rotate: rotate_mod.Rotate = rotate_mod.Rotate.init("debug"),
    /// console 最低輸出等級。
    console_level: RuntimeLogLevel = .info,
    /// 檔案日誌最低輸出等級。
    file_level: RuntimeLogLevel = .info,
    /// 舊日誌保留天數。
    max_age_days: i64 = rotate_mod.default_max_age_days,
    /// 單檔大小上限（bytes）；`0` 代表停用大小輪轉。
    max_size_bytes: u64 = rotate_mod.default_max_size_bytes,
    /// Seq 最低送出等級。
    seq_level: RuntimeLogLevel = .warn,
    /// Seq 遠端日誌 sink。`null` 代表未啟用或設定不完整。
    seq_sink: ?seq_mod.SeqSink = null,
    /// 避免 Seq 故障時每筆 log 都在 console 洗版。
    seq_failure_reported: bool = false,

    /// 關閉 logger 裡所有已開啟檔案。
    fn deinit(self: *Logger) void {
        // 關檔期間也上鎖，避免另一個執行路徑正在寫入同一個檔案。
        self.mutex.lockUncancelable(self.io);
        // `defer` 代表函式離開時一定會解鎖，即使中間提早 return 也一樣。
        defer self.mutex.unlock(self.io);

        // 逐一關閉四種等級的檔案。
        self.info_rotate.deinit(self.io);
        self.warn_rotate.deinit(self.io);
        self.error_rotate.deinit(self.io);
        self.debug_rotate.deinit(self.io);
        // Seq sink 內部持有 HTTP client，也需要釋放連線池資源。
        if (self.seq_sink) |*sink| {
            sink.deinit();
            self.seq_sink = null;
        }
    }

    /// 根據 log level 選出對應的輪替器。
    fn rotateForLevel(self: *Logger, level: std.log.Level) *rotate_mod.Rotate {
        // 回傳指標，呼叫端才能直接修改對應 Rotate 裡的檔案狀態。
        return switch (level) {
            .info => &self.info_rotate,
            .warn => &self.warn_rotate,
            .err => &self.error_rotate,
            .debug => &self.debug_rotate,
        };
    }

    /// 把已格式化好的訊息寫到對應檔案。
    fn writeRendered(
        self: *Logger,
        level: std.log.Level,
        scope_name: ?[]const u8,
        message: []const u8,
    ) void {
        // 取得目前本地時間；如果時間 API 失敗，這筆檔案日誌就略過。
        const now = format_mod.localNow() catch return;

        // 寫檔前上鎖，避免多個 log 同時寫入造成內容交錯。
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (shouldWriteLevel(level, self.file_level)) {
            // 找到這個 level 對應的檔案輪替器。
            const rotate = self.rotateForLevel(level);
            // 寫入失敗時不讓主程式崩潰，因為 logger 失敗通常不該中斷 DDNS 服務。
            rotate.writeLine(self.io, now, level, scope_name, message) catch {};
        }

        // 如果 Seq 已啟用，把同一筆 log 轉成 CLEF 送出。
        // 失敗時只提示一次，避免遠端日誌服務影響本地服務或造成 console 洗版。
        if (self.seq_sink != null and shouldWriteLevel(level, self.seq_level)) {
            const sink = &self.seq_sink.?;
            sink.write(level, scope_name, message, now) catch |err| {
                if (!self.seq_failure_reported) {
                    self.seq_failure_reported = true;
                    var warning_buffer: [256]u8 = undefined;
                    const warning = std.fmt.bufPrint(
                        &warning_buffer,
                        "seq log ingestion failed: {s}",
                        .{@errorName(err)},
                    ) catch "seq log ingestion failed";
                    format_mod.writeRenderedToConsole(.warn, null, warning);
                }
            };
        }
    }
};

/// 全域 logger 實體。
///
/// `null` 代表尚未初始化。初始化後，`std.log` 才能寫入檔案。
var global_logger: ?Logger = null;

/// 初始化全域 logger。
///
/// 主程式啟動時會呼叫一次。
pub fn init(io: std.Io) !void {
    // 如果已初始化過，就直接返回，避免重複打開檔案。
    if (global_logger != null) return;
    // 先確認 log 目錄存在。
    try rotate_mod.ensureLogDir(io);
    // 建立 logger，並保存目前這份 io。
    global_logger = .{ .io = io };
}

/// 依設定套用 runtime 日誌等級與 Seq 遠端日誌。
///
/// 這個函式會在設定檔與 `.env` 都載入完成後呼叫，所以可以安全使用
/// `LOG_*` 覆寫後的值。
pub fn configure(
    allocator: std.mem.Allocator,
    io: std.Io,
    logging_config: config_mod.Logging,
) !void {
    if (global_logger) |*logger| {
        logger.mutex.lockUncancelable(logger.io);
        defer logger.mutex.unlock(logger.io);

        if (logger.seq_sink) |*sink| {
            sink.deinit();
            logger.seq_sink = null;
        }

        logger.console_level = parseRuntimeLogLevel(logging_config.console_level);
        logger.file_level = parseRuntimeLogLevel(logging_config.file_level);
        logger.seq_level = parseRuntimeLogLevel(logging_config.seq.level);
        logger.max_age_days = logging_config.max_age_days;
        logger.max_size_bytes = rotate_mod.resolveMaxSizeBytes(logging_config.max_size_mb);
        logger.info_rotate.max_age_days = logging_config.max_age_days;
        logger.warn_rotate.max_age_days = logging_config.max_age_days;
        logger.error_rotate.max_age_days = logging_config.max_age_days;
        logger.debug_rotate.max_age_days = logging_config.max_age_days;
        logger.info_rotate.max_size_bytes = logger.max_size_bytes;
        logger.warn_rotate.max_size_bytes = logger.max_size_bytes;
        logger.error_rotate.max_size_bytes = logger.max_size_bytes;
        logger.debug_rotate.max_size_bytes = logger.max_size_bytes;
        logger.seq_sink = try seq_mod.SeqSink.init(allocator, io, logging_config.seq, default_log_name);

        if (format_mod.localNow()) |now| {
            logger.info_rotate.cleanupOldFiles(logger.io, now);
        } else |_| {}
    }
}

/// 關閉全域 logger。
///
/// 主程式結束時呼叫，讓已開啟的檔案 handle 正常釋放。
pub fn deinit() void {
    // 如果 logger 存在，就拿出它的指標做清理。
    if (global_logger) |*logger| {
        // 關閉所有檔案。
        logger.deinit();
        // 清完後設回 null，避免後續誤用已關閉的 logger。
        global_logger = null;
    }
}

/// Zig 標準日誌入口。
///
/// `build.zig` 或 `cli.zig` 會把這個函式指定給 `std_options.logFn`。
/// 之後所有 `std.log.info(...)` 都會進到這裡。
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // 用固定 stack buffer 暫存格式化後的文字，避免每次 log 都 heap allocate。
    var message_buffer: [4096]u8 = undefined;
    // 如果訊息太長放不進 buffer，就用短字串替代，避免 logger 本身再出錯。
    const rendered = std.fmt.bufPrint(&message_buffer, format, args) catch "<msg toolong>";

    // `.default` 代表呼叫端沒有指定 log scope。
    // 有 scope 時，例如 `std.log.scoped(.http)`，就把 scope 名稱轉成字串。
    const scope_name = if (scope == .default) null else @tagName(scope);

    // logger 已初始化時，寫入對應的檔案。
    if (global_logger) |*logger| {
        logger.writeRendered(level, scope_name, rendered);
    }

    // 不管檔案 logger 是否已初始化，console 仍由 runtime level 控制。
    const console_level = if (global_logger) |*logger| logger.console_level else RuntimeLogLevel.info;
    if (shouldWriteLevel(level, console_level)) {
        format_mod.writeRenderedToConsole(level, scope_name, rendered);
    }
}

/// 直接寫一筆 info 等級檔案日誌。
///
/// 這種函式用在已經有完整文字、不想再走 `std.log` 格式化流程的地方。
pub fn infoFile(message: []const u8) void {
    writeDirect(.info, null, message);
}

/// 直接寫一筆 warn 等級檔案日誌。
pub fn warnFile(message: []const u8) void {
    writeDirect(.warn, null, message);
}

/// 直接寫一筆 error 等級檔案日誌。
pub fn errorFile(message: []const u8) void {
    writeDirect(.err, null, message);
}

/// 直接寫入指定等級的檔案，不經過 `std.log`。
fn writeDirect(level: std.log.Level, scope_name: ?[]const u8, message: []const u8) void {
    // logger 尚未初始化時就略過，因為這個 API 的目的只有寫檔。
    if (global_logger) |*logger| logger.writeRendered(level, scope_name, message);
}

fn parseRuntimeLogLevel(value: []const u8) RuntimeLogLevel {
    if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "information")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(value, "error")) return .err;
    return .info;
}

fn runtimeLogLevelRank(level: RuntimeLogLevel) u8 {
    return switch (level) {
        .debug => 0,
        .info => 1,
        .warn => 2,
        .err => 3,
    };
}

fn stdLogLevelRank(level: std.log.Level) u8 {
    return switch (level) {
        .debug => 0,
        .info => 1,
        .warn => 2,
        .err => 3,
    };
}

fn shouldWriteLevel(level: std.log.Level, minimum: RuntimeLogLevel) bool {
    return stdLogLevelRank(level) >= runtimeLogLevelRank(minimum);
}
