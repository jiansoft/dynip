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
//!
//! ## 啟動流程總覽
//!
//! 從按下 Enter 到服務開始跑，程式會照這個順序走一遍：
//!
//! ```text
//! main()
//!   ├─ logging.init()                  建立檔案 logger（此時還沒讀設定，用預設等級）
//!   ├─ installShutdownSignalHandlers() 註冊 Ctrl+C / SIGTERM
//!   ├─ init.minimal.args.toSlice()     取得命令列參數
//!   └─ runCommand()
//!        ├─ commandArgsOrDefault()     沒帶參數就補成 `service`
//!        ├─ 解析子命令與 `--config`
//!        ├─ config.loadLeaky()         app.json → .env → 環境變數，後者覆蓋前者
//!        ├─ logging.configure()        設定讀完才知道日誌等級與 Seq 位址，這時才套用
//!        ├─ logLoadedConfig()          把遮罩過的設定寫進日誌，方便事後對帳
//!        ├─ std.Thread.spawn()         Dashboard 跑在背景 thread（若啟用）
//!        └─ scheduler.runForever()     控制權交出去，正常情況下不會返回
//! ```
//!
//! ## 幾個一再出現的名詞
//!
//! 這些東西在下面每個函式的參數列都會看到，先在這裡解釋一次：
//!
//! - **`io`**（`std.Io`）：Zig 0.16 之後的 IO 介面。檔案讀寫、stderr、sleep、網路
//!   都要透過它，而不是直接呼叫作業系統。好處是同一份程式碼可以換不同的 IO 實作
//!   （例如測試時換成假的），也讓「這個函式會不會碰 IO」從型別上就看得出來。
//! - **`allocator` 與 `arena_allocator`**：兩個都是記憶體配置器，差別在回收方式。
//!   一般 allocator 配置的每一塊都要自己 `free`；arena 則是「先一直配置，最後整塊丟掉」。
//!   設定資料活到程式結束，用 arena 最省事（不必逐一釋放）；生命週期短的暫時字串
//!   則用一般 allocator 並搭配 `defer free`。
//! - **`stop_token`**：一個指向 [`shutdown_requested`] 的小包裝，讓 scheduler 能定期
//!   問「使用者要求停止了嗎？」。signal handler 不能做複雜的事，所以只能用這種
//!   「設旗標 + 別人來看」的方式傳遞停止意圖。

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
/// Dashboard HTTP server，與 DDNS scheduler 共用同一個 process。
const dashboard_server = dynip.dashboard_server;
/// 匯入 C 的 signal / exit API。
///
/// 這裡主要會用到：
/// - `signal`：註冊 SIGINT / SIGTERM handler
/// - `exit`：以指定狀態碼結束程式
const c = @import("c");

/// `std_options` 是 Zig 提供的特殊常數名稱。
///
/// 只要在根模組或主執行流程模組宣告它，
/// Zig 標準庫中的 logging 行為就會依照這裡的設定調整。
///
/// 這個專案在這裡做兩件事：
/// - 預設開到 `debug` 等級
/// - 把所有 `std.log.*` 呼叫導向 `logging.logFn`
///
/// 常見誤解：這裡設成 `.debug` **不代表**日誌檔會被 debug 訊息灌爆。
/// `log_level` 是「編譯期的上限」——低於這個等級的 `std.log.*` 呼叫會被整個編譯掉，
/// 連字串格式化都不會發生。真正決定「要不要寫出去」的是 `logging` 裡的
/// `console_level` / `file_level` / `seq_level`，那三個是執行期設定，來自 `.env`。
/// 上限開到 debug 只是讓「臨時把等級調成 debug 來抓問題」不必重新編譯。
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

/// 全域 shutdown 旗標。
///
/// signal handler 本身只做最小工作：把這個 atomic flag 設成 `true`。
/// 真正的收尾與停止邏輯，仍然由主流程與 scheduler 觀察後處理。
///
/// 為什麼是 `std.atomic.Value(bool)` 而不是普通的 `bool`：這個變數會被兩個執行脈絡
/// 同時碰到——signal handler（可能在任何時間點插進來）與主流程／scheduler。
/// 用一般變數時，編譯器可以合法地把「重複讀取同一個變數」優化成只讀一次，
/// 迴圈就永遠看不到旗標被改過。atomic 版本會擋掉這類優化，也保證讀寫不會被切成兩半。
///
/// 讀寫都用 `.monotonic`（最寬鬆的記憶體順序）是因為這裡只需要「這個 bool 本身正確」，
/// 不需要用它去保證其他資料的可見性順序，沒必要付更強順序的代價。
var shutdown_requested: std.atomic.Value(bool) = .init(false);

/// 空 CLI 參數時要套用的預設子命令。
///
/// `zig build run` 在 Zig 0.17-dev 的新 build API 裡，通常會把程式本體
/// 啟動成「沒有任何 app 參數」的狀態。也就是說，`runCommand(...)` 收到的
/// `args` 會是空 slice。
///
/// 這個專案希望新手直接輸入 `zig build run` 就能啟動 DDNS service，
/// 所以把空參數視為等同於：
///
/// ```text
/// dynip service
/// ```
///
/// 這裡用全域常數，而不是在 helper 裡建立區域陣列，是因為 helper 會回傳
/// slice。slice 只是「指向一段記憶體的視窗」，不能指向已經離開作用域的區域陣列。
const default_service_args = [_][]const u8{"service"};

/// 將 CLI 用法寫到標準錯誤。
///
/// 當使用者帶錯參數，或明確要求 `--help` / `-h` 時，
/// 都會呼叫這個函式。
///
/// # Arguments
/// * `io` - IO 介面，用來取得 stderr。
///
/// # Errors
/// 寫入或 flush stderr 失敗時回傳錯誤（例如輸出被導向到已關閉的 pipe）。
///
/// 為什麼寫 stderr 而不是 stdout：usage 屬於「給人看的診斷訊息」，不是程式的正常輸出。
/// 分開之後，`dynip ... > out.txt` 這種重導向不會把說明文字混進資料檔，
/// 使用者也仍然能在終端看到它。
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
///
/// # Arguments
/// * `arg` - 單一命令列參數，例如 `"--help"`、`"service"`。
///
/// # Returns
/// `arg` 等於 `--help` 或 `-h` 時為 `true`，其餘為 `false`。
fn isHelpFlag(arg: []const u8) bool {
    // `std.mem.eql(u8, a, b)` 代表逐 byte 比較兩段字串是否相等。
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// 將 CLI 子命令參數標準化成 parser 後續可以直接處理的形式。
///
/// `args` 的型別是 `[]const []const u8`，可以從右往左讀：
/// - `[]const u8`：一段不可修改的 byte 字串，例如 `"service"`
/// - `[]const []const u8`：多個不可修改字串組成的 slice，也就是參數列表
///
/// 規則很單純：
/// - 如果使用者有帶參數，就原樣回傳，避免改掉 `--help` 或 `--config`
/// - 如果使用者沒帶參數，就補成 `service`
///
/// # Arguments
/// * `args` - 已經去掉程式名稱（`args[0]`）的參數列表，可能是空的。
///
/// # Returns
/// 至少含一個元素的參數列表。呼叫端因此可以放心讀 `[0]` 而不必再檢查長度。
///
/// 注意回傳的 slice 有兩種來源：使用者傳進來的 `args`，或全域的
/// [`default_service_args`]。兩者的記憶體都活得比這個函式久，所以回傳 slice 是安全的。
fn commandArgsOrDefault(args: []const []const u8) []const []const u8 {
    // `args.len == 0` 代表沒有任何子命令或選項。
    if (args.len == 0) {
        // `default_service_args[0..]` 把固定長度陣列轉成 slice。
        // 後面的 parser 只需要 slice，不需要知道底層是陣列還是別的來源。
        return default_service_args[0..];
    }

    // 有帶參數時完全不改動，讓明確輸入的 CLI 行為優先。
    return args;
}

/// 解析 CLI 子命令，並在合法時啟動服務。
///
/// 目前只支援一個子命令：
/// - `service`
///
/// 允許的形式如下：
/// - `dynip service`
/// - `dynip service --config app.json`
/// - `dynip`
/// - `dynip --help`
///
/// # Arguments
/// * `arena_allocator` - 給「活到程式結束」的資料用（設定資料）。arena 會在程式收尾時
///   整塊釋放，所以這裡配置的東西不需要、也不應該逐一 `free`。
/// * `allocator` - 一般用途 allocator，給生命週期較短或需要精確回收的資料用
///   （例如 [`logLoadedConfig`] 的暫存 JSON、Seq sink 內部的 HTTP client）。
/// * `io` - IO 介面，往下傳給設定載入、logger、Dashboard 與 scheduler。
/// * `args` - 已去掉程式名稱的命令列參數。
/// * `stop_token` - 停止訊號的觀察端；`null` 代表呼叫端不打算中途停止（例如測試）。
///
/// # Errors
/// * `error.InvalidArguments` - 子命令或選項不合法，此時已經先印過 usage。
/// * 其他 - 設定載入、logger 設定、Dashboard thread 建立或 scheduler 執行過程的錯誤。
///
/// 正常情況下這個函式**不會返回**：最後一步 `scheduler.runForever(...)` 會一直跑，
/// 直到 stop token 被設起來或發生錯誤為止。
fn runCommand(
    arena_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stop_token: ?scheduler.StopToken,
) !void {
    // 先把「空參數」這個特殊情況收斂掉。
    // 後面的判斷就可以一律假設至少有一個 command_args[0] 可讀。
    const command_args = commandArgsOrDefault(args);

    // 只有一個參數且是 help flag，代表使用者只想看說明。
    if (command_args.len == 1 and isHelpFlag(command_args[0])) {
        try printUsage(io);
        return;
    }

    // 目前只接受 `service` 這一種子命令。
    if (!std.mem.eql(u8, command_args[0], "service")) {
        try printUsage(io);
        return error.InvalidArguments;
    }

    // `dynip service --help` 也是合法寫法。
    if (command_args.len == 2 and isHelpFlag(command_args[1])) {
        try printUsage(io);
        return;
    }

    // 把 `service` 子命令本身拿掉，
    // 後面才是屬於 `service` 的選項。
    const option_args = command_args[1..];
    // 解析 `--config <path>`。
    //
    // 這裡用 switch 直接對「選項的個數」分流，而不是寫一個通用的參數迴圈：
    // 目前只有一個選項，合法組合就只有 0 個或 2 個參數兩種，用長度判斷最直接。
    const config_path: []const u8 = switch (option_args.len) {
        // 沒帶額外選項時，就走預設 `app.json`。
        0 => config.default_config_path,
        // 如果帶兩個參數，就只接受 `--config 某路徑`。
        //
        // `blk: { ... break :blk value; }` 是 Zig 的 labeled block：
        // 讓一段需要多行邏輯的程式碼「當成一個值」用，`break :blk` 送出的就是它的值。
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
    // 設定載入完成後，才知道 Seq server URL / API key 是否有被 `.env` 覆寫。
    // 所以遠端 Seq logger 要在這裡啟用，而不是一開始初始化檔案 logger 時啟用。
    try logging.configure(allocator, io, app_config.logging);
    // 啟動前先把敏感資訊遮罩後的設定寫進日誌。
    try logLoadedConfig(allocator, app_config);
    // 補一筆簡短訊息，說明這次啟動用哪個設定檔路徑。
    std.log.info("ddns scheduler will use config: {s}", .{config_path});
    // Dashboard 和 DDNS scheduler 採用「同一個 OS process、不同 thread」。
    //
    // 新手閱讀重點：
    // - `std.Thread.spawn(...)` 會開一條背景 thread。
    // - thread entry point 是 `dashboard_server.runAndLog`。
    // - 傳進去的是同一份 `app_config`，所以 Dashboard 可讀到 host/port/provider enabled。
    // - Dashboard 最後仍然透過 `ddns.getProviderSnapshots()` 讀 process memory，
    //   沒有啟動第二個應用程式，也不直接連 Redis。
    if (app_config.dashboard.enabled) {
        const dashboard_thread = try std.Thread.spawn(
            .{},
            dashboard_server.runAndLog,
            .{ allocator, io, app_config, stop_token },
        );
        // 這裡使用 detach，表示主 thread 不會 join 等 Dashboard thread 結束。
        //
        // 原因：
        // - 主流程由 scheduler.runForever(...) 控制生命週期。
        // - 程式收到 Ctrl+C/SIGTERM 時，stop_token 會讓 scheduler 收尾。
        // - process 結束時，Dashboard thread 也會一起消失。
        dashboard_thread.detach();
    } else {
        std.log.info("dashboard server disabled by config", .{});
    }
    // 真正把控制權交給常駐排程器。
    try scheduler.runForever(allocator, io, app_config, stop_token);
}

/// 把實際生效的設定轉成 JSON 寫進檔案日誌。
///
/// 為了避免密碼與 token 外洩，這裡會先呼叫
/// `config.redactedForLog(...)` 產生已遮罩的副本。
///
/// # Arguments
/// * `allocator` - 用來配置 JSON 字串與訊息文字；兩者都在函式結束前釋放。
/// * `app_config` - 三層來源合併後、實際生效的設定。
///
/// # Errors
/// JSON 序列化或字串配置失敗時回傳錯誤。
///
/// 為什麼值得在啟動時寫一份設定進日誌：設定來自 `app.json`、`.env` 與環境變數三層覆蓋，
/// 「最後到底生效的是哪個值」光看檔案是看不出來的。事後排查時，這一筆日誌能直接回答
/// 「服務當時是用什麼設定在跑」，不必去猜當下的環境變數是什麼。
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
    //
    // `errdefer` 和 `defer` 的差別：`defer` 不論如何都會執行，`errdefer` 只在
    // 「函式以錯誤結束」時執行。這裡兩者並存是因為緩衝區的所有權會在中途轉手：
    // 成功時下面的 `toArrayList()` 會把底層陣列還給 `json_buffer`，由 `defer` 負責釋放；
    // 失敗時陣列還在 writer 手上，就得由 `errdefer` 來收。
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
///
/// `_ = c.signal(...)` 前面的 `_ =` 是在明講「我知道有回傳值，但故意不用」。
/// `signal` 會回傳前一個 handler，這裡不需要它；Zig 不允許默默忽略回傳值，
/// 所以要顯式丟棄。
///
/// `@hasDecl(c, "SIGTERM")` 是編譯期檢查：Windows 沒有 `SIGTERM`，
/// 直接寫死會編不過，用它就能讓同一份程式碼在兩種平台上都成立。
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
///
/// 「async-signal-safe」的意思：signal 可能在程式的**任何**一行中間插進來，包含
/// malloc 或寫檔正在改內部狀態的那一瞬間。如果 handler 這時又去呼叫同一組函式，
/// 就會撞上一個處於半完成狀態的資料結構，造成死鎖或記憶體毀損。因此 handler 裡只做
/// 一件保證安全的事：設定一個 atomic 旗標，剩下的交給主流程在安全的時間點處理。
///
/// # Arguments
/// * `_` - signal 編號。這裡不分辨是哪個 signal，一律當成「請求停止」，
///   所以用 `_` 表示這個參數刻意不使用。
///
/// `callconv(.c)` 表示這個函式要用 C 的呼叫慣例，因為真正呼叫它的是作業系統／C runtime，
/// 不是 Zig 程式碼。
fn handleShutdownSignal(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .monotonic);
}

/// 直接把一行訊息寫到 stderr。
///
/// 這個函式故意忽略寫入失敗，因為它常用在程式準備退出時，
/// 那時候我們只想盡量把錯誤訊息顯示出來。
///
/// # Arguments
/// * `io` - IO 介面。
/// * `text` - 要輸出的文字，函式會自動補一個換行。
///
/// 這裡不透過 `std.log` 是刻意的：這個函式的使用時機包含「logger 初始化失敗」與
/// 「程式即將 `exit`」，那些情境下 logger 可能不可用，或它的緩衝來不及送出。
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
///
/// # Arguments
/// * `io` - IO 介面。
/// * `status` - 要回給 shell 的 exit code（`0` 代表成功，非 0 代表失敗）。
/// * `text` - 顯示給使用者的錯誤訊息。
///
/// 回傳型別 `noreturn` 表示這個函式**不會**回到呼叫端——它一定以 `c.exit(...)` 結束程式。
/// 這個標註不只是註解，編譯器會據此檢查：呼叫它之後的程式碼會被視為不可到達，
/// 呼叫端也因此不需要在它後面再補 `return`。
fn exitWithCliError(io: std.Io, status: c_int, text: []const u8) noreturn {
    writeStderrLine(io, text);
    c.exit(status);
}

/// 把常見錯誤轉成較穩定、較友善的 CLI 錯誤訊息。
///
/// 這樣使用者在終端看到的輸出，不會直接暴露太多內部實作細節。
///
/// # Arguments
/// * `io` - IO 介面。
/// * `err` - 從 [`runCommand`] 一路傳上來的錯誤。
///
/// exit code 的對應（腳本可以據此判斷失敗原因）：
///
/// | 錯誤 | exit code | 意義 |
/// |---|---:|---|
/// | `error.InvalidArguments` | `2` | 使用者輸入的命令列參數不合法 |
/// | `error.NoEnabledDdnsService` | `1` | 設定讀到了，但沒有任何可用的 DDNS provider |
/// | 其他 | `1` | 未預期的失敗，訊息附上 Zig 的 error name |
///
/// 用 `2` 表示「用法錯誤」是 Unix 工具的慣例，和一般執行期失敗的 `1` 區分開。
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
///
/// # Arguments
/// * `init` - Zig 在程式啟動時交給我們的初始化資料，這裡會用到四個東西：
///   - `init.gpa`：一般用途 allocator。
///   - `init.io`：IO 介面。
///   - `init.arena`：整塊釋放的 arena，適合放活到程式結束的設定資料。
///   - `init.minimal.args`：命令列參數。
///
/// # Errors
/// 只有取得命令列參數失敗會直接往外拋；其餘錯誤都在下面被 [`handleMainError`] 收掉，
/// 轉成訊息與 exit code。
pub fn main(init: std.process.Init) !void {
    // `gpa` 是程式啟動時提供的 allocator。
    const allocator = init.gpa;
    // `io` 讓我們能取得 stdin / stdout / stderr 等資源。
    const io = init.io;

    // 先初始化檔案 logger。
    //
    // 這一步失敗不會中止程式：DDNS 更新本身不依賴日誌，
    // 沒辦法寫檔時仍應該讓服務跑起來，只是把失敗原因印到 console。
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
        //
        // 為什麼會有這種情況：Ctrl+C 之後，正在進行的 HTTP 請求或 Redis 操作
        // 會被中斷並回報錯誤。那是「使用者要求停止」的副作用，不是真的故障，
        // 不該讓程式以非 0 的 exit code 結束。
        if (shutdown_requested.load(.monotonic)) {
            std.log.info("service shutdown completed", .{});
            return;
        }
        // 否則轉成 CLI 友善的錯誤輸出。
        handleMainError(io, err);
    };

    // 如果是正常收到 shutdown signal 後離開，
    // 最後再補一筆完成訊息。
    //
    // 這裡和上面的 catch 區塊看起來重複，實際上涵蓋兩條不同的路徑：
    // 上面是「收尾過程中順帶產生了錯誤」，這裡是「scheduler 自己乾淨地跑完收尾才返回」。
    if (shutdown_requested.load(.monotonic)) {
        std.log.info("service shutdown completed", .{});
    }
}
