//! 檔案日誌的輪轉與清理。
//!
//! 一個 [`Rotate`] 管一個等級（info / warn / error / debug）的檔案，負責：
//! - 依日期開檔，跨日自動換檔。
//! - 單檔超過大小上限時輪轉（rename-on-rollover，見 [`Rotate`] 的說明）。
//! - 清掉超過保留天數的舊日誌。
//!
//! 這裡只管檔案，log 行的格式在 `format.zig`，logger 的組裝在 `../logging.zig`。

const std = @import("std");

/// 匯入編譯目標資訊；`getFileLength` 需要分辨 Linux 與其他平台。
const builtin = @import("builtin");

/// 時間型別與行格式化。
const format = @import("format.zig");

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
pub const default_max_age_days: i64 = 7;

/// 單檔大小上限預設值（10 MB）。
///
/// 超過這個大小時，正在寫入的檔案會被改名成帶時間戳的封存檔。
pub const default_max_size_bytes: u64 = 10 * 1024 * 1024;

/// 單檔大小上限的可設定範圍（bytes）：1 MB ～ 1 GB。
///
/// 設太小會讓封存檔暴增，設太大則失去輪轉意義，因此把設定值收斂到這個區間。
pub const min_configurable_size_bytes: u64 = 1024 * 1024;

pub const max_configurable_size_bytes: u64 = 1024 * 1024 * 1024;

/// 同一秒內封存檔名的最大序號。
///
/// 同一秒連續輪轉時會用 `-1`、`-2` 這種序號避免覆蓋既有封存檔；
/// 這個上限只是保險，避免極端情況下無止盡探測檔名。
const max_filename_seq: u32 = 1000;

/// 確保 `log/` 目錄存在。
///
/// 這個函式只負責建立資料夾，不負責開 log 檔。
pub fn ensureLogDir(io: std.Io) !void {
    // `std.Io.Dir.cwd()` 代表目前工作目錄。
    // `createDir` 如果資料夾已存在會回 `error.PathAlreadyExists`，這種情況對我們來說是成功。
    std.Io.Dir.cwd().createDir(io, default_log_dir, .default_dir) catch |err| switch (err) {
        // 資料夾已經存在就不用做任何事。
        error.PathAlreadyExists => {},
        // 其他錯誤，例如權限不足，應該往外回傳，讓呼叫端知道初始化失敗。
        else => return err,
    };
}

/// 取得當前檔案大小。
///
/// 在 Linux 系統下，Zig 標準庫的 `file.length(io)` 底層使用 `statx`
/// （見 `std/Io/Threaded.zig` 的 `fileLength`）。在某些容器環境（如 distroless 且以
/// 非 root 執行）或舊版 Kernel 下，`statx` 可能被沙箱（seccomp）阻擋而回傳錯誤，
/// 導致寫入中斷。因此 Linux 改用更穩定的「seek 到檔尾」取得大小。
fn getFileLength(io: std.Io, file: std.Io.File) std.Io.File.LengthError!u64 {
    if (comptime builtin.os.tag != .linux) return file.length(io);

    return seekToEnd(file);
}

/// 以 seek 到檔尾的方式取得檔案大小（Linux 專用）。
///
/// 分成兩條路是因為 32 位元 target（例如 Raspberry Pi 的 armv7l）上標準庫的 `lseek`
/// 不可用：該平台的 `lseek` offset 只有 32 位元，Kernel 另外提供 `_llseek`，
/// 把 64 位元 offset 拆成高低兩半傳入，結果寫回 `offset` 指標。
///
/// 兩條路的回傳方式也不同：`lseek` 直接把新的檔案位置當回傳值，
/// `llseek` 的回傳值只是 errno，真正的位置在 `offset` 裡。
fn seekToEnd(file: std.Io.File) std.posix.UnexpectedError!u64 {
    const linux = std.os.linux;

    if (comptime @sizeOf(usize) == 8) {
        const rc = linux.lseek(file.handle, 0, linux.SEEK.END);
        try checkErrno(linux.errno(rc));
        return rc;
    }

    var offset: linux.off_t = 0;
    const rc = linux.llseek(file.handle, 0, &offset, linux.SEEK.END);
    try checkErrno(linux.errno(rc));
    // seek 成功時檔案位置必為非負，轉成 u64 是安全的。
    return @intCast(offset);
}

/// 把 syscall 的 errno 轉成 Zig error。
///
/// 用 `unexpectedErrno` 而不是直接 `return error.Unexpected`：兩者對呼叫端是同一個
/// 錯誤，但前者在 debug 建置會把實際的 errno 印出來，否則這裡失敗時只會看到
/// 一個沒有線索的 `error.Unexpected`。
fn checkErrno(err: std.os.linux.E) std.posix.UnexpectedError!void {
    if (err != .SUCCESS) return std.posix.unexpectedErrno(err);
}

/// 管理單一日誌等級的檔案輪替狀態。
///
/// 例如 `info`、`warn`、`error`、`debug` 各自都會有一份 `Rotate`。
/// 這樣寫的好處是每個等級可以獨立開檔、換日與關檔。
///
/// 檔名策略採 **rename-on-rollover**（和 logrotate 的 `create` 模式相同）：
/// - **正在寫入的檔案永遠不帶時間戳**，例如 `log/2026-04-26_dynip_info.log`。
///   因此 tail、監控或 log 收集器都可以固定盯同一個路徑。
/// - 檔案超過大小上限時，先把它**改名**成
///   `log/2026-04-26_dynip_info.09-06-56.log`，時間戳是這個檔**最後一筆**日誌的時間，
///   代表「這個檔的內容截止到幾點幾分」；接著再開一個同名空檔繼續寫。
/// - 同一秒內連續輪轉會加序號（`.09-06-56-1.log`），不會覆蓋既有封存檔。
/// - 跨日時舊日期的活躍檔（檔名已含日期）原樣保留，直接改開新日期的活躍檔。
pub const Rotate = struct {
    /// 這個輪替器管理的等級名稱，例如 `"info"`。
    level_name: []const u8,
    /// 舊日誌保留天數。
    max_age_days: i64 = default_max_age_days,
    /// 單檔大小上限（bytes）；`0` 代表停用大小輪轉，只保留跨日換檔。
    max_size_bytes: u64 = default_max_size_bytes,
    /// 目前這個檔案最後一筆日誌的時間。
    ///
    /// 輪轉時用它當封存檔名的時間戳；`null` 代表這個檔案還沒被本行程寫過
    /// （例如剛開檔、或剛輪轉完），此時退回使用當下時間。
    last_write: ?format.LocalDateTime = null,
    /// 是否已回報過輪轉失敗。
    ///
    /// 改名失敗（例如檔案被防毒或其他程序鎖住）時只在 console 提示一次，
    /// 避免每寫一行 log 就洗版。
    rotate_failure_reported: bool = false,
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
    pub fn init(level_name: []const u8) Rotate {
        // 只指定 level_name，其餘欄位使用 struct 裡的預設值。
        return .{ .level_name = level_name };
    }

    /// 關閉目前開啟中的檔案。
    pub fn deinit(self: *Rotate, io: std.Io) void {
        // `if (optional) |value|` 是 Zig 解開 optional 的常見寫法。
        if (self.file) |file| {
            // 有開檔才需要關檔。
            file.close(io);
            // 關完後設回 null，避免之後誤以為還有檔案可寫。
            self.file = null;
        }
    }

    /// 寫入一行已格式化的日誌。
    pub fn writeLine(
        self: *Rotate,
        io: std.Io,
        now: format.LocalDateTime,
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
        const line = try format.formatLogLine(&line_buffer, now, level, scope_name, message);

        // 再次確認檔案存在。理論上 ensureReady 成功後一定有檔案，但 optional 還是要安全處理。
        if (self.file) |file| {
            // 取得目前檔案長度，這就是「檔尾」的位置。
            //
            // 為什麼每次寫入前都重新取長度：
            // - 服務重啟後，檔案本來就已經有舊內容。
            // - 每次寫入前把「邏輯寫入位置」設到最新檔尾，就能保證 log 是 append，不會寫到檔案最上面。
            const size = try getFileLength(io, file);

            // 寫下去會超過上限就先輪轉：把目前這個檔改名封存，再開一個同名空檔。
            if (self.shouldRotateBySize(size, line.len)) {
                try self.rotateBySize(io, now);
            }
        }

        // 輪轉可能換過 handle，這裡重新取出目前的活躍檔；
        // 長度也一律重新取，不能假設輪轉後就是 0（改名失敗時會續寫原檔，
        // 從檔頭寫會蓋掉既有內容）。
        if (self.file) |file| {
            const size = try getFileLength(io, file);
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
            // 記住這一筆的時間，下次輪轉時會拿它當封存檔名的時間戳。
            self.last_write = now;
        }
    }

    /// 判斷把這一行寫下去是否會超過單檔大小上限。
    ///
    /// 兩個保護條件：
    /// - `max_size_bytes == 0` 代表停用大小輪轉。
    /// - `current_size == 0`（空檔）時不輪轉，否則單行大於上限時會變成每寫一行就輪轉一次。
    fn shouldRotateBySize(self: *Rotate, current_size: u64, line_len: usize) bool {
        if (self.max_size_bytes == 0) return false;
        if (current_size == 0) return false;
        return current_size + line_len > self.max_size_bytes;
    }

    /// 執行大小輪轉：把活躍檔改名成封存檔，再開一個同名空檔。
    ///
    /// 改名前一定要先關閉 handle，否則 Windows 會拒絕改名。
    /// 改名失敗時不讓日誌中斷：console 提示一次後續寫原檔，下一筆訊息會再試一次。
    fn rotateBySize(self: *Rotate, io: std.Io, now: format.LocalDateTime) !void {
        // 封存檔名用「最後一筆日誌的時間」；本行程還沒寫過就退回當下時間。
        const stamp = self.last_write orelse now;

        // 先關檔，Windows 上開啟中的檔案無法改名。
        self.deinit(io);

        // 活躍檔路徑（會寫進 self.path_buffer）。
        const active_path = try self.buildCurrentPath(now);
        // 封存檔路徑另外用區域 buffer，避免覆蓋掉還要用的 active_path。
        var archive_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const archive_path = try self.resolveArchivePath(io, &archive_buffer, stamp);

        std.Io.Dir.cwd().rename(active_path, std.Io.Dir.cwd(), archive_path, io) catch |err| {
            if (!self.rotate_failure_reported) {
                self.rotate_failure_reported = true;
                format.errorConsoleFmt(
                    "log rotate failed: {s} -> {s}: {s}",
                    .{ active_path, archive_path, @errorName(err) },
                );
            }
        };

        // 不論改名成功與否都要把檔案重新開回來，日誌才能繼續寫。
        self.last_write = null;
        try self.openCurrentFile(io, now);
    }

    /// 找出一個尚未被使用的封存檔名。
    ///
    /// 同一秒內連續輪轉（或重啟後同秒再輪轉）時遞增序號，確保不會覆蓋既有封存檔。
    fn resolveArchivePath(
        self: *Rotate,
        io: std.Io,
        buffer: []u8,
        stamp: format.LocalDateTime,
    ) ![]const u8 {
        var seq: u32 = 0;
        while (true) : (seq += 1) {
            const candidate = try buildArchivePath(buffer, self.level_name, stamp, seq);
            // 序號用盡時就直接用最後一個候選，避免無止盡探測。
            if (seq >= max_filename_seq) return candidate;
            // statFile 失敗（多半是 FileNotFound）就代表這個檔名還沒人用。
            _ = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch return candidate;
        }
    }

    /// 確認目前日期對應的 log 檔已準備好。
    fn ensureReady(self: *Rotate, io: std.Io, now: format.LocalDateTime) !void {
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
    fn openCurrentFile(self: *Rotate, io: std.Io, now: format.LocalDateTime) !void {
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
    fn buildCurrentPath(self: *Rotate, now: format.LocalDateTime) ![]const u8 {
        // `bufPrint` 會把格式化結果寫進固定 buffer，回傳實際使用的 slice。
        return std.fmt.bufPrint(
            &self.path_buffer,
            "{s}/{d:0>4}-{d:0>2}-{d:0>2}_{s}_{s}.log",
            .{ default_log_dir, now.year, now.month, now.day, default_log_name, self.level_name },
        );
    }

    /// 組出封存檔（已輪轉的舊檔）路徑。
    ///
    /// 時間戳是這個檔最後一筆日誌的時間，`:` 在 Windows 檔名不合法，所以用 `-` 分隔：
    /// - `seq == 0`：`log/2026-04-26_dynip_info.09-06-56.log`
    /// - `seq > 0` ：`log/2026-04-26_dynip_info.09-06-56-1.log`（同一秒再次輪轉）
    ///
    /// 日期部分刻意維持在檔名開頭，`cleanupOldFiles` 才能照舊由檔名判斷保留天數。
    fn buildArchivePath(
        buffer: []u8,
        level_name: []const u8,
        stamp: format.LocalDateTime,
        seq: u32,
    ) ![]const u8 {
        const prefix_fmt = "{s}/{d:0>4}-{d:0>2}-{d:0>2}_{s}_{s}.{d:0>2}-{d:0>2}-{d:0>2}";
        return if (seq == 0)
            std.fmt.bufPrint(buffer, prefix_fmt ++ ".log", .{
                default_log_dir,  stamp.year, stamp.month, stamp.day,
                default_log_name, level_name, stamp.hour,  stamp.minute,
                stamp.second,
            })
        else
            std.fmt.bufPrint(buffer, prefix_fmt ++ "-{d}.log", .{
                default_log_dir,  stamp.year, stamp.month, stamp.day,
                default_log_name, level_name, stamp.hour,  stamp.minute,
                stamp.second,     seq,
            });
    }

    /// 清除超過保留天數的舊 log 檔。
    pub fn cleanupOldFiles(self: *Rotate, io: std.Io, now: format.LocalDateTime) void {
        // 小於等於 0 代表不自動刪除舊日誌。
        if (self.max_age_days <= 0) return;
        // 打開 `log/` 目錄並啟用 iterate，才能逐檔掃描。
        var dir = std.Io.Dir.cwd().openDir(io, default_log_dir, .{ .iterate = true }) catch return;
        // 函式結束時關閉目錄 handle。
        defer dir.close(io);

        // 建立目錄迭代器。
        var iter = dir.iterate();
        const now_days = daysSinceEpoch(now.year, now.month, now.day);

        // 一個檔案一個檔案看。
        while (iter.next(io) catch return) |entry| {
            // 只略過明確為目錄的項目。
            // 注意：在 Linux (如樹莓派/Docker/ext4) 上，entry.kind 經常為 .unknown (DT_UNKNOWN)，
            // 若寫成 `if (entry.kind != .file) continue;` 會把所有舊 log 檔都略過不刪。
            if (entry.kind == .directory) continue;

            // 1. 優先由檔名解析日期（例如 `2026-07-28_dynip_warn.log`）。
            // 檔名日期比檔案 mtime 更穩定，不受 touch、時區或 Linux statx 系統呼叫失敗影響。
            if (parseLogDateFromFilename(entry.name)) |log_date| {
                const file_days = daysSinceEpoch(log_date.year, log_date.month, log_date.day);
                if (now_days - file_days >= self.max_age_days) {
                    dir.deleteFile(io, entry.name) catch {};
                }
                continue;
            }

            // 2. 非日期格式命名的檔案（例如 general_stdout.log）保留不隨意刪除。
        }
    }
};

/// 計算指定年月日距離基準點的天數（採用西曆閏年規則）。
pub fn daysSinceEpoch(year: u32, month: u8, day: u8) i64 {
    const days_before_month = [_]i64{ 0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    const y: i64 = @intCast(year);
    const m: usize = @intCast(month);
    const d: i64 = @intCast(day);

    const leap_years = @divFloor(y - 1, 4) - @divFloor(y - 1, 100) + @divFloor(y - 1, 400);
    var days: i64 = (y * 365) + leap_years;
    if (m >= 1 and m <= 12) {
        days += days_before_month[m];
        const is_leap = (@mod(y, 4) == 0 and @mod(y, 100) != 0) or (@mod(y, 400) == 0);
        if (is_leap and m > 2) {
            days += 1;
        }
    }
    days += d;
    return days;
}

/// 從日誌檔名（例如 `2026-07-28_dynip_warn.log`）解析出年月日。
/// 若檔名開頭符合 `YYYY-MM-DD` 格式則回傳年月日，否則回傳 null。
pub fn parseLogDateFromFilename(name: []const u8) ?struct { year: u32, month: u8, day: u8 } {
    if (name.len < 10) return null;
    if (name[4] != '-' or name[7] != '-') return null;

    const year = std.fmt.parseInt(u32, name[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, name[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, name[8..10], 10) catch return null;

    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    return .{ .year = year, .month = month, .day = day };
}

/// 把設定檔的「MB」換算成實際 bytes 上限。
///
/// - 小於等於 0：回傳 `0`，代表停用大小輪轉（只保留跨日換檔）。
/// - 其他值：收斂到 1 MB ～ 1 GB，避免設成 1 KB 讓封存檔暴增，
///   或設成幾百 GB 等同沒有上限。
pub fn resolveMaxSizeBytes(max_size_mb: i64) u64 {
    if (max_size_mb <= 0) return 0;

    const mb: u64 = @intCast(max_size_mb);
    // 先擋掉乘法溢位（超過 1 GB 的值反正都會被夾到上限）。
    if (mb > max_configurable_size_bytes / (1024 * 1024)) return max_configurable_size_bytes;

    return std.math.clamp(
        mb * 1024 * 1024,
        min_configurable_size_bytes,
        max_configurable_size_bytes,
    );
}

test "log timestamp and filename do not prefix positive year with plus" {
    // 這個測試是為了防止 Zig 0.16 的有號整數格式化再次把年份印成 `+2026`。
    var rotate = Rotate.init("info");
    const now = format.LocalDateTime{
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
    const line = try format.formatLogLine(&buffer, now, .info, null, "hello");
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

    const now = format.LocalDateTime{
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

test "buildArchivePath stamps the file with a timestamp and sequence" {
    const stamp = format.LocalDateTime{
        .unix_seconds = 0,
        .year = 2026,
        .month = 4,
        .day = 26,
        .hour = 9,
        .minute = 6,
        .second = 56,
    };

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "log/2026-04-26_dynip_info.09-06-56.log",
        try Rotate.buildArchivePath(&buffer, "info", stamp, 0),
    );
    try std.testing.expectEqualStrings(
        "log/2026-04-26_dynip_info.09-06-56-2.log",
        try Rotate.buildArchivePath(&buffer, "info", stamp, 2),
    );
}

test "size rollover renames the active file and keeps writing to the plain name" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const first = format.LocalDateTime{
        .unix_seconds = 0,
        .year = 2098,
        .month = 3,
        .day = 4,
        .hour = 5,
        .minute = 6,
        .second = 7,
    };
    // 第二筆日誌晚一小時，用來確認封存檔名取的是「最後一筆」而非輪轉當下的時間。
    const later = format.LocalDateTime{
        .unix_seconds = 0,
        .year = 2098,
        .month = 3,
        .day = 4,
        .hour = 6,
        .minute = 6,
        .second = 7,
    };

    const active_path = "log/2098-03-04_dynip_info.log";
    const archive_path = "log/2098-03-04_dynip_info.05-06-07.log";
    const unexpected_archive = "log/2098-03-04_dynip_info.06-06-07.log";
    std.Io.Dir.cwd().deleteFile(io, active_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, archive_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, active_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, archive_path) catch {};

    var rotate = Rotate.init("info");
    // 上限設得比一行 log 還小，第二行就會觸發輪轉。
    rotate.max_size_bytes = 16;
    rotate.max_age_days = 0;

    try rotate.writeLine(io, first, .info, null, "first");
    try rotate.writeLine(io, later, .info, null, "second");
    rotate.deinit(io);

    // 封存檔應該只有第一行，且檔名帶著第一行（該檔最後一筆）的時間。
    const archived = try std.Io.Dir.cwd().readFileAlloc(
        io,
        archive_path,
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(archived);
    try std.testing.expectEqualStrings("2098-03-04 05:06:07 info first\n", archived);

    // 活躍檔仍是不帶時間戳的檔名，內容是輪轉後寫入的第二行。
    const active = try std.Io.Dir.cwd().readFileAlloc(
        io,
        active_path,
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(active);
    try std.testing.expectEqualStrings("2098-03-04 06:06:07 info second\n", active);

    // 不該用輪轉當下的時間當檔名。
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, unexpected_archive, .{}),
    );
}

test "size rollover keeps every archived file when rotating within the same second" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const now = format.LocalDateTime{
        .unix_seconds = 0,
        .year = 2097,
        .month = 3,
        .day = 4,
        .hour = 5,
        .minute = 6,
        .second = 7,
    };

    const paths = [_][]const u8{
        "log/2097-03-04_dynip_info.log",
        "log/2097-03-04_dynip_info.05-06-07.log",
        "log/2097-03-04_dynip_info.05-06-07-1.log",
    };
    for (paths) |path| std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer for (paths) |path| std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var rotate = Rotate.init("info");
    rotate.max_size_bytes = 16;
    rotate.max_age_days = 0;

    // 三行同一秒寫入 → 兩次輪轉 → 封存檔以序號區分，彼此不覆蓋。
    try rotate.writeLine(io, now, .info, null, "one");
    try rotate.writeLine(io, now, .info, null, "two");
    try rotate.writeLine(io, now, .info, null, "three");
    rotate.deinit(io);

    for (paths) |path| {
        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
            std.debug.print("missing rotated log: {s}\n", .{path});
            return err;
        };
    }
}

test "max_size_bytes = 0 disables size rollover" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const now = format.LocalDateTime{
        .unix_seconds = 0,
        .year = 2096,
        .month = 3,
        .day = 4,
        .hour = 5,
        .minute = 6,
        .second = 7,
    };

    const active_path = "log/2096-03-04_dynip_info.log";
    const archive_path = "log/2096-03-04_dynip_info.05-06-07.log";
    std.Io.Dir.cwd().deleteFile(io, active_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, active_path) catch {};

    var rotate = Rotate.init("info");
    rotate.max_size_bytes = 0;
    rotate.max_age_days = 0;

    try rotate.writeLine(io, now, .info, null, "one");
    try rotate.writeLine(io, now, .info, null, "two");
    rotate.deinit(io);

    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, archive_path, .{}),
    );
}

test "resolveMaxSizeBytes clamps configured values" {
    // 0 或負數代表停用大小輪轉。
    try std.testing.expectEqual(@as(u64, 0), resolveMaxSizeBytes(0));
    try std.testing.expectEqual(@as(u64, 0), resolveMaxSizeBytes(-5));
    // 一般值直接換算。
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), resolveMaxSizeBytes(10));
    // 太小夾到 1 MB，太大夾到 1 GB，超大值也不會溢位。
    try std.testing.expectEqual(min_configurable_size_bytes, resolveMaxSizeBytes(1));
    try std.testing.expectEqual(max_configurable_size_bytes, resolveMaxSizeBytes(4096));
    try std.testing.expectEqual(max_configurable_size_bytes, resolveMaxSizeBytes(std.math.maxInt(i64)));
}

test "cleanupOldFiles deletes old logs and preserves recent and non-matching logs" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try ensureLogDir(io);

    // Create 3 files:
    // 1. Old log (17 days old): 2026-07-28_dynip_warn.log -> should be deleted
    // 2. Recent log (1 day old): 2026-08-13_dynip_info.log -> should be kept
    // 3. Non-date log: general_stdout.log -> should be kept
    const old_log = "log/2026-07-28_dynip_warn.log";
    const recent_log = "log/2026-08-13_dynip_info.log";
    const general_log = "log/general_stdout.log";

    const f1 = try std.Io.Dir.cwd().createFile(io, old_log, .{});
    f1.close(io);
    const f2 = try std.Io.Dir.cwd().createFile(io, recent_log, .{});
    f2.close(io);
    const f3 = try std.Io.Dir.cwd().createFile(io, general_log, .{});
    f3.close(io);

    defer std.Io.Dir.cwd().deleteFile(io, old_log) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, recent_log) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, general_log) catch {};

    var rotate = Rotate.init("info");
    rotate.max_age_days = 7;

    const now = format.LocalDateTime{
        .unix_seconds = 0,
        .year = 2026,
        .month = 8,
        .day = 14,
        .hour = 12,
        .minute = 0,
        .second = 0,
    };
    rotate.cleanupOldFiles(io, now);

    // Old log should be deleted
    const old_stat = std.Io.Dir.cwd().statFile(io, old_log, .{});
    try std.testing.expectError(error.FileNotFound, old_stat);

    // Recent log and general stdout log should still exist
    _ = try std.Io.Dir.cwd().statFile(io, recent_log, .{});
    _ = try std.Io.Dir.cwd().statFile(io, general_log, .{});
}

test "parseLogDateFromFilename extracts valid dates and ignores others" {
    const d1 = parseLogDateFromFilename("2026-07-28_dynip_warn.log");
    try std.testing.expect(d1 != null);
    try std.testing.expectEqual(@as(u32, 2026), d1.?.year);
    try std.testing.expectEqual(@as(u8, 7), d1.?.month);
    try std.testing.expectEqual(@as(u8, 28), d1.?.day);

    const d2 = parseLogDateFromFilename("general_stdout.log");
    try std.testing.expect(d2 == null);

    const d3 = parseLogDateFromFilename("2026-99-99_dynip.log");
    try std.testing.expect(d3 == null);
}

test "daysSinceEpoch accurately computes day difference across months" {
    const days_jul28 = daysSinceEpoch(2026, 7, 28);
    const days_aug14 = daysSinceEpoch(2026, 8, 14);
    try std.testing.expectEqual(@as(i64, 17), days_aug14 - days_jul28);

    const days_aug07 = daysSinceEpoch(2026, 8, 7);
    try std.testing.expectEqual(@as(i64, 7), days_aug14 - days_aug07);
}
