//! 檔案日誌模組。
//!
//! 這個模組負責把 `std.log.info(...)`、`std.log.err(...)` 這類 Zig 標準日誌，
//! 接到本專案自己的檔案與 console 輸出格式。
//!
//! 給初學者看的重點：
//! - `//!` 是「檔案或模組等級」的 Zigdoc，通常用來說明整份檔案的用途。
//! - `///` 是「下一個宣告」的 Zigdoc，通常用來說明函式、常數、struct 或欄位。
//! - 一般 `//` 是實作註解，適合說明某一行為什麼要這樣寫。
//!
//! 設計上這裡做幾件事：
//! - 依日誌等級分成 `info`、`warn`、`error`、`debug` 四個檔案。
//! - 依日期產生檔名，例如 `log/2026-04-26_dynip_info.log`。
//! - 跨日自動換到新的檔案。
//! - 清掉超過保留天數的舊日誌。
//! - 同一筆 log 同時寫入檔案與 console，方便開發時直接看終端機。
//! - 使用 Zig 0.16 的 `std.Io` API，不再使用舊版 std.fs API。

/// 匯入 Zig 標準函式庫。
///
/// `std` 裡面放了格式化、檔案 IO、同步鎖、log level、測試工具等功能。
const std = @import("std");

/// 匯入編譯目標資訊。
///
/// 這裡用 `builtin.os.tag` 判斷目前是不是 Windows，因為 Windows 和 POSIX 取得本地時間的 API 不一樣。
const builtin = @import("builtin");

/// 匯入 C 標準函式庫的 `time.h`。
///
/// 用意：
/// - `c.time(null)` 可以取得 Unix timestamp 秒數。
/// - POSIX 平台會再用 `localtime_r` 把 timestamp 轉成本地年月日時分秒。
/// - Windows 分支雖然用 Win32 的 `GetLocalTime` 取得本地時間，但仍用 `c.time` 取得清舊檔需要的 Unix 秒數。
const c = @cImport({
    // `@cInclude` 會讓 Zig 幫我們引入 C header 裡宣告的型別與函式。
    @cInclude("time.h");
});

/// 日誌資料夾名稱。
///
/// 所有檔案日誌都會放在專案執行目錄下的 `log/`。
pub const default_log_dir = "log";

/// 日誌檔名中的服務名稱。
///
/// 最終檔名會像 `2026-04-26_dynip_info.log`。
pub const default_log_name = "dynip";

/// 舊日誌保留天數。
///
/// 超過 7 天的檔案會在換日或第一次開檔時嘗試刪除。
const default_max_age_days: i64 = 7;

/// 確保 `log/` 目錄存在。
///
/// 這個函式只負責建立資料夾，不負責開 log 檔。
fn ensureLogDir(io: std.Io) !void {
    // `std.Io.Dir.cwd()` 代表目前工作目錄。
    // `createDir` 如果資料夾已存在會回 `error.PathAlreadyExists`，這種情況對我們來說是成功。
    std.Io.Dir.cwd().createDir(io, default_log_dir, .default_dir) catch |err| switch (err) {
        // 資料夾已經存在就不用做任何事。
        error.PathAlreadyExists => {},
        // 其他錯誤，例如權限不足，應該往外回傳，讓呼叫端知道初始化失敗。
        else => return err,
    };
}

/// 程式內部使用的本地時間格式。
///
/// 為什麼不用直接到處傳 C 的 `tm` 或 Windows `SYSTEMTIME`：
/// - 兩個平台的時間 struct 不一樣。
/// - 轉成本專案自己的 struct 後，後面格式化檔名與 log line 就可以共用同一套程式碼。
const LocalDateTime = struct {
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

/// 管理單一日誌等級的檔案輪替狀態。
///
/// 例如 `info`、`warn`、`error`、`debug` 各自都會有一份 `Rotate`。
/// 這樣寫的好處是每個等級可以獨立開檔、換日與關檔。
const Rotate = struct {
    /// 這個輪替器管理的等級名稱，例如 `"info"`。
    level_name: []const u8,
    /// 目前已開啟檔案所屬的年份，用來判斷是否跨日。
    current_year: u32 = 0,
    /// 目前已開啟檔案所屬的月份，用來判斷是否跨日。
    current_month: u8 = 0,
    /// 目前已開啟檔案所屬的日期，用來判斷是否跨日。
    current_day: u8 = 0,
    /// 目前開啟中的檔案。
    ///
    /// `?std.Io.File` 是 optional，`null` 代表還沒有開檔。
    file: ?std.Io.File = null,
    /// 組檔名用的固定 buffer。
    ///
    /// 這樣每次組路徑時不用額外配置 heap 記憶體。
    path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,

    /// 建立一個指定等級的輪替器。
    fn init(level_name: []const u8) Rotate {
        // 只指定 level_name，其餘欄位使用 struct 裡的預設值。
        return .{ .level_name = level_name };
    }

    /// 關閉目前開啟中的檔案。
    fn deinit(self: *Rotate, io: std.Io) void {
        // `if (optional) |value|` 是 Zig 解開 optional 的常見寫法。
        if (self.file) |file| {
            // 有開檔才需要關檔。
            file.close(io);
            // 關完後設回 null，避免之後誤以為還有檔案可寫。
            self.file = null;
        }
    }

    /// 寫入一行已格式化的日誌。
    fn writeLine(
        self: *Rotate,
        io: std.Io,
        now: LocalDateTime,
        level: std.log.Level,
        scope_name: ?[]const u8,
        message: []const u8,
    ) !void {
        // 寫入前先確認檔案存在，而且日期正確。
        // 如果今天還沒開檔，或已經跨日，這裡會自動開新檔。
        try self.ensureReady(io, now);

        // 每一行 log 最多先放在 stack buffer 裡。
        // 這比每次 heap allocate 更簡單，也比較適合短字串日誌。
        var line_buffer: [8192]u8 = undefined;
        // 把時間、等級、scope 和訊息組成真正要寫入檔案的一行文字。
        const line = try formatLogLine(&line_buffer, now, level, scope_name, message);

        // 再次確認檔案存在。理論上 ensureReady 成功後一定有檔案，但 optional 還是要安全處理。
        if (self.file) |file| {
            // 取得目前檔案長度，這就是「檔尾」的位置。
            //
            // 為什麼每次寫入前都重新取長度：
            // - 服務重啟後，檔案本來就已經有舊內容。
            // - 每次寫入前把「邏輯寫入位置」設到最新檔尾，就能保證 log 是 append，不會寫到檔案最上面。
            const size = try file.length(io);
            // 使用 positional writer，而不是 streaming writer。
            // positional writer 會把 offset 明確交給底層寫入 API，不依賴作業系統目前的檔案游標。
            var write_buffer: [1024]u8 = undefined;
            var writer = file.writer(io, &write_buffer);
            // 把這次 writer 的邏輯寫入位置移到檔尾。
            try writer.seekTo(size);
            // 透過同一個 writer 寫入，這樣 seek 位置和真正寫入位置會一致。
            try writer.interface.writeAll(line);
            // flush 確保 buffer 裡的資料真的送到底層檔案。
            try writer.flush();
        }
    }

    /// 確認目前日期對應的 log 檔已準備好。
    fn ensureReady(self: *Rotate, io: std.Io, now: LocalDateTime) !void {
        // 第一次寫入時 `self.file == null`。
        // 年月日任一欄不同，代表跨日，需要切到新的檔名。
        const day_changed = self.file == null or
            self.current_year != now.year or
            self.current_month != now.month or
            self.current_day != now.day;

        // 只有第一次或跨日時才重新開檔，避免每行 log 都重開檔造成 I/O 成本。
        if (day_changed) {
            // 先更新目前日期狀態，讓後續判斷知道目前檔案是哪一天。
            self.current_year = now.year;
            self.current_month = now.month;
            self.current_day = now.day;
            // 開啟新日期的檔案。
            try self.openCurrentFile(io, now);
            // 順便清掉過舊檔案；放在這裡可以避免每一行 log 都掃目錄。
            self.cleanupOldFiles(io, now);
        }
    }

    /// 開啟目前日期與等級對應的 log 檔。
    fn openCurrentFile(self: *Rotate, io: std.Io, now: LocalDateTime) !void {
        // 如果之前有舊檔案，先關掉，避免 handle 外洩。
        self.deinit(io);
        // 開檔前先確保 `log/` 目錄存在。
        try ensureLogDir(io);

        // 組出完整路徑，例如 `log/2026-04-26_dynip_info.log`。
        const path = try self.buildCurrentPath(now);

        // `createFile` 搭配 `.read = true` 與 `.truncate = false`：
        // - read=true 讓 Windows handle 可以讀 metadata / 長度；沒有它，後續 file.length 可能失敗。
        // - 檔案不存在就建立。
        // - 檔案存在就保留原本內容。
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
        });

        // 開檔成功後才放回狀態裡。
        // 真正寫入時會再次 seek 到檔尾，確保重啟服務後一定是 append。
        self.file = file;
    }

    /// 依目前日期與等級組出 log 檔案路徑。
    fn buildCurrentPath(self: *Rotate, now: LocalDateTime) ![]const u8 {
        // `bufPrint` 會把格式化結果寫進固定 buffer，回傳實際使用的 slice。
        return std.fmt.bufPrint(
            &self.path_buffer,
            "{s}/{d:0>4}-{d:0>2}-{d:0>2}_{s}_{s}.log",
            .{ default_log_dir, now.year, now.month, now.day, default_log_name, self.level_name },
        );
    }

    /// 清除超過保留天數的舊 log 檔。
    fn cleanupOldFiles(self: *Rotate, io: std.Io, now: LocalDateTime) void {
        // 這個函式目前不需要使用 self，但保留成 method 讓呼叫端語意清楚。
        _ = self;
        // 打開 `log/` 目錄並啟用 iterate，才能逐檔掃描。
        var dir = std.Io.Dir.cwd().openDir(io, default_log_dir, .{ .iterate = true }) catch return;
        // 函式結束時關閉目錄 handle。
        defer dir.close(io);

        // 建立目錄迭代器。
        var iter = dir.iterate();
        // 計算舊檔分界線：現在時間減掉保留天數。
        const cutoff = now.unix_seconds - (default_max_age_days * 24 * 60 * 60);

        // 一個檔案一個檔案看。
        while (iter.next(io) catch return) |entry| {
            // 只處理一般檔案，資料夾或其他項目直接略過。
            if (entry.kind != .file) continue;
            // 讀取檔案 metadata，拿到 mtime。
            const stat = dir.statFile(io, entry.name, .{}) catch continue;
            // 還沒超過保留期限就不用刪。
            if (stat.mtime.toSeconds() > cutoff) continue;

            // 刪檔失敗不讓 logger 崩潰；日誌清理是輔助功能，不應影響主程式。
            dir.deleteFile(io, entry.name) catch {};
        }
    }
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
    info_rotate: Rotate = Rotate.init("info"),
    /// warn 等級的檔案輪替器。
    warn_rotate: Rotate = Rotate.init("warn"),
    /// error 等級的檔案輪替器。
    error_rotate: Rotate = Rotate.init("error"),
    /// debug 等級的檔案輪替器。
    debug_rotate: Rotate = Rotate.init("debug"),

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
    }

    /// 根據 log level 選出對應的輪替器。
    fn rotateForLevel(self: *Logger, level: std.log.Level) *Rotate {
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
        const now = localNow() catch return;

        // 寫檔前上鎖，避免多個 log 同時寫入造成內容交錯。
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // 找到這個 level 對應的檔案輪替器。
        const rotate = self.rotateForLevel(level);
        // 寫入失敗時不讓主程式崩潰，因為 logger 失敗通常不該中斷 DDNS 服務。
        rotate.writeLine(self.io, now, level, scope_name, message) catch {};
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
    try ensureLogDir(io);
    // 建立 logger，並保存目前這份 io。
    global_logger = .{ .io = io };
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

    // 不管檔案 logger 是否已初始化，都同步輸出到 console。
    // 這樣初始化失敗或早期錯誤仍然看得到。
    writeRenderedToConsole(level, scope_name, rendered);
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

/// 把已格式化好的日誌輸出到 console。
fn writeRenderedToConsole(
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

/// 組出寫入檔案的一整行 log。
fn formatLogLine(
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
/// Windows 和 POSIX 用不同 API：
/// - Windows：用 `GetLocalTime`，因為它直接給本地時間。
/// - POSIX：用 `time` 加 `localtime_r`。
fn localNow() !LocalDateTime {
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

test "log timestamp and filename do not prefix positive year with plus" {
    // 這個測試是為了防止 Zig 0.16 的有號整數格式化再次把年份印成 `+2026`。
    var rotate = Rotate.init("info");
    const now = LocalDateTime{
        .unix_seconds = 0,
        .year = 2026,
        .month = 4,
        .day = 26,
        .hour = 23,
        .minute = 5,
        .second = 2,
    };

    // 檔名應該是 `2026-...`，不能是 `+2026-...`。
    try std.testing.expectEqualStrings(
        "log/2026-04-26_dynip_info.log",
        try rotate.buildCurrentPath(now),
    );

    // log line 的 timestamp 也一樣不能出現加號。
    var buffer: [256]u8 = undefined;
    const line = try formatLogLine(&buffer, now, .info, null, "hello");
    try std.testing.expectEqualStrings(
        "2026-04-26 23:05:02 info hello\n",
        line,
    );
}

test "reopened log file appends to bottom instead of overwriting beginning" {
    // 這個測試模擬服務重啟：
    // 第一個 Rotate 寫一行，關檔；第二個 Rotate 開同一個檔案再寫一行。
    // 如果 append 行為錯了，第二行會覆蓋第一行開頭。
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const now = LocalDateTime{
        .unix_seconds = 0,
        .year = 2099,
        .month = 1,
        .day = 2,
        .hour = 3,
        .minute = 4,
        .second = 5,
    };
    const path = "log/2099-01-02_dynip_info.log";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var first = Rotate.init("info");
    try first.writeLine(io, now, .info, null, "first-long-line");
    first.deinit(io);

    var second = Rotate.init("info");
    try second.writeLine(io, now, .info, null, "second");
    second.deinit(io);

    const text = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        "2099-01-02 03:04:05 info first-long-line\n" ++
            "2099-01-02 03:04:05 info second\n",
        text,
    );
}
