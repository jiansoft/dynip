//! 日誌的時間取得與單行格式化。
//!
//! 這個檔只處理「一筆 log 長什麼樣子」與「現在幾點」，不碰檔案輪轉，也不碰 Seq。
//! 檔案輪轉在 `rotate.zig`，遠端推送在 `seq.zig`，兩邊都會用到這裡的
//! `LocalDateTime` 與格式化函式。

const std = @import("std");

/// 匯入編譯目標資訊；`builtin.os.tag` 用來分辨 Windows 與 POSIX 的取時間 API。
const builtin = @import("builtin");

/// 匯入 C 標準函式庫的 `time.h`（由 build.zig 的 addTranslateC 提供）。
const c = @import("c");

/// 程式內部使用的本地時間格式。
///
/// 為什麼不用直接到處傳 C 的 `tm` 或 Windows `SYSTEMTIME`：
/// - 兩個平台的時間 struct 不一樣。
/// - 轉成本專案自己的 struct 後，後面格式化檔名與 log line 就可以共用同一套程式碼。
pub const LocalDateTime = struct {
    /// Unix epoch 秒數，主要拿來判斷舊檔是否超過保留天數。
    unix_seconds: i64,
    /// 年份使用 unsigned，避免 Zig 0.16 格式化 `{d:0>4}` 時把正數印成 `+2026`。
    year: u32,
    /// 月份，範圍是 1 到 12。
    month: u8,
    /// 日期，範圍是 1 到 31。
    day: u8,
    /// 小時，範圍是 0 到 23。
    hour: u8,
    /// 分鐘，範圍是 0 到 59。
    minute: u8,
    /// 秒，範圍是 0 到 59。
    second: u8,
};

/// 取得目前本地時間。
///
/// Windows 和 POSIX 用不同 API：
/// - Windows：用 `GetLocalTime`，因為它直接給本地時間。
/// - POSIX：用 `time` 加 `localtime_r`。
pub fn localNow() !LocalDateTime {
    // Windows 沒有 POSIX 的 `localtime_r`，所以分開處理。
    if (builtin.os.tag == .windows) {
        // 只宣告本函式需要的 Win32 SYSTEMTIME 欄位。
        // 用 extern struct 是為了讓記憶體布局和 C API 相容。
        const SYSTEMTIME = extern struct {
            wYear: u16,
            wMonth: u16,
            wDayOfWeek: u16,
            wDay: u16,
            wHour: u16,
            wMinute: u16,
            wSecond: u16,
            wMilliseconds: u16,
        };

        // 把 Win32 API 包在區域 struct 裡，避免污染整個檔案的命名空間。
        const kernel32 = struct {
            // `callconv(.winapi)` 是 Zig 0.16 呼叫 Win32 API 時應使用的 calling convention。
            extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
        };

        // 準備一塊 SYSTEMTIME 給 Windows 填入目前本地時間。
        var st: SYSTEMTIME = undefined;
        // 呼叫 Win32 API，取得本地年月日時分秒。
        kernel32.GetLocalTime(&st);
        // 另外取得 Unix 秒數，清除舊檔時要和檔案 mtime 比較。
        const unix_time: c.time_t = c.time(null);

        // 轉成本專案共用的 LocalDateTime。
        return .{
            .unix_seconds = @intCast(unix_time),
            .year = @intCast(st.wYear),
            .month = @intCast(st.wMonth),
            .day = @intCast(st.wDay),
            .hour = @intCast(st.wHour),
            .minute = @intCast(st.wMinute),
            .second = @intCast(st.wSecond),
        };
    } else {
        // POSIX 先取得 Unix 秒數。
        var unix_time: c.time_t = c.time(null);
        // `localtime_r` 會把 timestamp 轉成本地時間，且比 `localtime` 更適合多執行緒。
        var local_tm: c.struct_tm = undefined;
        // 如果 localtime_r 失敗，就回傳錯誤。
        _ = c.localtime_r(&unix_time, &local_tm) orelse return error.LocalTimeUnavailable;
        // C 的 tm_year 是從 1900 開始算，tm_mon 是 0 到 11，所以要修正成人類常見格式。
        return .{
            .unix_seconds = @intCast(unix_time),
            .year = @intCast(local_tm.tm_year + 1900),
            .month = @intCast(local_tm.tm_mon + 1),
            .day = @intCast(local_tm.tm_mday),
            .hour = @intCast(local_tm.tm_hour),
            .minute = @intCast(local_tm.tm_min),
            .second = @intCast(local_tm.tm_sec),
        };
    }
}

/// 組出寫入檔案的一整行 log。
pub fn formatLogLine(
    buffer: []u8,
    now: LocalDateTime,
    level: std.log.Level,
    scope_name: ?[]const u8,
    message: []const u8,
) ![]const u8 {
    // `0>4` 代表年份至少 4 位，不足補 0；例如 26 會印成 0026。
    const timestamp_fmt = "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}";
    // 有 scope 就把 scope 放在 level 後面，例如 `info(http)`。
    return if (scope_name) |scope_text|
        std.fmt.bufPrint(buffer, timestamp_fmt ++ " {s}({s}) {s}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, levelText(level), scope_text, message })
        // 沒 scope 就省略括號，讓一般服務 log 比較乾淨。
    else
        std.fmt.bufPrint(buffer, timestamp_fmt ++ " {s} {s}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, levelText(level), message });
}

/// 把 Zig 的 log level 轉成本專案想要顯示的文字。
pub fn levelText(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
}

/// 把已格式化好的日誌輸出到 console。
pub fn writeRenderedToConsole(
    level: std.log.Level,
    scope_name: ?[]const u8,
    message: []const u8,
) void {
    // console 輸出也使用本地時間，方便直接閱讀。
    const now = localNow() catch return;
    // 這裡把 timestamp 格式集中成一個 comptime 字串，避免兩個分支重複寫一大段。
    const timestamp_fmt = "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}";

    // 有 scope 時輸出成 `info(http)`，比較容易看出是哪個模組寫的。
    if (scope_name) |scope_text| {
        std.debug.print(timestamp_fmt ++ " {s}({s}) {s}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, levelText(level), scope_text, message });
    } else {
        // 沒 scope 時就輸出成單純的 `info message`。
        std.debug.print(timestamp_fmt ++ " {s} {s}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, levelText(level), message });
    }
}

/// 格式化錯誤訊息並直接輸出到 console。
///
/// 這通常用在 logger 初始化失敗時，因為那時候檔案 logger 可能還不能用。
pub fn errorConsoleFmt(comptime format: []const u8, args: anytype) void {
    // 用小 buffer 組出錯誤文字。
    var buffer: [1024]u8 = undefined;
    // 如果格式化失敗，就用短字串替代。
    const text = std.fmt.bufPrint(&buffer, format, args) catch "<err>";
    // console 也要帶 timestamp，方便和檔案日誌對齊。
    const now = localNow() catch return;
    // 直接用 std.debug.print，避免再進入 logFn 造成遞迴。
    std.debug.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} error: {s}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, text });
}
