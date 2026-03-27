//! `dynip` CLI 入口。
//!
//! 這支可執行檔現在只保留一種模式：
//! - `service`：啟動 DDNS 常駐排程。

/// 匯入 Zig 標準函式庫。
///
/// CLI 參數、IO、JSON 字串化與基本工具都會從 `std` 取得。
const std = @import("std");
/// 匯入全域設定模組。
///
/// `main` 會先用它讀入 `app.json`、`.env` 和系統環境變數。
const config = @import("config.zig");
/// 匯入日誌模組。
///
/// 用來接管 `std.log`，並在服務啟動時寫入設定內容。
const logging = @import("logging.zig");
/// 匯入排程模組。
///
/// 命令列解析完成後，真正的常駐循環會交給這個模組。
const scheduler = @import("scheduler.zig");
const c = @cImport({
    @cInclude("signal.h");
    @cInclude("stdlib.h");
});

/// `std_options` 是 Zig 提供的一個特殊常數名稱。
///
/// 如果你在根模組宣告它，Zig 標準庫的一些行為就會依照這裡的設定調整。
/// 這個專案主要拿它來客製：
/// - 預設 log 等級
/// - `std.log` 最後要呼叫哪個函式
pub const std_options: std.Options = .{
    // 這裡把預設 log level 設成 `debug`，
    // 所以 info / warn / error / debug 都會進到我們的 logging 模組。
    .log_level = .debug,
    // 指定真正處理 log 的函式是 `logging.logFn`。
    // 之後專案裡面呼叫 `std.log.info(...)` 之類的 API，
    // 最終都會流到 `src/logging.zig`。
    .logFn = logging.logFn,
};

/// 全域 shutdown 旗標，signal handler 只做這一件事。
var shutdown_requested: std.atomic.Value(bool) = .init(false);

/// 將 CLI 用法寫到標準錯誤，供參數不正確時顯示。
fn printUsage(io: std.Io) !void {
    // 先準備一塊固定大小的記憶體當作輸出 buffer。
    // 初學先把它理解成：writer 寫字前暫時放資料的地方。
    var stderr_buffer: [256]u8 = undefined;

    // 取得 stderr 的 writer，之後就可以往標準錯誤輸出訊息。
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // `writeAll` 會把整段字串完整寫出去。
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

    // 有些 writer 會先把內容留在 buffer，`flush` 會強制送出去。
    try stderr.flush();
}

/// 判斷某個參數是不是常見的 help flag。
///
/// 這個小函式的好處是：
/// 之後如果不同地方都要判斷 `--help` / `-h`，
/// 就不用把同一段比較邏輯重複寫很多次。
fn isHelpFlag(arg: []const u8) bool {
    // `std.mem.eql(u8, a, b)` 代表：
    // 用 byte-by-byte 的方式比較兩段字串是否完全相同。
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// 目前只支援 `service` 這個模式。
fn runCommand(
    arena_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stop_token: ?scheduler.StopToken,
) !void {
    // 如果完全沒有帶任何子命令，
    // 代表使用者輸入的東西不符合我們這支 CLI 的需求。
    if (args.len == 0) {
        // 先把 usage 印給使用者看。
        try printUsage(io);
        // 再回傳一個明確的錯誤，讓上層知道是參數不正確。
        return error.InvalidArguments;
    }

    // 如果唯一的參數就是 `--help` 或 `-h`，
    // 代表使用者只是想看說明，不是要真的啟動服務。
    if (args.len == 1 and isHelpFlag(args[0])) {
        try printUsage(io);
        return;
    }

    // 這個專案目前只接受 `service` 這一種子命令。
    // 所以如果第一個參數不是 `service`，就視為錯誤。
    if (!std.mem.eql(u8, args[0], "service")) {
        try printUsage(io);
        return error.InvalidArguments;
    }

    // `dynip service --help` 也是合法寫法，
    // 所以這裡單獨處理。
    if (args.len == 2 and isHelpFlag(args[1])) {
        try printUsage(io);
        return;
    }

    // 把第一個子命令 `service` 拿掉，
    // 後面剩下的才是 `service` 子命令自己的選項。
    const option_args = args[1..];

    // 這個 switch 負責解析 `--config` 選項。
    //
    // 目前允許兩種情況：
    // 1. 沒帶任何額外選項 => 用預設 `app.json`
    // 2. 明確帶 `--config <path>` => 用指定路徑
    const config_path: []const u8 = switch (option_args.len) {
        // 沒帶額外選項時，直接回傳預設設定檔路徑。
        0 => config.default_config_path,
        // 如果有兩個額外參數，就預期它應該長成 `--config 某個路徑`。
        2 => blk: {
            // 第一個選項必須是字面值 `--config`，
            // 否則就不接受。
            if (!std.mem.eql(u8, option_args[0], "--config")) {
                try printUsage(io);
                return error.InvalidArguments;
            }
            // `break :blk option_args[1]` 的意思是：
            // 把第二個參數，也就是實際路徑，當作這個 block 的結果回傳出去。
            break :blk option_args[1];
        },
        // 其他長度目前都視為不合法。
        else => {
            try printUsage(io);
            return error.InvalidArguments;
        },
    };

    // 真的把設定載入記憶體。
    //
    // 這個過程會依照專案規則讀：
    // 1. `app.json`
    // 2. `.env`
    // 3. 系統環境變數
    const app_config = try config.loadLeaky(arena_allocator, io, config_path);

    // 啟動時把最後生效的設定寫進日誌，
    // 方便之後確認服務實際用了哪些值。
    try logLoadedConfig(allocator, app_config);

    // 再寫一筆簡短訊息，說明這次服務用的是哪個設定檔路徑。
    std.log.info("ddns scheduler will use config: {s}", .{config_path});

    // 最後把控制權交給排程器。
    // 這裡之後通常就不會回來，因為服務會持續常駐。
    try scheduler.runForever(allocator, io, app_config, stop_token);
}

/// 在服務啟動時，把實際載入到記憶體的設定輸出成格式化 JSON。
fn logLoadedConfig(allocator: std.mem.Allocator, app_config: config.AppConfig) !void {
    // 為了安全，我們不直接印出原始設定，而是請 config 模組建立遮罩後的副本。
    // 這樣所有敏感欄位規則都只維護在同一個地方。
    const masked_config = config.redactedForLog(app_config);

    // 先建立一個可成長的 byte 陣列，等等拿來裝 JSON 文字。
    var json_buffer = std.ArrayList(u8).empty;
    // 函式結束前把這塊記憶體釋放掉。
    defer json_buffer.deinit(allocator);

    // `Allocating writer` 是一種會自動把內容寫進動態陣列的 writer。
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_buffer);
    // 如果中途失敗，先清掉 writer 自己握住的資源。
    errdefer writer.deinit();

    // 把遮罩後的 masked_config 轉成格式化 JSON。
    try std.json.Stringify.value(masked_config, .{ .whitespace = .indent_2 }, &writer.writer);

    // 把資料拿回 json_buffer。
    // `toArrayList()` 的作用是把 writer 暫時接管的底層陣列還給我們。
    json_buffer = writer.toArrayList();

    // 這裡再組出一段完整訊息，
    // 目的是讓日誌裡會先出現一行標題，再接真正的 JSON 內容。
    const message = try std.fmt.allocPrint(
        allocator,
        "service loaded config (sensitive data masked):\n{s}",
        .{json_buffer.items},
    );
    // 這段訊息字串是暫時配置的，所以函式離開前要釋放。
    defer allocator.free(message);

    // 真正把整理好的訊息寫進 info 等級的檔案日誌。
    logging.infoFile(message);
}

/// 註冊 SIGINT / SIGTERM 的 signal handler。
///
/// handler 本身只會把全域 shutdown 旗標設成 `true`，
/// 真正的收尾邏輯仍在主流程與 scheduler 內完成。
fn installShutdownSignalHandlers() void {
    // 註冊 Ctrl+C 對應的 SIGINT handler。
    _ = c.signal(c.SIGINT, handleShutdownSignal);
    // 有些平台也支援 SIGTERM，所以這裡先檢查 C import 裡有沒有這個常數。
    if (@hasDecl(c, "SIGTERM")) {
        // 如果有，就把它也接到同一個 shutdown handler。
        _ = c.signal(c.SIGTERM, handleShutdownSignal);
    }
}

/// C signal handler 入口。
///
/// 這裡只做 async-signal-safe 的最小工作：更新 atomic 旗標。
fn handleShutdownSignal(_: c_int) callconv(.c) void {
    // 這裡不能做太複雜的事情，
    // 因為 signal handler 要盡量只做最小、最安全的工作。
    // 所以我們只更新 atomic 旗標，讓正常流程自己觀察到後再收尾。
    shutdown_requested.store(true, .monotonic);
}

/// 直接把一行訊息寫到 stderr。
fn writeStderrLine(io: std.Io, text: []const u8) void {
    // 先準備一塊固定大小 buffer，提供 stderr writer 使用。
    var stderr_buffer: [256]u8 = undefined;
    // 從標準錯誤建立 writer，這樣下面就能寫字到 stderr。
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    // 取出通用 writer 介面，方便用 `writeAll`。
    const stderr = &stderr_writer.interface;

    // 先寫真正的訊息內容。
    stderr.writeAll(text) catch return;
    // 再補一個換行，讓終端輸出整齊。
    stderr.writeAll("\n") catch return;
    // 最後把 buffer 裡可能尚未送出的資料 flush 出去。
    stderr.flush() catch {};
}

/// 用指定 exit status 結束程式，並先把訊息寫到 stderr。
fn exitWithCliError(io: std.Io, status: c_int, text: []const u8) noreturn {
    // 先把人看得懂的錯誤訊息印出來。
    writeStderrLine(io, text);
    // 再用指定的 exit code 結束整個程式。
    c.exit(status);
}

/// 把常見啟動錯誤轉成較友善的 CLI 輸出。
fn handleMainError(io: std.Io, err: anyerror) noreturn {
    // 針對我們已知的常見錯誤，改成較友善、較穩定的 CLI 訊息。
    switch (err) {
        // 參數錯誤通常代表使用方式不對，所以回傳 exit code 2。
        error.InvalidArguments => exitWithCliError(io, 2, "error: invalid arguments"),
        // 沒有任何 DDNS 供應商可用時，明確提示是設定問題。
        error.NoEnabledDdnsService => exitWithCliError(io, 1, "error: no DDNS provider is enabled or fully configured"),
        else => {
            // 其他錯誤就退而求其次，把 Zig 的 error name 轉成字串印出。
            var buffer: [256]u8 = undefined;
            // 用固定 buffer 組出 `error: 某某錯誤名`，避免這裡再額外配置記憶體。
            const text = std.fmt.bufPrint(&buffer, "error: {s}", .{@errorName(err)}) catch "error: unexpected failure";
            // 印完之後用 exit code 1 結束。
            exitWithCliError(io, 1, text);
        },
    }
}

/// 主入口只做 DDNS 指令解析。
pub fn main(init: std.process.Init) !void {
    // `main` 的參數不是傳統的 `argc/argv`，
    // Zig 會把啟動程式時需要的資源包在 `init` 裡。

    // `gpa` 是程式啟動時提供的 allocator。
    // 你可以把 allocator 想成「負責幫你借記憶體 / 還記憶體的人」。
    const allocator = init.gpa;

    // `io` 讓你存取 stdin / stdout / stderr 等 IO 資源。
    const io = init.io;

    logging.init(io) catch |err| {
        logging.errorConsoleFmt("failed to initialize logger: {}", .{err});
    };
    defer logging.deinit();
    installShutdownSignalHandlers();

    // 把命令列參數轉成 slice，方便用陣列方式存取。
    // `args[0]` 通常是程式名稱本身。
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // `init.arena.allocator()` 很適合拿來放「整個程式都會用到」的設定資料，
    // 例如 DDNS 的 config 字串。
    const arena_allocator = init.arena.allocator();
    const stop_token = scheduler.StopToken{ .requested = &shutdown_requested };

    // 最後把真正的命令列解析工作交給 `runCommand(...)`。
    // 這裡用 `args[1..]` 是因為 `args[0]` 通常只是程式名稱本身。
    runCommand(arena_allocator, allocator, io, args[1..], stop_token) catch |err| {
        if (shutdown_requested.load(.monotonic)) {
            std.log.info("service shutdown completed", .{});
            return;
        }
        handleMainError(io, err);
    };

    if (shutdown_requested.load(.monotonic)) {
        std.log.info("service shutdown completed", .{});
    }
}
