//! 專案自用的 C / platform shim。
//!
//! - `shim` 可以理解成「薄薄一層轉接器」。
//! - 原本可以用 `translate-c` 把 C header 自動翻成 Zig declarations。
//! - 但本專案只需要少數 C / Win32 API，自動翻譯整包 header 反而會讓
//!   Windows locale / Perl 工具鏈變成 build 風險。
//! - 所以這裡手寫最小需要的 declarations，讓 `@import("c")` 的呼叫端
//!   不需要知道底層是 C、Win32，還是 Zig 標準庫。
//!
//! 這個檔案刻意不要放業務邏輯；它只處理平台 API 的形狀差異。

const std = @import("std");
const builtin = @import("builtin");

/// C `time_t` 的專案內部表示。
///
/// 專案內部一律用 64-bit Unix seconds。
/// 直接固定成 `i64` 可以避免引入 `translate-c` 只為了取得 typedef；
/// 和 libc 實際 `time_t` 寬度的差異由下方 `LibcTime` 與 `posix` 宣告吸收。
pub const time_t = i64;

/// Ctrl+C 對應的 C signal 編號。
///
/// POSIX 平台真的會呼叫 C `signal(SIGINT, ...)`。
/// Windows 平台則會在 `handleWindowsConsoleSignal()` 裡把 console event
/// 轉成這個專案熟悉的 SIGINT 語意。
pub const SIGINT: c_int = 2;
/// 常見「要求程序結束」的 signal 編號。
///
/// Windows 沒有完全相同的 POSIX SIGTERM 行為，所以這裡只把 close/logoff/shutdown
/// 這類 console event 映射成 SIGTERM，讓上層 CLI 可以共用同一套 shutdown flag。
pub const SIGTERM: c_int = 15;

/// 專案用到的 C `struct tm` 欄位。
///
/// `extern struct` 的意思是：
/// - 欄位排列要遵守 C ABI，不讓 Zig 自己重新最佳化 layout。
/// - 這樣才能安全接 C 的 `localtime()` 回傳資料。
///
/// 這裡只宣告本專案會讀的欄位，但順序仍需符合常見 C `struct tm`。
pub const struct_tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};

/// C signal callback 的型別。
///
/// `?*const fn (...)` 代表：
/// - `?`：這是一個 optional，可能是 null。
/// - `*const fn`：指向函式的指標，函式本身不可被修改。
/// - `callconv(.c)`：這個函式要用 C calling convention，才能被 C signal API 呼叫。
pub const SignalHandler = ?*const fn (c_int) callconv(.c) void;

/// 取得目前 Unix timestamp 秒數。
///
/// 呼叫端把它當成 C `time()` 用：
/// - 傳 `null`：只要回傳值。
/// - 傳一個 `*time_t`：除了回傳，也把結果寫進指標指向的位置。
///
/// Windows 分支不用 C runtime 的 `time()`，改用 Win32 `GetSystemTimeAsFileTime()`。
/// 這樣可以保持 shim 自己掌控平台差異。
pub fn time(timer: ?*time_t) time_t {
    // 這裡刻意傳 null 給 libc：libc 的 `time_t` 寬度可能和本專案的 `time_t`（i64）不同，
    // 寫回 caller 指標的工作統一由下面的 `if (timer)` 處理。
    const now: time_t = if (builtin.os.tag == .windows) windowsTime() else posix.time(null);
    // C `time()` 的語意是：如果 caller 有傳 output pointer，就順手寫入。
    // Zig 的 `if (optional) |value|` 是解開 optional 的常見寫法。
    if (timer) |out| out.* = now;
    return now;
}

/// 註冊 shutdown signal handler。
///
/// POSIX 平台直接轉呼叫 C `signal()`。
/// Windows 平台沒有 POSIX signal，同等需求要透過 `SetConsoleCtrlHandler()`。
pub fn signal(sig: c_int, handler: SignalHandler) SignalHandler {
    if (builtin.os.tag != .windows) return posix.signal(sig, handler);
    return windowsSignal(sig, handler);
}

/// 結束程序。
///
/// 呼叫端原本使用 C `exit(status)`；這裡改轉成 Zig 標準庫的
/// `std.process.exit()`，讓 Windows / POSIX 都走 Zig 支援的程序結束流程。
pub fn exit(status: c_int) noreturn {
    std.process.exit(@intCast(status));
}

/// Thread-safe localtime wrapper。
///
/// POSIX 有 `localtime_r()`，Windows 沒有同名 API。
/// 呼叫端只需要 `localtime_r()` 這個形狀，所以 shim 在這裡提供同名函式。
///
/// 目前只有非 Windows 分支真的會呼叫這個函式；Windows 取得本地時間的邏輯
/// 在 `logging.zig` / `ddns.zig` 裡使用 Win32 `GetLocalTime()`。
pub fn localtime_r(timer: *const time_t, result: *struct_tm) ?*struct_tm {
    // 轉成 libc 自己的 `time_t` 寬度再傳指標，不能直接把 `*i64` 交給 32-bit `time_t` 的 libc。
    const libc_timer: LibcTime = std.math.cast(LibcTime, timer.*) orelse return null;
    const local_time = posix.localtime(&libc_timer) orelse return null;
    // C `localtime()` 回傳的是指向靜態記憶體的 pointer。
    // 為了模擬 `localtime_r()`，我們把內容 copy 到 caller 提供的 result。
    result.* = local_time.*;
    return result;
}

/// Windows 版 Unix timestamp。
///
/// Win32 `FILETIME` 是從 1601-01-01 開始，以 100ns 為單位。
/// Unix timestamp 是從 1970-01-01 開始，以秒為單位。
/// 所以需要：
/// 1. 把 high/low 32-bit 合成 64-bit ticks。
/// 2. 除以 10,000,000，把 100ns ticks 轉成 seconds。
/// 3. 減掉 Windows epoch 到 Unix epoch 的秒數差。
fn windowsTime() time_t {
    var file_time: FILETIME = undefined;
    kernel32.GetSystemTimeAsFileTime(&file_time);

    const ticks_since_windows_epoch =
        (@as(u64, file_time.dwHighDateTime) << 32) | @as(u64, file_time.dwLowDateTime);
    const seconds_since_windows_epoch = ticks_since_windows_epoch / 10_000_000;
    return @intCast(seconds_since_windows_epoch - 11_644_473_600);
}

var windows_sigint_handler: SignalHandler = null;
var windows_sigterm_handler: SignalHandler = null;
var windows_console_handler_installed = false;

/// Windows 版 signal registration。
///
/// C `signal()` 會回傳「先前註冊的 handler」。
/// 所以這裡也保留同樣語意：把新 handler 存起來，並回傳舊 handler。
fn windowsSignal(sig: c_int, handler: SignalHandler) SignalHandler {
    installWindowsConsoleHandler();

    return switch (sig) {
        SIGINT => swapSignalHandler(&windows_sigint_handler, handler),
        SIGTERM => swapSignalHandler(&windows_sigterm_handler, handler),
        else => null,
    };
}

/// 把某個 handler slot 換成新值，並回傳舊值。
///
/// 這個小 helper 讓 `windowsSignal()` 保持接近 C `signal()` 的行為。
fn swapSignalHandler(slot: *SignalHandler, handler: SignalHandler) SignalHandler {
    const previous = slot.*;
    slot.* = handler;
    return previous;
}

/// 安裝 Windows console control handler。
///
/// 只安裝一次，因為 `SetConsoleCtrlHandler()` 是 process-wide 設定；
/// 重複安裝同一個 callback 沒有必要，也會讓行為較難推理。
fn installWindowsConsoleHandler() void {
    if (windows_console_handler_installed) return;
    windows_console_handler_installed = true;
    _ = kernel32.SetConsoleCtrlHandler(handleWindowsConsoleSignal, 1);
}

/// Windows console event callback。
///
/// Windows 會用這個 callback 通知 Ctrl+C、關閉 console、登出、關機等事件。
/// 回傳值語意：
/// - `1`：事件已處理，不再交給下一個 handler。
/// - `0`：這裡不處理，交給系統或其他 handler。
fn handleWindowsConsoleSignal(ctrl_type: u32) callconv(.winapi) c_int {
    const handler = switch (ctrl_type) {
        CTRL_C_EVENT, CTRL_BREAK_EVENT => windows_sigint_handler,
        CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT => windows_sigterm_handler,
        else => null,
    };

    if (handler) |callback| {
        callback(if (ctrl_type == CTRL_C_EVENT or ctrl_type == CTRL_BREAK_EVENT) SIGINT else SIGTERM);
        return 1;
    }

    return 0;
}

/// 32-bit Linux + musl 是否要改用 64-bit time 的 symbol。
///
/// musl 1.2 起，32-bit 平台的 `time_t` 一律是 64-bit，但 C header 會用
/// `__REDIR(time, __time64)` 把呼叫「轉址」到 `__time64` / `__localtime64`。
/// 原本的 `time` / `localtime` symbol 只是給舊程式用的 32-bit 相容版本：
/// `time` 只回傳 32-bit，若照 `i64` 宣告去接，高 32 位元會是暫存器裡的垃圾值。
///
/// 我們沒有走 C header（沒有 translate-c），所以要自己做同樣的轉址。
/// 這個問題實際發生在 Raspberry Pi（`arm-linux-musleabihf`）上：
/// `next_retry_at` 等時間戳變成 `-2503822690` 這種負數。
const use_musl_time64 = builtin.os.tag == .linux and
    builtin.abi.isMusl() and
    @bitSizeOf(usize) == 32;

/// libc 自己的 `time_t` 寬度。
///
/// - 64-bit 平台：`long` 本來就是 64-bit。
/// - 32-bit musl：走 `__time64` 系列 symbol，是 64-bit。
/// - 其他 32-bit libc（例如舊版 glibc）：`time` 回傳 32-bit 的 `long`。
const LibcTime = if (use_musl_time64) i64 else c_long;

/// POSIX / libc declarations。
///
/// `extern "c"` 告訴 Zig：
/// - 這些函式不是 Zig 實作的。
/// - linker 需要去 C runtime 裡找 symbol。
/// - 呼叫時使用 C ABI。
///
/// `time` / `localtime` 用 `@extern` 依平台選 symbol 名稱，原因見 `use_musl_time64`。
const posix = struct {
    const time = @extern(*const fn (timer: ?*LibcTime) callconv(.c) LibcTime, .{
        .name = if (use_musl_time64) "__time64" else "time",
        .library_name = "c",
    });
    const localtime = @extern(*const fn (timer: *const LibcTime) callconv(.c) ?*struct_tm, .{
        .name = if (use_musl_time64) "__localtime64" else "localtime",
        .library_name = "c",
    });
    extern "c" fn signal(sig: c_int, handler: SignalHandler) SignalHandler;
};

/// Win32 `FILETIME` layout。
///
/// 這個 struct 必須和 Windows API 文件中的欄位順序一致，
/// 所以使用 `extern struct`。
const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

const CTRL_C_EVENT: u32 = 0;
const CTRL_BREAK_EVENT: u32 = 1;
const CTRL_CLOSE_EVENT: u32 = 2;
const CTRL_LOGOFF_EVENT: u32 = 5;
const CTRL_SHUTDOWN_EVENT: u32 = 6;

/// Win32 kernel32 declarations。
///
/// `if (builtin.os.tag == .windows) ... else struct {}` 的寫法讓非 Windows
/// target 不會看到不存在的 Win32 extern symbol。
const kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;
    extern "kernel32" fn SetConsoleCtrlHandler(
        HandlerRoutine: ?*const fn (u32) callconv(.winapi) c_int,
        Add: c_int,
    ) callconv(.winapi) c_int;
} else struct {};
