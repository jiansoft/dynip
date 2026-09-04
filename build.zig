//! 專案建置腳本，定義 DDNS CLI 與單元測試。

/// 匯入 Zig 標準函式庫。
///
/// `std` 幾乎是每個 Zig 檔案最常見的第一個 import，
/// 裡面放了建置、字串、檔案、網路、測試等通用工具。
const std = @import("std");

/// 配置 `dynip` 可執行檔與 `zig build test` 所需的測試步驟。
pub fn build(b: *std.Build) void {
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

    // `strip` 代表要不要把除錯符號和除錯資訊從產物裡拿掉。
    // 這會讓釋出版明顯變小，但除錯資訊也會跟著變少。
    //
    // 這裡提供 `-Dstrip=true/false` 給使用者覆寫。
    // 如果使用者沒特別指定，就採用這個規則：
    // - Debug: 不 strip，方便開發與除錯
    // - 非 Debug: 預設 strip，較接近正式部署時的版本
    const strip = b.option(bool, "strip", "Strip debug symbols from build artifacts") orelse
        (optimize != .debug);

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
    //
    // `.use_pkg_config = .no` 是必要的：ws2_32 由 mingw 直接提供，不需要 pkg-config。
    // 若放任 Zig 去探測，它會執行 `pkg-config --list-all`；在 Windows 上這常被解析成
    // Perl 的 .BAT shim，導致 build 直接失敗（且錯誤訊息與本專案完全無關）。
    if (target.result.os.tag == .windows) {
        exe_module.linkSystemLibrary("ws2_32", .{ .use_pkg_config = .no });
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
    b.installArtifact(exe);

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
    debug_step.dependOn(&install_debug_exe.step);

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
    run_step.dependOn(&run_cmd.step);

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
        test_module.linkSystemLibrary("ws2_32", .{ .use_pkg_config = .no });
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
    test_step.dependOn(&run_unit_tests.step);
}
