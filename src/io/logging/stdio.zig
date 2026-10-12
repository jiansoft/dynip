//! 把行程自己的 stdout / stderr（fd 1 / 2）依日期導向 `log/YYYY-MM-DD_dynip_stdout.log`。
//!
//! 為什麼需要：`control.sh` 用 `nohup ... >>檔案 2>&1` 在背景啟動服務，shell 的重導向
//! 在啟動當下就把 fd 綁到某一個檔案（inode），之後怎麼改名、刪檔都換不掉。
//! 服務久不重啟，那個檔就會一直長大。只有程式自己 `dup2` 才能在跨日時換檔。
//!
//! 這個檔收的是 console 輸出（受 `LOG_CONSOLE_LEVEL` 過濾）以及 panic、logger 初始化前
//! 的錯誤這類「來不及進 `log/*.log`」的輸出。檔名沿用 `log/*.log` 的日期規則，
//! 所以 `rotate.cleanupOldFiles` 會依 `max_age_days` 一併清掉過期的檔案。
//!
//! 只在 POSIX 平台生效；Windows 沒有這個部署情境，`ensure` 直接什麼都不做。
//! 這是 opt-in 功能（`logging.stdio_to_file` / `LOG_STDIO_TO_FILE`），
//! Docker 模式維持寫 stdout，`docker logs` 才看得到。

const std = @import("std");
const builtin = @import("builtin");

/// 時間型別與 console 錯誤輸出。
const format = @import("format.zig");
/// 日誌目錄、服務名稱與日期檔名規則。
const rotate = @import("rotate.zig");

/// 目前平台是否支援 stdio 重導向。
pub const supported = builtin.os.tag != .windows;

/// 檔名中的「等級」欄位，最終檔名像 `2026-10-12_dynip_stdout.log`。
pub const file_kind = "stdout";

/// 記住目前 fd 1 / 2 指向哪一天的檔案，跨日時才重新導向。
pub const StdioRedirect = struct {
    /// 是否啟用；由 `logging.configure` 依設定填入。
    enabled: bool = false,
    /// 目前導向的檔案所屬年份；0 代表還沒導向過。
    current_year: u32 = 0,
    /// 目前導向的檔案所屬月份。
    current_month: u8 = 0,
    /// 目前導向的檔案所屬日期。
    current_day: u8 = 0,
    /// 是否已回報過導向失敗，避免每寫一行 log 就洗版。
    failure_reported: bool = false,

    /// 確認 fd 1 / 2 指向 `now` 這一天的檔案。
    ///
    /// 呼叫端（logger）每寫一筆 log 都會呼叫；同一天只比較三個欄位，不產生 syscall。
    /// 失敗時不回傳錯誤：stdio 導向失敗不該中斷 DDNS 服務，輸出會留在原本的 fd。
    pub fn ensure(self: *StdioRedirect, io: std.Io, now: format.LocalDateTime) void {
        if (!supported or !self.enabled) return;
        if (self.current_year == now.year and
            self.current_month == now.month and
            self.current_day == now.day) return;

        // 先記下日期再導向：失敗時同一天就不再重試，隔天換檔時會再試一次。
        self.current_year = now.year;
        self.current_month = now.month;
        self.current_day = now.day;

        redirectTo(io, now) catch |err| {
            if (!self.failure_reported) {
                self.failure_reported = true;
                format.errorConsoleFmt("stdio redirect failed: {s}", .{@errorName(err)});
            }
        };
    }
};

/// 開啟當天的檔案，並把 fd 1 / 2 換成它。
///
/// - `APPEND`：同一天重啟服務時接在檔尾，不會蓋掉既有內容；多個 fd 同時寫也不會互蓋。
/// - `CLOEXEC`：只作用在這次 `open` 拿到的暫時 fd；`dup2` 出來的 fd 1 / 2 不帶這個旗標。
/// - `dup2` 是原子替換，其他執行緒同時寫 stderr 時只會寫到舊檔或新檔其中之一。
fn redirectTo(io: std.Io, now: format.LocalDateTime) !void {
    try rotate.ensureLogDir(io);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try buildPath(&path_buffer, now);

    const fd = std.c.open(path.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, @as(c_uint, 0o644));
    if (fd < 0) return error.StdioLogOpenFailed;
    // fd 1 / 2 已經各自持有一份 dup，暫時 fd 用完就關。
    defer _ = std.c.close(fd);

    if (std.c.dup2(fd, std.posix.STDOUT_FILENO) < 0) return error.StdioRedirectFailed;
    if (std.c.dup2(fd, std.posix.STDERR_FILENO) < 0) return error.StdioRedirectFailed;
}

/// 組出 `log/YYYY-MM-DD_dynip_stdout.log`，結尾補 0 好直接交給 C `open`。
pub fn buildPath(buffer: []u8, now: format.LocalDateTime) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buffer, "{s}/{d:0>4}-{d:0>2}-{d:0>2}_{s}_{s}.log", .{
        rotate.default_log_dir,
        now.year,
        now.month,
        now.day,
        rotate.default_log_name,
        file_kind,
    }, 0);
}

test "stdio log path follows the dated log naming used by cleanup" {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const now = format.LocalDateTime{
        .unix_seconds = 0,
        .year = 2026,
        .month = 10,
        .day = 2,
        .hour = 3,
        .minute = 4,
        .second = 5,
    };
    const path = try buildPath(&buffer, now);
    try std.testing.expectEqualStrings("log/2026-10-02_dynip_stdout.log", path);

    // 檔名必須能被過期清理解析出日期，否則舊檔永遠不會被刪。
    const date = rotate.parseLogDateFromFilename(path["log/".len..]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2026), date.year);
    try std.testing.expectEqual(@as(u8, 10), date.month);
    try std.testing.expectEqual(@as(u8, 2), date.day);
}

test "disabled redirect never touches stdio" {
    var redirect: StdioRedirect = .{};
    const now = format.LocalDateTime{
        .unix_seconds = 0,
        .year = 2026,
        .month = 10,
        .day = 2,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    // 測試執行檔自己的 stdout / stderr 不能被換掉，所以只驗證停用時連日期都不記。
    redirect.ensure(std.testing.io, now);
    try std.testing.expectEqual(@as(u32, 0), redirect.current_year);
}
