//! 檔案日誌模組。
//!
//! 這份 Zig 版主要移植 Rust 專案 logging 的核心能力：
//! - 依等級分流到不同檔案：info / warn / error / debug
//! - 依日期切換檔名
//! - 清理超過保留天數的舊日誌
//! - 透過 `std_options.logFn` 接管 `std.log`

/// 匯入編譯期平台資訊。
///
/// logging 需要知道目前是不是 Windows，才能選對時間 API。
const builtin = @import("builtin");
/// 匯入 Zig 標準函式庫。
///
/// 這裡會用到檔案、格式化輸出、路徑、時間與同步原語。
const std = @import("std");

/// 匯入 C 的 `time.h`。
///
/// 非 Windows 平台會用這裡的時間函式來取得本地時間。
const c = @cImport({
    @cInclude("time.h");
});

/// 只有在 Windows 時才匯入 Win32 API。
///
/// 這樣 `GetLocalTime` 之類的函式才能在 Windows 版 logging 使用。
const win = if (builtin.os.tag == .windows)
    @cImport({
        @cInclude("windows.h");
    })
else
    struct {};

/// 日誌資料夾名稱。
///
/// 之後所有 log 檔都會放在 `./log/` 下面。
pub const default_log_dir = "log";
/// 日誌檔名中的主名稱。
///
/// 最後檔名會長得像：
/// `2026-03-25_dynip_info.log`
pub const default_log_name = "dynip";

/// 舊日誌保留天數。
///
/// 超過這個天數的舊檔會被清掉。
const default_max_age_days: i64 = 7;

/// 確保 log 目錄存在。
fn ensureLogDir(io: std.Io) !void {
    std.Io.Dir.cwd().createDir(io, default_log_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// 用來表示「本地時間」的一份結構。
///
/// 我們把時間拆成：
/// - 年月日
/// - 時分秒
/// - Unix timestamp
///
/// 這樣後面在組檔名與格式化 log line 時會方便很多。
const LocalDateTime = struct {
    /// Unix epoch 秒數，方便拿來和檔案修改時間做比較。
    unix_seconds: i64,
    /// 年，例如 2026。
    year: i32,
    /// 月，1 到 12。
    month: u8,
    /// 日，1 到 31。
    day: u8,
    /// 小時，0 到 23。
    hour: u8,
    /// 分鐘，0 到 59。
    minute: u8,
    /// 秒，0 到 59。
    second: u8,
};

/// 管理某一個 log level 的檔案輪替狀態。
///
/// 例如 info、warn、error、debug 各自都會有一個 `Rotate`。
const Rotate = struct {
    /// 這個 Rotate 管的是哪個等級，例如 `"info"`。
    level_name: []const u8,
    /// 目前打開的檔案屬於哪一年。
    current_year: i32 = 0,
    /// 目前打開的檔案屬於哪一月。
    current_month: u8 = 0,
    /// 目前打開的檔案屬於哪一天。
    current_day: u8 = 0,
    /// 目前這個檔案已經寫了多少 byte。
    current_size: u64 = 0,
    /// 目前真正打開中的檔案 handle。
    file: ?std.Io.File = null,
    /// 暫時拿來組路徑字串的固定 buffer。
    path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,

    /// 建立一個新的 Rotate 狀態。
    fn init(level_name: []const u8) Rotate {
        // 這裡只需要把 level_name 放進去，其他欄位都用預設值即可。
        return .{ .level_name = level_name };
    }

    /// 關閉目前打開的檔案。
    fn deinit(self: *Rotate, io: std.Io) void {
        // `if (self.file) |file|` 的意思是：
        // 如果現在真的有打開檔案，就把那個檔案取出來處理。
        if (self.file) |file| {
            // 先把檔案關閉。
            file.close(io);
            // 再把欄位設回 null，表示目前沒有任何檔案是打開狀態。
            self.file = null;
        }
    }

    /// 寫入一整行已格式化完成的 log。
    fn writeLine(
        self: *Rotate,
        io: std.Io,
        now: LocalDateTime,
        level: std.log.Level,
        scope_name: ?[]const u8,
        message: []const u8,
    ) !void {
        // 在真的寫入前，先確認今天的檔案有沒有準備好。
        // 這裡會處理「第一次寫」、「跨日切新檔」等情況。
        try self.ensureReady(io, now);

        // 每一筆日誌都先格式化成一整行字串，再一次寫進檔案。
        var line_buffer: [8192]u8 = undefined;
        const line = try formatLogLine(&line_buffer, now, level, scope_name, message);

        // 取出目前打開中的檔案。
        const file = self.file orelse return error.LoggerFileNotOpen;
        // 以串流方式把整行文字完整寫入。
        try file.writeStreamingAll(io, line);
        // 同步更新目前檔案大小統計。
        self.current_size += line.len;
    }

    /// 確保目前要寫的那一天的檔案已經打開。
    fn ensureReady(self: *Rotate, io: std.Io, now: LocalDateTime) !void {
        // 只要有任一條件成立，就代表要重新準備檔案：
        // - 還沒有任何檔案打開
        // - 年月日改變了，也就是跨日了
        const day_changed = self.file == null or
            self.current_year != now.year or
            self.current_month != now.month or
            self.current_day != now.day;

        if (day_changed) {
            // 先把新的年月日記下來。
            self.current_year = now.year;
            self.current_month = now.month;
            self.current_day = now.day;
            // 新檔案的大小也要重新計算。
            self.current_size = 0;
            // 打開今天對應的檔案。
            try self.openCurrentFile(io, now);
            // 順手清理太舊的歷史檔案。
            self.cleanupOldFiles(io, now);
        }
    }

    /// 打開目前日期對應的日誌檔。
    fn openCurrentFile(self: *Rotate, io: std.Io, now: LocalDateTime) !void {
        // 先把之前可能打開的檔案關掉，避免檔案 handle 泄漏。
        self.deinit(io);

        // 確保 `log/` 目錄存在，不存在就自動建立。
        try ensureLogDir(io);

        // 組出這次要打開的路徑。
        const path = try self.buildCurrentPath(now);
        // 用「如果檔案不存在就建立，已存在就保留內容」的方式打開。
        var file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = false,
        });

        // 讀取檔案目前已有的大小，這樣續寫時才知道從哪裡接。
        const existing_size = file.length(io) catch 0;

        // 這一小段是在把 writer 的位置移到檔尾。
        // 否則後面寫入可能會從檔案開頭覆蓋舊內容。
        var seek_buffer: [64]u8 = undefined;
        var writer = file.writer(io, &seek_buffer);
        try writer.seekTo(existing_size);
        try writer.flush();

        // 把這個已打開的檔案放回 Rotate 狀態裡。
        self.file = file;
        // 記錄目前已存在的大小。
        self.current_size = existing_size;
    }

    /// 根據日期與等級組出檔名。
    fn buildCurrentPath(self: *Rotate, now: LocalDateTime) ![]const u8 {
        // `bufPrint` 的整數格式化比較習慣用 unsigned，
        // 所以先把 year 轉成 `u32`。
        const year: u32 = @intCast(now.year);

        return std.fmt.bufPrint(
            &self.path_buffer,
            "{s}/{d:0>4}-{d:0>2}-{d:0>2}_{s}_{s}.log",
            .{ default_log_dir, year, now.month, now.day, default_log_name, self.level_name },
        );
    }

    /// 清掉超過保留天數的舊日誌。
    fn cleanupOldFiles(self: *Rotate, io: std.Io, now: LocalDateTime) void {
        // 這個函式不需要用到 `self` 的欄位，所以明確丟掉，避免編譯器警告。
        _ = self;

        // 用 iterate 模式打開 `log/` 目錄，準備逐檔掃描。
        var dir = std.Io.Dir.cwd().openDir(io, default_log_dir, .{ .iterate = true }) catch return;
        defer dir.close(io);

        // 建立目錄迭代器。
        var iter = dir.iterate();
        // 算出「太舊」的分界點。
        const cutoff = now.unix_seconds - (default_max_age_days * 24 * 60 * 60);

        // 一個檔案一個檔案往下看。
        while (iter.next(io) catch return) |entry| {
            // 只處理一般檔案，資料夾或其他類型都跳過。
            if (entry.kind != .file) continue;

            // 取出這個檔案的 metadata。
            const stat = dir.statFile(io, entry.name, .{}) catch continue;
            // 修改時間還在保留期限內，就不用刪。
            if (stat.mtime.toSeconds() > cutoff) continue;

            // 超過保留期限就刪掉。
            dir.deleteFile(io, entry.name) catch |err| {
                errorConsoleFmt("failed to delete old log file {s}: {}", .{ entry.name, err });
            };
        }
    }
};

const Logger = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    info_rotate: Rotate = Rotate.init("info"),
    warn_rotate: Rotate = Rotate.init("warn"),
    error_rotate: Rotate = Rotate.init("error"),
    debug_rotate: Rotate = Rotate.init("debug"),

    fn deinit(self: *Logger) void {
        // 因為 logger 可能同時被多執行路徑碰到，
        // 所以先上鎖，確保關檔過程不會和寫檔互相打架。
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // 依序把四種等級的檔案都關掉。
        self.info_rotate.deinit(self.io);
        self.warn_rotate.deinit(self.io);
        self.error_rotate.deinit(self.io);
        self.debug_rotate.deinit(self.io);
    }

    fn rotateForLevel(self: *Logger, level: std.log.Level) *Rotate {
        // 根據 log level，選出對應的 Rotate 狀態。
        return switch (level) {
            .info => &self.info_rotate,
            .warn => &self.warn_rotate,
            .err => &self.error_rotate,
            .debug => &self.debug_rotate,
        };
    }

    fn writeRendered(
        self: *Logger,
        level: std.log.Level,
        scope_name: ?[]const u8,
        message: []const u8,
    ) void {
        // 先拿到「現在的本地時間」。
        const now = localNow() catch {
            errorConsole("failed to get local time for logger");
            return;
        };

        // 寫檔時上鎖，避免多條 log 同時寫壞同一個檔案。
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // 找到這個 log level 對應的 Rotate。
        const rotate = self.rotateForLevel(level);
        // 再把這筆 log 寫進那個等級自己的檔案。
        rotate.writeLine(self.io, now, level, scope_name, message) catch |err| {
            errorConsoleFmt("failed to write log file: {}", .{err});
        };
    }
};

var global_logger: ?Logger = null;

/// 初始化全域 logger。
pub fn init(io: std.Io) !void {
    // 如果已經初始化過，就直接返回，避免重複初始化。
    if (global_logger != null) return;

    // 先確保 log 目錄存在。
    try ensureLogDir(io);
    // 再把全域 logger 建立起來。
    global_logger = .{ .io = io };
}

/// 關閉目前打開的日誌檔。
pub fn deinit() void {
    // 如果 logger 存在，就做真正的清理工作。
    if (global_logger) |*logger| {
        logger.deinit();
        global_logger = null;
    }
}

/// 讓 `std.log` 的訊息同時寫到檔案與主控台。
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // 先把 `std.log.info("hello {}", .{name})` 這種格式化訊息，
    // 轉成一段真正的文字。
    var message_buffer: [4096]u8 = undefined;
    const rendered = std.fmt.bufPrint(&message_buffer, format, args) catch "<log message too long>";

    // 如果全域 logger 已經初始化，就把這筆訊息寫進檔案。
    if (global_logger) |*logger| {
        // `scope == .default` 代表沒有特別的分類，就用 null 表示。
        const scope_name = if (scope == .default) null else @tagName(scope);
        logger.writeRendered(level, scope_name, rendered);
        // console 也直接用同一份已格式化字串輸出，
        // 避免檔案和終端機顯示不同步。
        writeRenderedToConsole(level, scope_name, rendered);
        return;
    }

    // 如果 logger 尚未初始化，仍然直接輸出到 console，
    // 避免初始化前的錯誤訊息被吞掉。
    writeRenderedToConsole(level, if (scope == .default) null else @tagName(scope), rendered);
}

/// 直接寫入 info 檔案。
pub fn infoFile(message: []const u8) void {
    writeDirect(.info, null, message);
}

/// 直接寫入 warn 檔案。
pub fn warnFile(message: []const u8) void {
    writeDirect(.warn, null, message);
}

/// 直接寫入 error 檔案。
pub fn errorFile(message: []const u8) void {
    writeDirect(.err, null, message);
}

/// 直接寫入 debug 檔案。
pub fn debugFile(message: []const u8) void {
    writeDirect(.debug, null, message);
}

/// 直接寫到某個等級的檔案，不經過 `std.log`。
///
/// 這種 API 適合 logger 自己內部使用，避免遞迴呼叫 `logFn`。
fn writeDirect(level: std.log.Level, scope_name: ?[]const u8, message: []const u8) void {
    if (global_logger) |*logger| {
        logger.writeRendered(level, scope_name, message);
    }
}

/// 直接輸出 info 到主控台，不走 `std.log`，避免 logger 內部錯誤遞迴呼叫。
pub fn infoConsole(message: []const u8) void {
    consoleWithLevel("Info", message);
}

/// 直接輸出 error 到主控台，不走 `std.log`，避免 logger 內部錯誤遞迴呼叫。
pub fn errorConsole(message: []const u8) void {
    consoleWithLevel("Error", message);
}

/// 先格式化字串，再直接輸出到 console。
pub fn errorConsoleFmt(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch "<logger internal error>";
    errorConsole(text);
}

/// 用固定格式把訊息印到主控台。
fn consoleWithLevel(level_text: []const u8, message: []const u8) void {
    var timestamp_buffer: [32]u8 = undefined;
    const timestamp = formatConsoleTimestamp(&timestamp_buffer) catch "0000-00-00 00:00:00";
    std.debug.print("{s} {s} {s}\n", .{ timestamp, level_text, message });
}

/// 把 `std.log` 已格式化完成的訊息直接鏡像到 console。
fn writeRenderedToConsole(
    level: std.log.Level,
    scope_name: ?[]const u8,
    message: []const u8,
) void {
    if (scope_name) |scope_text| {
        std.debug.print("{s}({s}): {s}\n", .{ levelText(level), scope_text, message });
    } else {
        std.debug.print("{s}: {s}\n", .{ levelText(level), message });
    }
}

/// 產生 console 用的時間字串，例如 `2026-03-25 18:30:00`。
fn formatConsoleTimestamp(buffer: []u8) ![]const u8 {
    const now = try localNow();
    return std.fmt.bufPrint(
        buffer,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{ now.year, now.month, now.day, now.hour, now.minute, now.second },
    );
}

fn formatLogLine(
    buffer: []u8,
    now: LocalDateTime,
    level: std.log.Level,
    scope_name: ?[]const u8,
    message: []const u8,
) ![]const u8 {
    // 先把年轉成 unsigned，方便後面用格式字串補零輸出。
    const year: u32 = @intCast(now.year);

    // 如果有分類，就輸出成 `info(ddns)` 這種格式。
    return if (scope_name) |scope_text|
        std.fmt.bufPrint(
            buffer,
            "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}({s}) {s}\n",
            .{ year, now.month, now.day, now.hour, now.minute, now.second, levelText(level), scope_text, message },
        )
        // 沒有分類時，就只輸出等級與訊息。
    else
        std.fmt.bufPrint(
            buffer,
            "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s} {s}\n",
            .{ year, now.month, now.day, now.hour, now.minute, now.second, levelText(level), message },
        );
}

/// 把 `std.log.Level` 轉成我們想寫進檔案的文字。
fn levelText(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
}

/// 取得目前本地時間。
///
/// 這裡依平台分兩條路：
/// - Windows: 用 `GetLocalTime`
/// - 其他平台: 用 `localtime_r`
fn localNow() !LocalDateTime {
    if (builtin.os.tag == .windows) {
        // Windows 版本直接請 Win32 API 幫我們填入本地時間。
        var local_time: win.SYSTEMTIME = undefined;
        win.GetLocalTime(&local_time);
        // 同時另外拿 Unix 秒數，方便日後做舊檔清理。
        const unix_time: c.time_t = c.time(null);

        return .{
            .unix_seconds = @as(i64, @intCast(unix_time)),
            .year = local_time.wYear,
            .month = @intCast(local_time.wMonth),
            .day = @intCast(local_time.wDay),
            .hour = @intCast(local_time.wHour),
            .minute = @intCast(local_time.wMinute),
            .second = @intCast(local_time.wSecond),
        };
    } else {
        // 非 Windows 先拿現在的 Unix 秒數。
        var unix_time: c.time_t = c.time(null);
        // 再請 `localtime_r` 幫我們拆成本地年月日時分秒。
        var local_tm: c.struct_tm = undefined;
        _ = c.localtime_r(&unix_time, &local_tm) orelse return error.LocalTimeUnavailable;

        return .{
            .unix_seconds = @as(i64, @intCast(unix_time)),
            .year = local_tm.tm_year + 1900,
            .month = @intCast(local_tm.tm_mon + 1),
            .day = @intCast(local_tm.tm_mday),
            .hour = @intCast(local_tm.tm_hour),
            .minute = @intCast(local_tm.tm_min),
            .second = @intCast(local_tm.tm_sec),
        };
    }
}

test "build file name uses one file per day" {
    var rotate = Rotate.init("info");
    const now = LocalDateTime{
        .unix_seconds = 0,
        .year = 2026,
        .month = 3,
        .day = 25,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };

    try std.testing.expectEqualStrings(
        "log/2026-03-25_dynip_info.log",
        try rotate.buildCurrentPath(now),
    );
}

test "format log line includes scope when present" {
    // 這個測試確認分類存在時，格式會長成 `info(ddns)`。
    var buffer: [256]u8 = undefined;
    const now = LocalDateTime{
        .unix_seconds = 0,
        .year = 2026,
        .month = 3,
        .day = 25,
        .hour = 8,
        .minute = 9,
        .second = 10,
    };

    const line = try formatLogLine(&buffer, now, .info, "ddns", "hello");
    try std.testing.expectEqualStrings(
        "2026-03-25 08:09:10 info(ddns) hello\n",
        line,
    );
}
