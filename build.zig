//! 專案建置腳本，定義 DDNS CLI 與單元測試。

/// 匯入 Zig 標準函式庫。
///
/// `std` 幾乎是每個 Zig 檔案最常見的第一個 import，
/// 裡面放了建置、字串、檔案、網路、測試等通用工具。
const std = @import("std");
/// 匯入編譯器提供的「目前 build runner 所在平台」資訊。
///
/// 這裡不是拿來判斷 dynip 最後要跑在哪個 target，
/// 而是判斷「現在執行 build.zig 的這台機器」是不是 Windows。
/// 例如使用者在 Windows 上 cross-compile Linux binary 時：
/// - `builtin.os.tag` 仍然是 `.windows`
/// - `target.result.os.tag` 才是最後產物的目標 OS
const builtin = @import("builtin");

/// 配置 `dynip` 可執行檔與 `zig build test` 所需的測試步驟。
pub fn build(b: *std.Build) void {
    normalizeWindowsBuildLocale(b);

    // `b` 是 Zig 建置系統傳進來的 build 物件。
    // 幾乎所有建置設定，都是透過這個物件一步一步加上去。

    // `target` 代表這次要編譯給哪個作業系統 / CPU 架構。
    // 例如你可以是：
    // - Windows x86_64
    // - Linux aarch64
    // - macOS arm64
    //
    // 這一行呼叫標準工具，讓使用者可以用 `-Dtarget=...` 覆寫目標平台。
    const target = b.standardTargetOptions(.{});

    // `optimize` 代表最佳化等級。
    // 常見值像：
    // - Debug: 最適合除錯
    // - ReleaseSafe: 兼顧速度與安全檢查
    // - ReleaseFast: 追求速度
    //
    // 這一行同樣會讓使用者可以用 `-Doptimize=...` 來覆寫。
    const optimize = b.standardOptimizeOption(.{});
    // 這是 build.zig 內部使用的旗標，不是給一般使用者手動操作的功能。
    //
    // 為什麼需要它：
    // - Windows 上某些 Zig 0.17-dev 編譯子程序會啟動 Perl / libc 偵測。
    // - 如果外部 shell 帶著 `LC_ALL=C.UTF-8`，Windows Perl 不認得這個 locale。
    // - Perl 退回 CP950 後，Zig 又會拒絕 `Chinese (Traditional)_Taiwan.950`。
    //
    // 所以外層 `zig build run/test` 會用乾淨的 `LC_ALL=C` 重新呼叫一次自己。
    // 重新呼叫時帶上 `-Dlocale-normalized=true`，讓內層 build 知道：
    // 「我已經在安全 locale 裡了，不要再重新啟動一次」，避免無限遞迴。
    const locale_normalized = b.option(
        bool,
        "locale-normalized",
        "Internal: build was restarted with a Windows-safe locale",
    ) orelse false;
    const needs_locale_restart = builtin.os.tag == .windows and !locale_normalized;

    // `strip` 代表要不要把除錯符號和除錯資訊從產物裡拿掉。
    // 這會讓釋出版明顯變小，但除錯資訊也會跟著變少。
    //
    // 這裡提供 `-Dstrip=true/false` 給使用者覆寫。
    // 如果使用者沒特別指定，就採用這個規則：
    // - Debug: 不 strip，方便開發與除錯
    // - 非 Debug: 預設 strip，較接近正式部署時的版本
    const strip = b.option(bool, "strip", "Strip debug symbols from build artifacts") orelse
        (optimize != .Debug);

    // 讀取 `build.zig.zon` 裡宣告的第三方依賴。
    // 這裡抓的是放在 `vendor/okredis` 裡的 `zig-okredis`，
    // 之後會把它匯入到主程式與測試模組。
    const okredis_dep = b.dependency("okredis", .{
        .target = target,
        .optimize = optimize,
    });

    // 只提供專案實際用到的少量 C / platform declarations。
    // 避免 `translate-c` 在 Windows CP950 locale 下透過 Perl 初始化時失敗。
    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // 建立可執行檔要使用的根模組。
    //
    // 在 Zig 的 build system 裡，
    // `createModule(...)` 可以理解成：
    // 「先把某份原始碼入口、編譯選項與匯入依賴包成一個模組設定」。
    //
    // 之後這個模組可以拿去：
    // - 建 executable
    // - 建 library
    // - 建 test 產物
    //
    // 這裡的 executable 入口刻意保持很薄，只指向 `src/main.zig`。
    const exe_module = b.createModule(.{
        // 這個模組從哪支 Zig 檔開始編譯。
        .root_source_file = b.path("src/main.zig"),
        // 編譯目標平台。
        .target = target,
        // 最佳化等級。
        .optimize = optimize,
        // 是否移除除錯符號。
        .strip = strip,
        // 這個專案和 Zig 目前的 Windows socket/env path 都需要 libc。
        .link_libc = true,
    });
    // 把第三方 `okredis` 模組掛到這個根模組上。
    // 之後主程式裡就能直接寫 `@import("okredis")`。
    exe_module.addImport("okredis", okredis_dep.module("okredis"));
    // 掛載剛剛產生的 C 模組。之後程式裡寫 `@import("c")` 就拿得到 C 的 symbol。
    exe_module.addImport("c", c_mod);

    // 如果目標平台是 Windows，必須額外連結 Windows 的 Winsock 函式庫 (ws2_32)。
    if (target.result.os.tag == .windows) {
        exe_module.linkSystemLibrary("ws2_32", .{});
    }

    // 這裡才是把剛剛的模組變成真正的可執行檔。
    const exe = b.addExecutable(.{
        // `.name` 決定最後產出的執行檔名稱。
        .name = "dynip",
        // `.root_module` 告訴 Zig：「這個執行檔要用哪個模組當主體」。
        .root_module = exe_module,
    });

    // `installArtifact` 代表：
    // 當你執行 `zig build` 時，除了編出來，還要把產物安裝到 Zig 預設輸出位置。
    // 一般來說會在 `zig-out/` 下面看到結果。
    //
    // Windows 外層 build 不直接依賴 compile/install artifact。
    // 原因和 `run` / `test` 一樣：真正 compile 前可能先碰到不支援的 locale。
    // 所以外層 `zig build` 只負責用 `LC_ALL=C` 呼叫內層 `zig build install`。
    if (needs_locale_restart) {
        const normalized_install = addLocaleNormalizedBuildCommand(b, "install");
        b.getInstallStep().dependOn(&normalized_install.step);
    } else {
        b.installArtifact(exe);
    }

    // 額外建立一個只負責「把可執行檔裝到 zig-out/bin」的 install step。
    //
    // 這對一般 `zig build` 來說不一定必要，
    // 但對某些 IDE / debugger 整合很有幫助，
    // 因為它們會需要：
    // - 一個明確的 build step 名稱
    // - 一個固定、可預測的 executable 路徑
    const install_debug_exe = b.addInstallArtifact(exe, .{
        .dest_sub_path = exe.out_filename,
    });

    // 提供給 IDE 使用的 debug build step。
    //
    // 這個 step 不會真的執行程式，
    // 它只保證 `zig-out/bin/dynip` 這支檔案已經建好。
    const debug_step = b.step("debug", "Build dynip executable for IDE debugging");
    if (needs_locale_restart) {
        const normalized_debug = addLocaleNormalizedBuildCommand(b, "debug");
        debug_step.dependOn(&normalized_debug.step);
    } else {
        debug_step.dependOn(&install_debug_exe.step);
    }

    // `addRunArtifact` 會建立一個「執行這支程式」的 build step。
    // 之後 `zig build run` 就是靠這個物件運作。
    const run_cmd = b.addRunArtifact(exe);

    // 轉送使用者在 `zig build run --` 後面帶進來的參數。
    // 例如：
    //
    // zig build run -- service --config app.json
    //
    // 這時 `service --config app.json` 會原封不動轉給程式本身。
    //
    // Zig 0.17-dev 的 build API 正在變動：
    // - 較舊 snapshot 還有 `Build.args`
    // - 較新 snapshot 移除 `Build.args`，改用 `Run.addPassthruArgs`
    //
    // `comptime @hasField(...)` 和 `comptime @hasDecl(...)` 是編譯期檢查：
    // - `@hasField(std.Build, "args")`：檢查這版標準庫的 Build struct 是否還有 args 欄位
    // - `@hasDecl(std.Build.Step.Run, "addPassthruArgs")`：檢查 Run step 是否有這個函式
    //
    // 這樣同一份 build script 可以跨幾個 Zig 0.17-dev snapshot 編譯。
    if (comptime @hasField(std.Build, "args")) {
        // 舊 API：build system 會在 configure 階段把 `--` 後面的參數放進 b.args。
        if (b.args) |args| {
            // 使用者有明確帶參數時，全部轉送給 dynip。
            run_cmd.addArgs(args);
        } else {
            // 使用者只輸入 `zig build run` 時，預設啟動 service。
            run_cmd.addArg("service");
        }
    } else if (comptime @hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        // 新 API：build script 不再直接讀得到「是否有 passthrough args」。
        // 這裡只宣告 run step 願意接收 `zig build run -- ...` 的參數。
        //
        // 因為這個 API 無法在 build.zig 裡判斷「沒帶參數時補 service」，
        // 空參數預設值改放在 CLI 層處理，見 `src/cli.zig` 的
        // `commandArgsOrDefault(...)`。
        run_cmd.addPassthruArgs();
    } else {
        // 更舊或不同的 API 沒有 passthrough 支援時，至少讓 `zig build run`
        // 仍然能用預設 service 啟動。
        run_cmd.addArg("service");
    }

    // 建立一個名字叫 `run` 的 build step。
    // 使用者在命令列輸入 `zig build run` 時，找的就是這個名字。
    const run_step = b.step("run", "Run the DDNS service");
    // `dependOn` 的意思是：
    // 這個 `run` step 真正要做的事情，依賴 `run_cmd.step`。
    // 也就是先建出程式，再執行它。
    if (needs_locale_restart) {
        const normalized_run = addLocaleNormalizedBuildCommand(b, "run");
        run_step.dependOn(&normalized_run.step);
    } else {
        run_step.dependOn(&run_cmd.step);
    }

    // 測試這裡改成直接掛在 `src/root.zig`。
    //
    // 好處是：
    // - 不用再維護額外的 `src/tests.zig`
    // - `root.zig` 既能當共用模組入口，也能當測試匯總入口
    // - 專案 layout 會更接近常見的 Zig 風格
    const test_module = b.createModule(.{
        // 測試從 `src/root.zig` 開始。
        .root_source_file = b.path("src/root.zig"),
        // 測試也要知道目標平台。
        .target = target,
        // 測試也沿用同一組最佳化等級。
        .optimize = optimize,
        // 測試產物也套用同樣的 strip 規則。
        .strip = strip,
        // 測試裡一樣會碰到 C API，所以也連結 libc。
        .link_libc = true,
    });
    // 測試模組同樣需要能匯入 `okredis`。
    test_module.addImport("okredis", okredis_dep.module("okredis"));
    // 測試模組同樣需要 C 模組。
    test_module.addImport("c", c_mod);

    // 測試模組也需要在 Windows 上連結 ws2_32。
    if (target.result.os.tag == .windows) {
        test_module.linkSystemLibrary("ws2_32", .{});
    }

    // `addTest` 代表建立「編譯測試」這件事。
    // 注意：這時還只是建立測試產物，還沒真的執行。
    const unit_tests = b.addTest(.{
        // 告訴 Zig：「測試要從哪個根模組開始」。
        .root_module = test_module,
    });

    // 有了測試產物之後，再建立「執行測試」的命令。
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // 為了讓 IDE 也能 debug `zig build test` 類型的工作，
    // 另外把測試產物安裝成一支固定名稱的可執行檔。
    //
    // 這樣像 ZigBrains 這類需要「build step + output executable path」
    // 的 IDE，就能明確知道要附加到哪個測試 binary。
    const debug_test_filename = b.fmt(
        "dynip-tests{s}",
        .{std.fs.path.extension(unit_tests.out_filename)},
    );
    const install_debug_tests = b.addInstallArtifact(unit_tests, .{
        .dest_sub_path = debug_test_filename,
    });

    // 提供給 IDE 使用的測試 debug build step。
    //
    // 這個 step 只會建出測試執行檔，不會直接跑測試。
    const debug_test_step = b.step("debug-test", "Build unit test executable for IDE debugging");
    debug_test_step.dependOn(&install_debug_tests.step);

    // 建立名字叫 `test` 的 build step。
    // 所以你才能在命令列輸入 `zig build test`。
    const test_step = b.step("test", "Run Zig unit tests");
    // 指定 `test` 這個 step 的真正內容，就是執行剛剛建立的測試命令。
    if (needs_locale_restart) {
        // `test` 和 `run` 遇到的是同一個 Windows locale 問題：
        // 真正的 Zig compile step 還沒開始前，就可能因外部 locale 失敗。
        // 所以測試也先用安全 locale 重新呼叫一次自己。
        const normalized_test = addLocaleNormalizedBuildCommand(b, "test");
        test_step.dependOn(&normalized_test.step);
    } else {
        test_step.dependOn(&run_unit_tests.step);
    }
}

fn addLocaleNormalizedBuildCommand(b: *std.Build, step_name: []const u8) *std.Build.Step.Run {
    // Windows 外層 build 只做一件事：
    // 用同一支 Zig executable 重新執行 `zig build <step>`，
    // 並且把 locale 改成 Windows Perl 能接受的 `C`。
    //
    // 這裡用 `addSystemCommand`，因為我們不是要執行 dynip，
    // 而是要執行另一個系統程式：Zig 自己。
    //
    // 內層 build 會收到 `-Dlocale-normalized=true`，
    // 因此不會再次呼叫這個 wrapper，而會真正依賴 compile/install/run/test step。
    const normalized = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "-Dlocale-normalized=true",
        step_name,
    });

    // 明確把工作目錄設成專案根目錄，避免使用者從其他路徑呼叫 build 時，
    // 內層 `zig build <step>` 找錯 `build.zig` 或相對路徑設定檔。
    normalized.setCwd(b.path("."));

    // 同時設定三個常見 locale 變數。
    //
    // `LC_ALL` 優先權最高；`LC_CTYPE` 影響字元分類/編碼；
    // `LANG` 是很多工具最後 fallback 會看的變數。
    // 三個都設成 `C`，可以讓 Perl / libc 工具使用最保守的 ASCII locale。
    normalized.setEnvironmentVariable("LC_ALL", "C");
    normalized.setEnvironmentVariable("LC_CTYPE", "C");
    normalized.setEnvironmentVariable("LANG", "C");

    return normalized;
}

fn normalizeWindowsBuildLocale(b: *std.Build) void {
    if (comptime builtin.os.tag != .windows) return;

    // 這個函式在 build.zig configure 階段一開始就執行。
    //
    // 為什麼同時寫兩個地方：
    // 1. `b.graph.environ_map`
    //    這是 Zig build system 傳給後續 Run step 的環境快照。
    //    例如 `addSystemCommand` 建出來的 step 會從這份 map clone 環境。
    // 2. `SetEnvironmentVariableA`
    //    這會修改目前 build runner process 的真實 Windows 環境。
    //    某些 Zig 內部工具不是從 `Run` step 啟動，而是直接由目前 process
    //    spawn child process；這種情況需要 OS process env 也被修正。
    //
    // 注意：這不能完全取代 run/test 的自我重啟 wrapper。
    // 因為有些 compile server / maker 階段在這份 build.zig 之前就已經讀過
    // 外部環境；自我重啟才是最穩定的保險。
    b.graph.environ_map.put("LC_ALL", "C") catch @panic("OOM");
    b.graph.environ_map.put("LC_CTYPE", "C") catch @panic("OOM");
    b.graph.environ_map.put("LANG", "C") catch @panic("OOM");

    _ = kernel32.SetEnvironmentVariableA("LC_ALL", "C");
    _ = kernel32.SetEnvironmentVariableA("LC_CTYPE", "C");
    _ = kernel32.SetEnvironmentVariableA("LANG", "C");
}

const kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn SetEnvironmentVariableA(
        lpName: [*:0]const u8,
        lpValue: ?[*:0]const u8,
    ) callconv(.winapi) c_int;
} else struct {};
