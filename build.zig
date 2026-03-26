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

    // `strip` 代表要不要把除錯符號和 debug info 從產物裡拿掉。
    // 這會讓 release 版本明顯變小，但除錯資訊也會跟著變少。
    //
    // 這裡提供 `-Dstrip=true/false` 給使用者覆寫。
    // 如果使用者沒特別指定，就採用這個規則：
    // - Debug: 不 strip，方便開發與除錯
    // - 非 Debug: 預設 strip，較接近正式部署版本
    const strip = b.option(bool, "strip", "Strip debug symbols from build artifacts") orelse
        (optimize != .Debug);

    // 讀取 `build.zig.zon` 裡宣告的第三方依賴。
    // 這裡抓的是 vendored 在 `vendor/okredis` 裡的 `zig-okredis`，
    // 之後會把它匯入到主程式與測試模組。
    const okredis_dep = b.dependency("okredis", .{
        .target = target,
        .optimize = optimize,
    });

    // 這裡先建立「主模組」。
    // 你可以把 module 想成：這個可執行檔最上層的原始碼入口與編譯選項集合。
    const exe_module = b.createModule(.{
        // `root_source_file` 指定這個模組從哪支 Zig 檔開始。
        // 也就是說，整個程式的入口是 `src/main.zig`。
        .root_source_file = b.path("src/main.zig"),
        // 把剛剛決定好的目標平台套進來。
        .target = target,
        // 把剛剛決定好的最佳化等級套進來。
        .optimize = optimize,
        // 讓 executable 的 root module 依照上面的 strip 設定決定
        // 要不要保留 debug info。
        .strip = strip,
        // 這個專案有用到 `@cImport` 與 libc 時間函式，
        // 所以這裡要明確要求連結 libc。
        .link_libc = true,
    });
    // 把第三方的 `okredis` 模組掛到主模組裡。
    // 之後在原始碼裡就能直接寫 `@import("okredis")`。
    exe_module.addImport("okredis", okredis_dep.module("okredis"));

    // 這裡才是把剛剛的 module 變成真正的 executable。
    const exe = b.addExecutable(.{
        // `.name` 決定最後產出的執行檔名稱。
        .name = "dynip",
        // `.root_module` 告訴 Zig：「這個執行檔要用哪個 module 當主體」。
        .root_module = exe_module,
    });

    // `installArtifact` 代表：
    // 當你執行 `zig build` 時，除了編出來，還要把產物安裝到 Zig 預設輸出位置。
    // 一般來說會在 `zig-out/` 下面看到結果。
    b.installArtifact(exe);

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
        // 如果完全沒帶參數，這個專案想要的預設行為是直接啟動 service。
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

    // 測試也需要一個自己的 root module。
    // 因為這個專案的測試散在多個檔案內，所以用 `src/tests.zig`
    // 當作「測試總入口」，在裡面把所有有 test 的模組都 import 進來。
    const test_module = b.createModule(.{
        // 測試入口改成 `src/tests.zig`。
        .root_source_file = b.path("src/tests.zig"),
        // 測試也要知道目標平台。
        .target = target,
        // 測試也要知道最佳化等級。
        .optimize = optimize,
        // 測試 module 也沿用同一個 strip 規則。
        .strip = strip,
        // 測試裡一樣會碰到 libc 相關程式碼，所以也連結 libc。
        .link_libc = true,
    });
    // 測試模組也需要能匯入 `okredis`。
    test_module.addImport("okredis", okredis_dep.module("okredis"));

    // `addTest` 代表建立「編譯測試」這件事。
    // 注意：這時還只是建立測試 artifact，還沒真的跑。
    const unit_tests = b.addTest(.{
        // 告訴 Zig：「測試要從哪個 root module 開始」。
        .root_module = test_module,
    });

    // 有了測試 artifact 之後，再建立「執行測試」的命令。
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // 建立名字叫 `test` 的 build step。
    // 所以你才能在命令列輸入 `zig build test`。
    const test_step = b.step("test", "Run Zig unit tests");
    // 指定 `test` 這個 step 的真正內容，就是執行剛剛建立的測試命令。
    test_step.dependOn(&run_unit_tests.step);
}
