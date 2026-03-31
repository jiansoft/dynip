//! `dynip` CLI 與服務啟動流程。
//!
//! 這個模組負責：
//! - 解析命令列參數
//! - 顯示 help / usage
//! - 載入設定檔
//! - 初始化 logger
//! - 安裝 shutdown signal handler
//! - 啟動常駐排程器
//!
//! 可執行檔入口 [`main.zig`](main.zig) 只保留很薄的一層轉呼叫，
//! 讓這裡可以專心處理「程式怎麼啟動」這件事。

/// 匯入 Zig 標準函式庫。
///
/// CLI 參數、字串比較、JSON 輸出、allocator 與 IO 都從這裡取得。
const std = @import("std");
/// 匯入專案共用根模組。
///
/// 這樣就能從單一入口拿到 config / logging / scheduler 等模組。
const dynip = @import("root.zig");
/// 設定模組，負責讀取 `app.json`、`.env` 與環境變數。
const config = dynip.config;
/// 日誌模組，接管 `std.log` 並寫入檔案。
const logging = dynip.logging;
/// 排程模組，真正的常駐服務循環會交給它。
const scheduler = dynip.scheduler;
/// 匯入 C 的 signal / exit API。
///
/// 這裡主要會用到：
/// - `signal`：註冊 SIGINT / SIGTERM handler
/// - `exit`：以指定狀態碼結束程式
const c = @cImport({
    @cInclude("signal.h");
    @cInclude("stdlib.h");
});

/// `std_options` 是 Zig 提供的特殊常數名稱。
///
/// 只要在根模組或主執行流程模組宣告它，
/// Zig 標準庫中的 logging 行為就會依照這裡的設定調整。
///
/// 這個專案在這裡做兩件事：
/// - 預設開到 `debug` 等級
/// - 把所有 `std.log.*` 呼叫導向 `logging.logFn`
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

/// 全域 shutdown 旗標。
///
/// signal handler 本身只做最小工作：把這個 atomic flag 設成 `true`。
/// 真正的收尾與停止邏輯，仍然由主流程與 scheduler 觀察後處理。
var shutdown_requested: std.atomic.Value(bool) = .init(false);

/// 將 CLI 用法寫到標準錯誤。
///
/// 當使用者帶錯參數，或明確要求 `--help` / `-h` 時，
/// 都會呼叫這個函式。
fn printUsage(io: std.Io) !void {
    // 先準備固定大小的 buffer 給 stderr writer 使用。
    var stderr_buffer: [256]u8 = undefined;
    // 取得 stderr writer。
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    // 拿出通用 writer 介面，之後比較方便呼叫 `writeAll`。
    const stderr = &stderr_writer.interface;

    // 把完整 usage 一次寫到 stderr。
    try stderr.writeAll(
        \\Usage:
        \\  dynip service [--config <path>]
        \\  dynip --help
        \\
        \\Example:
        \\  dynip service --config app.json
        \\
        \\Default config path:
        \\  app.json
        \\
    );

    // 強制把 buffer 裡的內容送出去，避免訊息還停在記憶體裡。
    try stderr.flush();
}

/// 判斷某個參數是不是 help flag。
///
/// 這樣不同地方如果都要判斷 `--help` 或 `-h`，
/// 就不需要重複寫字串比較邏輯。
fn isHelpFlag(arg: []const u8) bool {
    // `std.mem.eql(u8, a, b)` 代表逐 byte 比較兩段字串是否相等。
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// 解析 CLI 子命令，並在合法時啟動服務。
///
/// 目前只支援一個子命令：
/// - `service`
///
/// 允許的形式如下：
/// - `dynip service`
/// - `dynip service --config app.json`
/// - `dynip --help`
fn runCommand(
    arena_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stop_token: ?scheduler.StopToken,
) !void {
    // 完全沒帶子命令，視為 CLI 使用方式錯誤。
    if (args.len == 0) {
        try printUsage(io);
        return error.InvalidArguments;
    }

    // 只有一個參數且是 help flag，代表使用者只想看說明。
    if (args.len == 1 and isHelpFlag(args[0])) {
        try printUsage(io);
        return;
    }

    // 目前只接受 `service` 這一種子命令。
    if (!std.mem.eql(u8, args[0], "service")) {
        try printUsage(io);
        return error.InvalidArguments;
    }

    // `dynip service --help` 也是合法寫法。
    if (args.len == 2 and isHelpFlag(args[1])) {
        try printUsage(io);
        return;
    }

    // 把 `service` 子命令本身拿掉，
    // 後面才是屬於 `service` 的選項。
    const option_args = args[1..];
    // 解析 `--config <path>`。
    const config_path: []const u8 = switch (option_args.len) {
        // 沒帶額外選項時，就走預設 `app.json`。
        0 => config.default_config_path,
        // 如果帶兩個參數，就只接受 `--config 某路徑`。
        2 => blk: {
            if (!std.mem.eql(u8, option_args[0], "--config")) {
                try printUsage(io);
                return error.InvalidArguments;
            }
            // 把實際路徑當成這個 block 的回傳值。
            break :blk option_args[1];
        },
        // 其他長度都視為不合法。
        else => {
            try printUsage(io);
            return error.InvalidArguments;
        },
    };

    // 依照專案規則載入設定：
    // 1. `app.json`
    // 2. `.env`
    // 3. process environment variables
    const app_config = try config.loadLeaky(arena_allocator, io, config_path);
    // 啟動前先把敏感資訊遮罩後的設定寫進日誌。
    try logLoadedConfig(allocator, app_config);
    // 補一筆簡短訊息，說明這次啟動用哪個設定檔路徑。
    std.log.info("ddns scheduler will use config: {s}", .{config_path});
    // 真正把控制權交給常駐排程器。
    try scheduler.runForever(allocator, io, app_config, stop_token);
}

/// 把實際生效的設定轉成 JSON 寫進檔案日誌。
///
/// 為了避免密碼與 token 外洩，這裡會先呼叫
/// `config.redactedForLog(...)` 產生已遮罩的副本。
fn logLoadedConfig(allocator: std.mem.Allocator, app_config: config.AppConfig) !void {
    // 先建立「適合寫 log」的安全副本。
    const masked_config = config.redactedForLog(app_config);

    // 準備一個可成長的 byte buffer 來裝 JSON 字串。
    var json_buffer = std.ArrayList(u8).empty;
    // 函式結束前把動態記憶體釋放掉。
    defer json_buffer.deinit(allocator);

    // 這種 writer 會把輸出內容自動累積到 ArrayList 裡。
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_buffer);
    // 如果中途失敗，先清掉 writer 自己握住的資源。
    errdefer writer.deinit();

    // 轉成格式化 JSON，方便人類閱讀。
    try std.json.Stringify.value(masked_config, .{ .whitespace = .indent_2 }, &writer.writer);
    // 把 writer 暫時接管的底層陣列拿回來。
    json_buffer = writer.toArrayList();

    // 補一個標題，再接真正的 JSON 本體。
    const message = try std.fmt.allocPrint(
        allocator,
        "service loaded config (sensitive data masked):\n{s}",
        .{json_buffer.items},
    );
    // 這段字串是暫時配置的，用完要釋放。
    defer allocator.free(message);

    // 寫進 info 等級的檔案日誌。
    logging.infoFile(message);
}

/// 安裝常見的 shutdown signal handler。
///
/// 目前會處理：
/// - `SIGINT`：例如 Ctrl+C
/// - `SIGTERM`：如果平台有提供
fn installShutdownSignalHandlers() void {
    // Ctrl+C 對應的 SIGINT。
    _ = c.signal(c.SIGINT, handleShutdownSignal);
    // 有些平台會有 SIGTERM，先檢查再註冊。
    if (@hasDecl(c, "SIGTERM")) {
        _ = c.signal(c.SIGTERM, handleShutdownSignal);
    }
}

/// C signal handler 入口。
///
/// signal handler 內要盡量只做 async-signal-safe 的最小工作，
/// 所以這裡只更新 atomic flag，不做 IO、不配置記憶體。
fn handleShutdownSignal(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .monotonic);
}

/// 直接把一行訊息寫到 stderr。
///
/// 這個函式故意忽略寫入失敗，因為它常用在程式準備退出時，
/// 那時候我們只想盡量把錯誤訊息顯示出來。
fn writeStderrLine(io: std.Io, text: []const u8) void {
    // 準備固定大小 buffer。
    var stderr_buffer: [256]u8 = undefined;
    // 建立 stderr writer。
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // 先寫文字本體。
    stderr.writeAll(text) catch return;
    // 再補換行。
    stderr.writeAll("\n") catch return;
    // 最後嘗試 flush。
    stderr.flush() catch {};
}

/// 先把 CLI 錯誤寫到 stderr，再用指定 exit code 結束。
fn exitWithCliError(io: std.Io, status: c_int, text: []const u8) noreturn {
    writeStderrLine(io, text);
    c.exit(status);
}

/// 把常見錯誤轉成較穩定、較友善的 CLI 錯誤訊息。
///
/// 這樣使用者在終端看到的輸出，不會直接暴露太多內部實作細節。
fn handleMainError(io: std.Io, err: anyerror) noreturn {
    switch (err) {
        // 參數錯誤通常會用 exit code 2。
        error.InvalidArguments => exitWithCliError(io, 2, "error: invalid arguments"),
        // 這代表設定檔雖然有載入，但沒有任何可實際更新的 DDNS provider。
        error.NoEnabledDdnsService => exitWithCliError(
            io,
            1,
            "error: no DDNS provider is enabled or fully configured",
        ),
        else => {
            // 其他錯誤就退而求其次，印出 Zig 的 error name。
            var buffer: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "error: {s}", .{@errorName(err)}) catch
                "error: unexpected failure";
            exitWithCliError(io, 1, text);
        },
    }
}

/// CLI 主入口。
///
/// 這裡負責：
/// - 初始化 logger
/// - 安裝 signal handler
/// - 取得命令列參數
/// - 建立 stop token
/// - 呼叫 `runCommand(...)`
pub fn main(init: std.process.Init) !void {
    // `gpa` 是程式啟動時提供的 allocator。
    const allocator = init.gpa;
    // `io` 讓我們能取得 stdin / stdout / stderr 等資源。
    const io = init.io;

    // 先初始化檔案 logger。
    logging.init(io) catch |err| {
        logging.errorConsoleFmt("failed to initialize logger: {}", .{err});
    };
    // 程式結束前收掉 logger。
    defer logging.deinit();
    // 註冊 Ctrl+C / SIGTERM。
    installShutdownSignalHandlers();

    // 把命令列參數轉成 slice，方便用陣列方式處理。
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // arena allocator 很適合用來存放整個程式生命週期都要保留的設定資料。
    const arena_allocator = init.arena.allocator();
    // 把全域 shutdown flag 包成 scheduler 能理解的 stop token。
    const stop_token = scheduler.StopToken{ .requested = &shutdown_requested };

    // 把真正的 CLI 解析工作交給 `runCommand(...)`。
    // `args[0]` 通常是程式名稱本身，所以這裡從 `args[1..]` 開始。
    runCommand(arena_allocator, allocator, io, args[1..], stop_token) catch |err| {
        // 如果錯誤發生時其實是因為收到 shutdown signal，
        // 就不要把它當成失敗，而是當成正常收尾。
        if (shutdown_requested.load(.monotonic)) {
            std.log.info("service shutdown completed", .{});
            return;
        }
        // 否則轉成 CLI 友善的錯誤輸出。
        handleMainError(io, err);
    };

    // 如果是正常收到 shutdown signal 後離開，
    // 最後再補一筆完成訊息。
    if (shutdown_requested.load(.monotonic)) {
        std.log.info("service shutdown completed", .{});
    }
}
