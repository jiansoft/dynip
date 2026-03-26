//! 全域設定模組。
//!
//! 這裡是 Zig 專案集中管理設定的地方。
//! 目前先實作 DDNS 相關欄位，但之後像資料庫、API、bot、排程等全域設定，
//! 也都應該持續加在這個檔案，而不是再分散到別的 `*_config.zig`。

/// 匯入 Zig 標準函式庫。
///
/// 這個檔案會用到字串處理、JSON、檔案讀取、環境變數與 allocator，
/// 這些都放在 `std` 裡。
const std = @import("std");

/// 預設的設定檔路徑，沿用 Rust 版專案的檔名。
pub const default_config_path = "app.json";

/// 預設的 `.env` 路徑。
pub const default_dotenv_path = ".env";

/// 目前 Zig 專案的總設定根節點。
///
/// 目前先保留 DDNS 這次移植真正需要的欄位。
/// 讀取 Rust 版 `app.json` 時，其他尚未移植的欄位會直接忽略。
pub const AppConfig = struct {
    /// Afraid.org 相關設定。
    afraid: Afraid = .{},
    /// Dynu 相關設定。
    dyny: Dynu = .{},
    /// No-IP 相關設定。
    noip: NoIp = .{},
    /// DDNS service 自己的執行設定。
    ddns: Ddns = .{},
};

/// Afraid.org DDNS 設定。
pub const Afraid = struct {
    /// 是否啟用 Afraid 更新。
    ///
    /// 設成 `false` 時，就算 IP 真的改變，
    /// 這輪 refresh 也不會去打 Afraid API。
    enabled: bool = true,
    /// Afraid API 的基底網址。
    url: []const u8 = "https://freedns.afraid.org",
    /// Afraid API 的路徑前綴。
    path: []const u8 = "/dynamic/update.php?",
    /// Afraid 更新 token。
    token: []const u8 = "",
};

/// Dynu DDNS 設定。
pub const Dynu = struct {
    /// 是否啟用 Dynu 更新。
    enabled: bool = true,
    /// Dynu API 的基底網址。
    url: []const u8 = "https://api.dynu.com/nic/update",
    /// Dynu 使用者名稱。
    username: []const u8 = "",
    /// Dynu 密碼。
    password: []const u8 = "",
};

/// No-IP DDNS 設定。
pub const NoIp = struct {
    /// 是否啟用 No-IP 更新。
    enabled: bool = true,
    /// No-IP API 的基底網址。
    url: []const u8 = "https://dynupdate.no-ip.com/nic/update",
    /// No-IP 使用者名稱。
    username: []const u8 = "",
    /// No-IP 密碼。
    password: []const u8 = "",
    /// 要更新的主機名稱列表。
    hostnames: []const []const u8 = &.{},
};

/// Redis 去重設定。
///
/// Zig 版現在改成真的連 Redis，不再用本地 `.ddns_state.json` 模擬。
pub const Redis = struct {
    /// 是否啟用 Redis 去重。
    ///
    /// 設成 `false` 時，DDNS 會退回成本機記憶體去重。
    enabled: bool = true,
    /// Redis 位址，格式通常是 `host:port`。
    addr: []const u8 = "localhost:6379",
    /// Redis ACL 帳號。未使用 ACL 時可留空。
    account: []const u8 = "",
    /// Redis 密碼。
    password: []const u8 = "",
    /// 要使用的 Redis DB index。
    db: u32 = 0,
};

/// Zig 版額外補的 DDNS 執行設定。
pub const Ddns = struct {
    /// 每輪 refresh 之間要等幾秒。
    refresh_interval_seconds: u64 = 60,
    /// Redis 去重 key 的 TTL 秒數。
    dedupe_ttl_seconds: u64 = 60 * 60 * 24,
    /// Redis 連線設定。
    redis: Redis = .{},
};

/// 從 `app.json` 讀取設定，並套用環境變數覆寫。
///
/// 傳回的字串與陣列資料都配置在呼叫端提供的 `allocator` 上，
/// 適合用 `ArenaAllocator` 持有整個程式生命週期。
pub fn loadLeaky(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !AppConfig {
    // 先建立一份帶預設值的設定。
    var config = AppConfig{};

    // 嘗試讀取 `app.json`。
    // 這裡用 `readFileAlloc` 直接把整份檔案讀成字串。
    const config_text = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    // 如果設定檔存在，就先用 JSON 把它解析成 struct。
    if (config_text) |text| {
        config = try parseJsonLeaky(allocator, text);
    }

    // 然後套用 `.env` 裡的值。
    try applyDotEnvFileOverridesLeaky(allocator, io, &config, default_dotenv_path);
    // 最後再用目前 process 的環境變數覆蓋一次。
    // 這樣環境變數的優先權最高。
    try applyProcessEnvOverridesLeaky(allocator, &config);
    // 回傳最後生效的設定。
    return config;
}

/// 將 JSON 文字解析成設定結構。
///
/// Zig 有內建 JSON 標準庫，所以這裡不用額外裝第三方套件。
/// 目前用的是 `std.json.parseFromSliceLeaky(...)`，意思可以拆成：
///
/// - `parse`
///   把文字解析成 Zig struct。
/// - `FromSlice`
///   輸入資料型別是 `[]const u8` 這種字串 slice。
/// - `Leaky`
///   解析過程配置的記憶體不會個別手動釋放，
///   而是交給外面的 allocator 一次回收。
///
/// 這個專案很適合用 `Leaky`，因為設定通常只在啟動時載入一次，
/// 然後整個 service 生命週期都會一直使用它。
///
/// 如果你改用 `std.json.parseFromSlice(...)`，
/// 它會回傳一個需要 `deinit()` 的包裝物件，比較適合短生命週期資料。
fn parseJsonLeaky(allocator: std.mem.Allocator, text: []const u8) !AppConfig {
    return std.json.parseFromSliceLeaky(AppConfig, allocator, text, .{
        .ignore_unknown_fields = true,
    });
}

/// 套用 `.env` 檔中的覆寫值。
fn applyDotEnvFileOverridesLeaky(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *AppConfig,
    path: []const u8,
) !void {
    // 先把整個 `.env` 檔一次讀進記憶體。
    // 這和前面讀 `app.json` 的做法很像，只是這次讀的是純文字設定檔。
    const dotenv_text = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(256 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    // 如果專案根目錄沒有 `.env`，就直接略過，不當成錯誤。
    const text = dotenv_text orelse return;

    // 真正逐行解析 `.env` 的工作，交給下一層函式。
    try applyDotEnvTextOverridesLeaky(allocator, config, text);
}

/// 逐行解析 `.env` 內容。
fn applyDotEnvTextOverridesLeaky(
    allocator: std.mem.Allocator,
    config: *AppConfig,
    text: []const u8,
) !void {
    // `tokenizeScalar(..., '\n')` 會按照換行把整段文字切成一行一行。
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        // 先把每行前後常見空白去掉，包含 Windows 常見的 `\r`。
        var line = std.mem.trim(u8, raw_line, " \t\r");

        // 空行或 `#` 開頭的註解行直接跳過。
        if (line.len == 0 or line[0] == '#') continue;

        // 有些 `.env` 會寫成 `export KEY=value`，
        // 所以如果看到 `export ` 前綴，就先拿掉再處理。
        if (std.mem.startsWith(u8, line, "export ")) {
            line = std.mem.trim(u8, line["export ".len..], " \t");
        }

        // `.env` 的核心格式就是 `KEY=value`，
        // 所以先找第一個 `=` 的位置。
        const equal_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;

        // `=` 左邊是 key，例如 `AFRAID_TOKEN`。
        const key = std.mem.trim(u8, line[0..equal_index], " \t");
        if (key.len == 0) continue;

        // `=` 右邊是 value，例如 token、帳密或 JSON 陣列字串。
        const raw_value = std.mem.trim(u8, line[equal_index + 1 ..], " \t");

        // 如果 value 外面包了單引號或雙引號，這裡先拆掉。
        const value = unquoteDotEnvValue(raw_value);

        // 最後把 `key=value` 寫進真正的 `AppConfig`。
        try applyOverrideValueLeaky(allocator, config, key, value);
    }
}

/// 移除 `.env` 常見的單引號或雙引號包裝。
fn unquoteDotEnvValue(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];

        // 例如 `"abc"` 會變成 `abc`，
        // `'abc'` 也會變成 `abc`。
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return value[1 .. value.len - 1];
        }
    }

    // 如果本來就沒引號，就原樣回傳。
    return value;
}

/// 套用目前 process 的環境變數覆寫。
fn applyProcessEnvOverridesLeaky(allocator: std.mem.Allocator, config: *AppConfig) !void {
    // 這一層是讀作業系統真的存在的環境變數，
    // 例如你在 shell 裡先 `export AFRAID_TOKEN=...` 那種。
    // 優先權比 `.env` 更高，因為它會最後套用。

    // 下面每一行都採用同一個模式：
    // 1. 先用 `getEnv("某個名稱")` 看環境變數有沒有存在
    // 2. 如果有，就把那個值交給 `applyOverrideValueLeaky(...)`
    // 3. 由後者決定要寫進 `AppConfig` 的哪個欄位
    if (getEnv("AFRAID_URL")) |value| {
        try applyOverrideValueLeaky(allocator, config, "AFRAID_URL", value);
    }
    if (getEnv("AFRAID_ENABLED")) |value| {
        try applyOverrideValueLeaky(allocator, config, "AFRAID_ENABLED", value);
    }
    if (getEnv("AFRAID_PATH")) |value| {
        try applyOverrideValueLeaky(allocator, config, "AFRAID_PATH", value);
    }
    if (getEnv("AFRAID_TOKEN")) |value| {
        try applyOverrideValueLeaky(allocator, config, "AFRAID_TOKEN", value);
    }

    if (getEnv("DYNU_ENABLED")) |value| {
        try applyOverrideValueLeaky(allocator, config, "DYNU_ENABLED", value);
    }
    if (getEnv("DYNU_URL")) |value| {
        try applyOverrideValueLeaky(allocator, config, "DYNU_URL", value);
    }
    if (getEnv("DYNU_USERNAME")) |value| {
        try applyOverrideValueLeaky(allocator, config, "DYNU_USERNAME", value);
    }
    if (getEnv("DYNU_PASSWORD")) |value| {
        try applyOverrideValueLeaky(allocator, config, "DYNU_PASSWORD", value);
    }

    if (getEnv("NOIP_ENABLED")) |value| {
        try applyOverrideValueLeaky(allocator, config, "NOIP_ENABLED", value);
    }
    if (getEnv("NOIP_URL")) |value| {
        try applyOverrideValueLeaky(allocator, config, "NOIP_URL", value);
    }
    if (getEnv("NOIP_USERNAME")) |value| {
        try applyOverrideValueLeaky(allocator, config, "NOIP_USERNAME", value);
    }
    if (getEnv("NOIP_PASSWORD")) |value| {
        try applyOverrideValueLeaky(allocator, config, "NOIP_PASSWORD", value);
    }
    if (getEnv("NOIP_HOSTNAMES")) |value| {
        try applyOverrideValueLeaky(allocator, config, "NOIP_HOSTNAMES", value);
    }

    if (getEnv("REDIS_ADDR")) |value| {
        try applyOverrideValueLeaky(allocator, config, "REDIS_ADDR", value);
    }
    if (getEnv("REDIS_ENABLED")) |value| {
        try applyOverrideValueLeaky(allocator, config, "REDIS_ENABLED", value);
    }
    if (getEnv("REDIS_ACCOUNT")) |value| {
        try applyOverrideValueLeaky(allocator, config, "REDIS_ACCOUNT", value);
    }
    if (getEnv("REDIS_PASSWORD")) |value| {
        try applyOverrideValueLeaky(allocator, config, "REDIS_PASSWORD", value);
    }
    if (getEnv("REDIS_DB")) |value| {
        try applyOverrideValueLeaky(allocator, config, "REDIS_DB", value);
    }
    if (getEnv("DDNS_DEDUPE_TTL_SECONDS")) |value| {
        try applyOverrideValueLeaky(allocator, config, "DDNS_DEDUPE_TTL_SECONDS", value);
    }
    if (getEnv("DDNS_REFRESH_INTERVAL_SECONDS")) |value| {
        try applyOverrideValueLeaky(allocator, config, "DDNS_REFRESH_INTERVAL_SECONDS", value);
    }
}

/// 依 key 把覆寫值寫進設定結構。
fn applyOverrideValueLeaky(
    allocator: std.mem.Allocator,
    config: *AppConfig,
    key: []const u8,
    value: []const u8,
) !void {
    // 這裡像是一個「key 對應表」：
    // 看 `.env` 或系統環境變數提供的是哪個 key，
    // 再決定要寫到 `AppConfig` 的哪個欄位。
    if (std.mem.eql(u8, key, "AFRAID_URL")) {
        // 這裡代表：把 `AFRAID_URL` 寫進 `config.afraid.url`。
        config.afraid.url = value;
        return;
    }

    if (std.mem.eql(u8, key, "AFRAID_ENABLED")) {
        // `AFRAID_ENABLED` 用來控制是否真的更新 Afraid。
        config.afraid.enabled = parseBoolOrKeep(value, config.afraid.enabled);
        return;
    }

    if (std.mem.eql(u8, key, "AFRAID_PATH")) {
        // 這裡代表：把 `AFRAID_PATH` 寫進 `config.afraid.path`。
        config.afraid.path = value;
        return;
    }

    if (std.mem.eql(u8, key, "AFRAID_TOKEN")) {
        // 這裡代表：把 `AFRAID_TOKEN` 寫進 `config.afraid.token`。
        config.afraid.token = value;
        return;
    }

    if (std.mem.eql(u8, key, "DYNU_ENABLED")) {
        // `DYNU_ENABLED` 用來控制是否真的更新 Dynu。
        config.dyny.enabled = parseBoolOrKeep(value, config.dyny.enabled);
        return;
    }

    if (std.mem.eql(u8, key, "DYNU_URL")) {
        // Dynu API base URL。
        config.dyny.url = value;
        return;
    }

    if (std.mem.eql(u8, key, "DYNU_USERNAME")) {
        // Dynu 使用者名稱。
        config.dyny.username = value;
        return;
    }

    if (std.mem.eql(u8, key, "DYNU_PASSWORD")) {
        // Dynu 密碼。
        config.dyny.password = value;
        return;
    }

    if (std.mem.eql(u8, key, "NOIP_ENABLED")) {
        // `NOIP_ENABLED` 用來控制是否真的更新 No-IP。
        config.noip.enabled = parseBoolOrKeep(value, config.noip.enabled);
        return;
    }

    if (std.mem.eql(u8, key, "NOIP_URL")) {
        // No-IP API base URL。
        config.noip.url = value;
        return;
    }

    if (std.mem.eql(u8, key, "NOIP_USERNAME")) {
        // No-IP 使用者名稱。
        config.noip.username = value;
        return;
    }

    if (std.mem.eql(u8, key, "NOIP_PASSWORD")) {
        // No-IP 密碼。
        config.noip.password = value;
        return;
    }

    if (std.mem.eql(u8, key, "NOIP_HOSTNAMES")) {
        // `NOIP_HOSTNAMES` 不是單純字串，而是 JSON 陣列字串，
        // 例如 `["a.ddns.net","b.zapto.org"]`。
        // 所以這裡再次用 `std.json` 把它解析成 Zig 的字串陣列。
        config.noip.hostnames = try std.json.parseFromSliceLeaky([][]const u8, allocator, value, .{});
        return;
    }

    if (std.mem.eql(u8, key, "REDIS_ADDR")) {
        // Redis 位址，例如 `127.0.0.1:6379`。
        config.ddns.redis.addr = value;
        return;
    }

    if (std.mem.eql(u8, key, "REDIS_ENABLED")) {
        // `REDIS_ENABLED` 用來控制是否使用 Redis 去重。
        config.ddns.redis.enabled = parseBoolOrKeep(value, config.ddns.redis.enabled);
        return;
    }

    if (std.mem.eql(u8, key, "REDIS_ACCOUNT")) {
        // Redis ACL 帳號。
        config.ddns.redis.account = value;
        return;
    }

    if (std.mem.eql(u8, key, "REDIS_PASSWORD")) {
        // Redis 密碼。
        config.ddns.redis.password = value;
        return;
    }

    if (std.mem.eql(u8, key, "REDIS_DB")) {
        // 這個值本來是字串，所以要先轉成 `u32`。
        // 如果轉換失敗，就保留原本設定值不動。
        config.ddns.redis.db = std.fmt.parseUnsigned(u32, value, 10) catch config.ddns.redis.db;
        return;
    }

    if (std.mem.eql(u8, key, "DDNS_REFRESH_INTERVAL_SECONDS")) {
        // 把 service refresh 間隔秒數轉成數字。
        config.ddns.refresh_interval_seconds =
            std.fmt.parseUnsigned(u64, value, 10) catch config.ddns.refresh_interval_seconds;
        return;
    }

    if (std.mem.eql(u8, key, "DDNS_DEDUPE_TTL_SECONDS")) {
        // 把 Redis 去重 TTL 秒數轉成數字。
        config.ddns.dedupe_ttl_seconds =
            std.fmt.parseUnsigned(u64, value, 10) catch config.ddns.dedupe_ttl_seconds;
        return;
    }
}

/// 把常見的布林文字轉成 `bool`。
///
/// 如果內容不是我們認得的布林字串，
/// 就保留原本值不動。
fn parseBoolOrKeep(value: []const u8, current: bool) bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "on")) return true;
    if (std.ascii.eqlIgnoreCase(value, "enabled")) return true;

    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    if (std.ascii.eqlIgnoreCase(value, "off")) return false;
    if (std.ascii.eqlIgnoreCase(value, "disabled")) return false;

    return current;
}

/// 取得環境變數文字，找不到就回傳 `null`。
fn getEnv(name: [*:0]const u8) ?[]const u8 {
    // `std.c.getenv` 走的是 C 標準函式庫的 getenv。
    const value = std.c.getenv(name) orelse return null;
    // C 的字串是 0 結尾指標，`std.mem.span` 會把它轉成 Zig 常用的 slice。
    return std.mem.span(value);
}

test "load config ignores unrelated rust settings" {
    // 這個測試確保：
    // Rust 原本 `app.json` 裡那些我們還沒移植的欄位，
    // 不會讓 Zig 版解析失敗。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{
        \\  "system": { "grpc_use_port": 9001 },
        \\  "afraid": { "enabled": false, "url": "https://freedns.afraid.org", "path": "/dynamic/update.php?", "token": "aaa" },
        \\  "dyny": {
        \\    "enabled": true,
        \\    "url": "https://api.dynu.com/nic/update",
        \\    "username": "dynu-user",
        \\    "password": "dynu-pass"
        \\  },
        \\  "noip": {
        \\    "enabled": false,
        \\    "url": "https://dynupdate.no-ip.com/nic/update",
        \\    "username": "noip-user",
        \\    "password": "noip-pass",
        \\    "hostnames": ["demo.ddns.net", "demo.zapto.org"]
        \\  },
        \\  "ddns": {
        \\    "redis": {
        \\      "enabled": false
        \\    }
        \\  }
        \\}
    ;

    const config = try parseJsonLeaky(allocator, json);

    // 確認真正需要的欄位都被正確解析出來。
    try std.testing.expect(!config.afraid.enabled);
    try std.testing.expectEqualStrings("https://freedns.afraid.org", config.afraid.url);
    try std.testing.expectEqualStrings("/dynamic/update.php?", config.afraid.path);
    try std.testing.expectEqualStrings("aaa", config.afraid.token);
    try std.testing.expect(config.dyny.enabled);
    try std.testing.expectEqualStrings("https://api.dynu.com/nic/update", config.dyny.url);
    try std.testing.expectEqualStrings("dynu-user", config.dyny.username);
    try std.testing.expect(!config.noip.enabled);
    try std.testing.expectEqualStrings("https://dynupdate.no-ip.com/nic/update", config.noip.url);
    try std.testing.expectEqualStrings("noip-user", config.noip.username);
    try std.testing.expectEqual(@as(usize, 2), config.noip.hostnames.len);
    try std.testing.expectEqualStrings("demo.ddns.net", config.noip.hostnames[0]);
    try std.testing.expect(!config.ddns.redis.enabled);
}

test "parse noip hostnames from env style json" {
    // 這個測試確認 `NOIP_HOSTNAMES=["a","b"]` 這種 JSON 陣列字串
    // 可以被正常解析成 Zig 的字串陣列。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const hostnames = try std.json.parseFromSliceLeaky(
        [][]const u8,
        allocator,
        "[\"a.ddns.net\",\"b.zapto.org\"]",
        .{},
    );

    try std.testing.expectEqual(@as(usize, 2), hostnames.len);
    try std.testing.expectEqualStrings("a.ddns.net", hostnames[0]);
    try std.testing.expectEqualStrings("b.zapto.org", hostnames[1]);
}

test "dotenv text overrides config values" {
    // 這個測試模擬一整份 `.env` 文字，確認覆寫流程有照預期工作。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = AppConfig{};
    const dotenv_text =
        \\# comment
        \\AFRAID_ENABLED=false
        \\AFRAID_TOKEN=example-afraid-token
        \\DYNU_ENABLED=1
        \\DYNU_URL=https://dynu.example.com/nic/update
        \\DYNU_USERNAME=example-dynu-user
        \\DYNU_PASSWORD=example-dynu-secret
        \\NOIP_ENABLED=off
        \\NOIP_URL=https://noip.example.com/nic/update
        \\NOIP_USERNAME=example-noip-user
        \\NOIP_PASSWORD=example-noip-secret
        \\NOIP_HOSTNAMES=["a.ddns.net","b.zapto.org"]
        \\REDIS_ENABLED=false
        \\REDIS_ADDR=127.0.0.1:6379
        \\REDIS_ACCOUNT=example-redis-user
        \\REDIS_PASSWORD=example-redis-secret
        \\REDIS_DB=5
        \\DDNS_DEDUPE_TTL_SECONDS=86400
        \\DDNS_REFRESH_INTERVAL_SECONDS=90
    ;

    try applyDotEnvTextOverridesLeaky(allocator, &config, dotenv_text);

    // 最後逐項確認：每個 key 都有落到正確欄位。
    try std.testing.expect(!config.afraid.enabled);
    try std.testing.expectEqualStrings("example-afraid-token", config.afraid.token);
    try std.testing.expect(config.dyny.enabled);
    try std.testing.expectEqualStrings("https://dynu.example.com/nic/update", config.dyny.url);
    try std.testing.expectEqualStrings("example-dynu-user", config.dyny.username);
    try std.testing.expect(!config.noip.enabled);
    try std.testing.expectEqualStrings("https://noip.example.com/nic/update", config.noip.url);
    try std.testing.expectEqualStrings("example-noip-user", config.noip.username);
    try std.testing.expectEqual(@as(usize, 2), config.noip.hostnames.len);
    try std.testing.expect(!config.ddns.redis.enabled);
    try std.testing.expectEqualStrings("127.0.0.1:6379", config.ddns.redis.addr);
    try std.testing.expectEqualStrings("example-redis-user", config.ddns.redis.account);
    try std.testing.expectEqualStrings("example-redis-secret", config.ddns.redis.password);
    try std.testing.expectEqual(@as(u32, 5), config.ddns.redis.db);
    try std.testing.expectEqual(@as(u64, 86400), config.ddns.dedupe_ttl_seconds);
    try std.testing.expectEqual(@as(u64, 90), config.ddns.refresh_interval_seconds);
}

test "parse bool override accepts common true false words" {
    try std.testing.expect(parseBoolOrKeep("true", false));
    try std.testing.expect(parseBoolOrKeep("1", false));
    try std.testing.expect(parseBoolOrKeep("yes", false));
    try std.testing.expect(parseBoolOrKeep("on", false));
    try std.testing.expect(!parseBoolOrKeep("false", true));
    try std.testing.expect(!parseBoolOrKeep("0", true));
    try std.testing.expect(!parseBoolOrKeep("no", true));
    try std.testing.expect(!parseBoolOrKeep("off", true));
    try std.testing.expect(parseBoolOrKeep("unknown", true));
    try std.testing.expect(!parseBoolOrKeep("unknown", false));
}
