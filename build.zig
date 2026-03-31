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
        (optimize != .Debug);

    // 讀取 `build.zig.zon` 裡宣告的第三方依賴。
    // 這裡抓的是放在 `vendor/okredis` 裡的 `zig-okredis`，
    // 之後會把它匯入到主程式與測試模組。
    const okredis_dep = b.dependency("okredis", .{
        .target = target,
        .optimize = optimize,
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
        // 這個專案有用到 `@cImport`，所以要明確連結 libc。
        .link_libc = true,
    });
    // 把第三方 `okredis` 模組掛到這個根模組上。
    // 之後主程式裡就能直接寫 `@import("okredis")`。
    exe_module.addImport("okredis", okredis_dep.module("okredis"));

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

    // `b.args` 代表使用者在 `zig build run --` 後面帶進來的參數。
    // 例如：
    //
    // zig build run -- service --config app.json
    //
    // 這時 `service --config app.json` 就會出現在 `b.args` 裡。
    if (b.args) |args| {
        // 如果真的有帶參數，就把這些參數原封不動轉給程式本身。
        run_cmd.addArgs(args);
    } else {
        // 如果完全沒帶參數，這個專案想要的預設行為是直接啟動服務。
        // 所以自動幫使用者補上一個 `"service"`。
        //
        // 這樣你在 IDE 直接按 Run，或在終端直接打 `zig build run`，
        // 就會直接進入常駐服務，而不需要每次自己手打子命令。
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
        // 測試裡一樣會碰到 `@cImport`，所以也連結 libc。
        .link_libc = true,
    });
    // 測試模組同樣需要能匯入 `okredis`。
    test_module.addImport("okredis", okredis_dep.module("okredis"));

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
