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
    /// Cloudflare DNS API 設定。此 provider 直接管理 A / AAAA record，
    /// 與 Afraid、Dynu、No-IP 的專屬 DDNS 更新 URL 不同。
    cloudflare: Cloudflare = .{},
    /// Afraid.org 相關設定。
    afraid: Afraid = .{},
    /// Dynu 相關設定。
    dynu: Dynu = .{},
    /// No-IP 相關設定。
    noip: NoIp = .{},
    /// DDNS 服務本身的執行設定。
    ddns: Ddns = .{},
    /// Dashboard HTTP server 設定。
    dashboard: Dashboard = .{},
    /// 日誌輸出設定。
    logging: Logging = .{},
    /// DDNS 成功、失敗與恢復時的外部通知設定。
    notifications: Notifications = .{},
};

/// Cloudflare DNS provider 的設定。
///
/// 使用最小權限的 API Token；Token 至少需要目標 zone 的 DNS Edit 權限。
/// `zone_id` 採顯式設定而非每輪自動搜尋，避免不必要的 Zone Read 權限與 API 呼叫。
pub const Cloudflare = struct {
    /// false 時完全不呼叫 Cloudflare API。
    enabled: bool = false,
    /// Cloudflare API Token；不要使用舊式 global API key。
    api_token: []const u8 = "",
    /// Cloudflare zone ID（32 字元十六進位 ID）。
    zone_id: []const u8 = "",
    /// 要管理的完整 record 名稱，例如 `home.example.com`。
    hostnames: []const []const u8 = &.{},
    /// 建立新 record 時是否啟用 Cloudflare proxy；既有 record 更新時不變更此設定。
    proxied: bool = false,
    /// 建立新 record 時的 TTL；1 代表 Cloudflare Automatic。
    ttl: u32 = 1,
    /// 新建 record 時寫入的 Cloudflare comment。空字串代表不寫入 comment。
    /// 建議填入例如 `managed-by:dynip`，讓多個 DDNS instance 可安全共存。
    record_comment: []const u8 = "",
    /// 只允許更新 comment 完全相符的既有 record。空字串維持舊行為：
    /// 所有同名同型別 record 都視為可管理；正式多 instance 部署應設定此欄位。
    managed_record_comment: []const u8 = "",
    /// Cloudflare List/PATCH/POST 遇到 429 或 5xx 時的額外嘗試次數。
    /// 例如 2 代表第一次失敗後最多再試兩次。
    http_retry_count: u32 = 2,
};

/// 寫進日誌前用來取代 token / password 的固定遮罩字串。
pub const masked_secret = "*****";

/// Afraid.org DDNS 設定。
pub const Afraid = struct {
    /// 是否啟用 Afraid 更新。
    ///
    /// 設成 `false` 時，就算 IP 真的改變，
    /// 這輪更新也不會去打 Afraid API。
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

/// Redis 防重複更新設定。
///
/// Zig 版現在改成真的連 Redis，不再用本地 `.ddns_state.json` 模擬。
pub const Redis = struct {
    /// 是否啟用 Redis 防重複更新。
    ///
    /// 設成 `false` 時，DDNS 會退回成本機記憶體防重複更新。
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
    /// 每輪更新之間要等幾秒。
    refresh_interval_seconds: u64 = 60,
    /// Redis 防重複更新 key 的 TTL 秒數。
    dedupe_ttl_seconds: u64 = 60 * 60 * 24,
    /// IPv4 public IP 的來源：`auto`、`none`、`stun`、`cloudflare_trace`、
    /// `url:<https-url>`、`file:<absolute-path>` 或 `static:<ip>`。
    ipv4_provider: []const u8 = "auto",
    /// IPv6 public IP 的來源；格式與 ipv4_provider 相同，兩者可獨立停用或指定。
    ipv6_provider: []const u8 = "auto",
    /// Redis 連線設定。
    redis: Redis = .{},
};

/// Dashboard HTTP server 設定。
///
/// 這個設定控制的是「同一個 dynip process 內」的 HTTP Dashboard。
/// Docker 部署時，container 內預設也使用同一個 port：9003。
pub const Dashboard = struct {
    /// 是否在同一個 dynip process 內啟動 Dashboard HTTP server。
    ///
    /// 設成 false 時，`dynip service` 只跑 DDNS scheduler，不開 Web port。
    enabled: bool = true,
    /// Dashboard 綁定位址。
    ///
    /// - `0.0.0.0`：容器/主機所有網卡都可連，適合 Docker publish port。
    /// - `127.0.0.1`：只允許本機連線，適合本機測試。
    host: []const u8 = "0.0.0.0",
    /// Dashboard 監聽 port。
    ///
    /// 依目前線上服務 port 排列，DDNS Dashboard 預設接在 9001-9002 後面。
    port: u32 = 9003,
};

/// 日誌相關設定。
pub const Logging = struct {
    /// console 最低輸出等級。
    console_level: []const u8 = "info",
    /// 檔案日誌最低輸出等級。
    file_level: []const u8 = "info",
    /// Seq HTTP ingestion 設定。
    seq: SeqLogging = .{},
};

/// 外部監控與 webhook 通知設定。
/// 空字串代表該整合未設定；三個 URL 可以同時啟用。
pub const Notifications = struct {
    /// Healthchecks 相容 ping URL；每輪成功會送出 ping。
    healthchecks_url: []const u8 = "",
    /// Uptime Kuma Push URL；每輪成功會送出 ping。
    uptime_kuma_url: []const u8 = "",
    /// 通用 webhook URL；會收到 JSON event body。
    webhook_url: []const u8 = "",
};

/// Seq 日誌收集設定。
pub const SeqLogging = struct {
    /// 是否把本專案日誌送到 Seq。
    enabled: bool = false,
    /// Seq 最低送出等級。
    level: []const u8 = "warn",
    /// Seq server URL，例如 `http://192.168.111.224:5341`。
    server_url: []const u8 = "",
    /// Seq ingestion API key。實際值建議放在 `.env`。
    api_key: []const u8 = "",
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
    // 最後再用目前執行環境的環境變數覆蓋一次。
    // 這樣環境變數的優先權最高。
    try applyProcessEnvOverridesLeaky(allocator, &config);
    // 回傳最後生效的設定。
    return config;
}

/// 建立一份適合寫進日誌的安全設定副本。
///
/// 這個函式會保留原本的功能性設定，
/// 但把密碼與 token 欄位改成 [`masked_secret`]。
pub fn redactedForLog(app_config: AppConfig) AppConfig {
    // 先把整份設定做一次值複製，
    // 這樣後面改的是副本，不會動到原本真的要拿來跑服務的設定。
    var redacted = app_config;
    // 如果 Afraid token 不是空字串，就把它換成固定遮罩字串。
    redactIfPresent(&redacted.afraid.token);
    // 如果 Dynu 密碼不是空字串，就把它換成固定遮罩字串。
    redactIfPresent(&redacted.dynu.password);
    // 如果 No-IP 密碼不是空字串，就把它換成固定遮罩字串。
    redactIfPresent(&redacted.noip.password);
    // 如果 Redis 密碼不是空字串，就把它換成固定遮罩字串。
    redactIfPresent(&redacted.ddns.redis.password);
    // 如果 Seq API key 不是空字串，就把它換成固定遮罩字串。
    redactIfPresent(&redacted.logging.seq.api_key);
    // Healthchecks、Uptime Kuma 與 webhook URL 常將 UUID 或 token 放進路徑或 query，
    // 因此和密碼一樣不能出現在啟動時輸出的完整設定日誌。
    redactIfPresent(&redacted.notifications.healthchecks_url);
    redactIfPresent(&redacted.notifications.uptime_kuma_url);
    redactIfPresent(&redacted.notifications.webhook_url);
    // 回傳這份「可安全寫進日誌」的設定副本。
    return redacted;
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
/// 然後整個服務生命週期都會一直使用它。
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

    // 如果專案根目錄沒有 `.env`，就直接跳過，不當成錯誤。
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

/// 套用目前執行環境的環境變數覆寫。
///
/// 這一層是讀作業系統真的存在的環境變數，
/// 例如你在 shell 裡先 `export AFRAID_TOKEN=...` 那種。
/// 優先權比 `.env` 更高，因為它會最後套用。
///
/// `inline for` 在編譯期把 `env_overrides` 裡所有 key 展開成獨立的
/// `getEnv` 呼叫。每個 key 在 comptime 就已知，可以直接轉成
/// C sentinel 字串，不需要執行期的任何字串複製或 buffer。
fn applyProcessEnvOverridesLeaky(allocator: std.mem.Allocator, config: *AppConfig) !void {
    // `inline for` 在編譯期把所有 override 展開成獨立的 `if (getEnv(...))` 判斷。
    // 每個 key 都是 comptime 已知的字串常數，不需要執行期額外配置。
    inline for (env_overrides) |override| {
        // 把 comptime 已知的 key 字串轉成 C 格式（在尾端補 null byte）。
        // `@as([*:0]const u8, ...)` 讓 Zig 知道這是 sentinel 終止指標，
        // 可以直接傳給 `std.c.getenv`。
        const sentinel_key: [*:0]const u8 = comptime @as([*:0]const u8, @ptrCast((override.key ++ .{0}).ptr));
        if (getEnv(sentinel_key)) |value| {
            try applyOverrideValueLeaky(allocator, config, override.key, value);
        }
    }
}

/// 環境變數覆寫的「型別標記」。
///
/// `applyOverrideValueLeaky` 的 comptime 對應表會用這個 enum
/// 決定每個 key 要用哪種方式把字串 value 轉成正確型別再寫入設定。
///
/// - `.str`    : 直接把 `[]const u8` 寫入字串欄位。
/// - `.bool`   : 用 `parseBoolOrKeep` 把常見布林字串轉成 `bool`。
/// - `.u32`    : 用 `std.fmt.parseUnsigned(u32, ...)` 轉成無號 32 位整數。
/// - `.u64`    : 用 `std.fmt.parseUnsigned(u64, ...)` 轉成無號 64 位整數。
/// - `.str_arr`: 用 JSON 解析把 `["a","b"]` 轉成 `[][]const u8`。
const FieldKind = enum { str, bool, u32, u64, str_arr };

/// 每一筆環境變數覆寫規則的描述。
/// comptime 建表時需要用字串路徑（`field`）來找到 `AppConfig` 裡對應的欄位指標，
/// 再搭配 `kind` 決定轉型策略。
const EnvOverride = struct {
    /// 環境變數名稱（例如 `"AFRAID_TOKEN"`）。
    key: []const u8,
    /// 從 `AppConfig` 根到目標欄位的點分路徑（例如 `"afraid.token"`）。
    ///
    /// `applyOverrideValueLeaky` 裡的 `inline for` 會在 comptime 用
    /// `@field(...)` 逐層解析這個路徑，不需要執行期字串處理。
    field: []const u8,
    /// 寫入時要用哪種轉型策略。
    kind: FieldKind,
};

/// 環境變數 → AppConfig 欄位的完整對應表。
///
/// 這是整個覆寫機制的唯一真實來源（single source of truth）。
/// 新增或移除一個環境變數時，**只需要改這裡**，其他地方完全不動：
/// - `applyProcessEnvOverridesLeaky` 直接從這張表提取 key 名稱。
/// - `applyOverrideValueLeaky` 直接從這張表找到目標欄位與轉型策略。
const env_overrides = [_]EnvOverride{
    .{ .key = "CLOUDFLARE_ENABLED", .field = "cloudflare.enabled", .kind = .bool },
    .{ .key = "CLOUDFLARE_API_TOKEN", .field = "cloudflare.api_token", .kind = .str },
    .{ .key = "CLOUDFLARE_ZONE_ID", .field = "cloudflare.zone_id", .kind = .str },
    .{ .key = "CLOUDFLARE_HOSTNAMES", .field = "cloudflare.hostnames", .kind = .str_arr },
    .{ .key = "CLOUDFLARE_PROXIED", .field = "cloudflare.proxied", .kind = .bool },
    .{ .key = "CLOUDFLARE_TTL", .field = "cloudflare.ttl", .kind = .u32 },
    .{ .key = "CLOUDFLARE_RECORD_COMMENT", .field = "cloudflare.record_comment", .kind = .str },
    .{ .key = "CLOUDFLARE_MANAGED_RECORD_COMMENT", .field = "cloudflare.managed_record_comment", .kind = .str },
    .{ .key = "CLOUDFLARE_HTTP_RETRY_COUNT", .field = "cloudflare.http_retry_count", .kind = .u32 },
    .{ .key = "AFRAID_URL", .field = "afraid.url", .kind = .str },
    .{ .key = "AFRAID_ENABLED", .field = "afraid.enabled", .kind = .bool },
    .{ .key = "AFRAID_PATH", .field = "afraid.path", .kind = .str },
    .{ .key = "AFRAID_TOKEN", .field = "afraid.token", .kind = .str },
    .{ .key = "DYNU_ENABLED", .field = "dynu.enabled", .kind = .bool },
    .{ .key = "DYNU_URL", .field = "dynu.url", .kind = .str },
    .{ .key = "DYNU_USERNAME", .field = "dynu.username", .kind = .str },
    .{ .key = "DYNU_PASSWORD", .field = "dynu.password", .kind = .str },
    .{ .key = "NOIP_ENABLED", .field = "noip.enabled", .kind = .bool },
    .{ .key = "NOIP_URL", .field = "noip.url", .kind = .str },
    .{ .key = "NOIP_USERNAME", .field = "noip.username", .kind = .str },
    .{ .key = "NOIP_PASSWORD", .field = "noip.password", .kind = .str },
    .{ .key = "NOIP_HOSTNAMES", .field = "noip.hostnames", .kind = .str_arr },
    .{ .key = "REDIS_ADDR", .field = "ddns.redis.addr", .kind = .str },
    .{ .key = "REDIS_ENABLED", .field = "ddns.redis.enabled", .kind = .bool },
    .{ .key = "REDIS_ACCOUNT", .field = "ddns.redis.account", .kind = .str },
    .{ .key = "REDIS_PASSWORD", .field = "ddns.redis.password", .kind = .str },
    .{ .key = "REDIS_DB", .field = "ddns.redis.db", .kind = .u32 },
    .{ .key = "DDNS_REFRESH_INTERVAL_SECONDS", .field = "ddns.refresh_interval_seconds", .kind = .u64 },
    .{ .key = "DDNS_DEDUPE_TTL_SECONDS", .field = "ddns.dedupe_ttl_seconds", .kind = .u64 },
    .{ .key = "DDNS_IPV4_PROVIDER", .field = "ddns.ipv4_provider", .kind = .str },
    .{ .key = "DDNS_IPV6_PROVIDER", .field = "ddns.ipv6_provider", .kind = .str },
    // Dashboard 可用環境變數覆寫 app.json，Docker 啟動時會用到。
    .{ .key = "DASHBOARD_ENABLED", .field = "dashboard.enabled", .kind = .bool },
    .{ .key = "DASHBOARD_HOST", .field = "dashboard.host", .kind = .str },
    .{ .key = "DASHBOARD_PORT", .field = "dashboard.port", .kind = .u32 },
    .{ .key = "LOG_CONSOLE_LEVEL", .field = "logging.console_level", .kind = .str },
    .{ .key = "LOG_FILE_LEVEL", .field = "logging.file_level", .kind = .str },
    .{ .key = "LOG_SEQ_ENABLED", .field = "logging.seq.enabled", .kind = .bool },
    .{ .key = "LOG_SEQ_LEVEL", .field = "logging.seq.level", .kind = .str },
    .{ .key = "LOG_SEQ_SERVER_URL", .field = "logging.seq.server_url", .kind = .str },
    .{ .key = "LOG_SEQ_API_KEY", .field = "logging.seq.api_key", .kind = .str },
    .{ .key = "HEALTHCHECKS_URL", .field = "notifications.healthchecks_url", .kind = .str },
    .{ .key = "UPTIME_KUMA_URL", .field = "notifications.uptime_kuma_url", .kind = .str },
    .{ .key = "NOTIFICATION_WEBHOOK_URL", .field = "notifications.webhook_url", .kind = .str },
};

/// 依 key 把覆寫值寫進設定結構。
///
/// 實作策略：
/// 1. 以 `inline for` 走 `env_overrides` 陣列（comptime 已知）。
/// 2. 每次迭代的 `override.key` 與 `override.field` 都是 comptime 常數，
///    讓 `resolveField(config, override.field)` 能在 comptime 解析點分路徑。
/// 3. `override.kind` 同樣是 comptime 常數，`switch` 的每個分支都能被編譯器靜態特化，
///    最終機器碼等同手寫的直接賦值，不產生任何執行期分派。
fn applyOverrideValueLeaky(
    allocator: std.mem.Allocator,
    config: *AppConfig,
    key: []const u8,
    value: []const u8,
) !void {
    // `inline for` 走唯一的 `env_overrides` 表，把每個 entry 展開成獨立分支。
    // `override.key` 是 comptime 常數；傳入的 `key` 是執行期 slice。
    inline for (env_overrides) |override| {
        // 比對執行期傳入的 key 與這個 comptime 分支的 key 是否相同。
        // 注意：`inline for` 裡的 `continue` 只有在條件為 comptime 時才合法；
        // 這裡 `key` 是執行期值，所以改用 `if` 把整個賦值區塊包起來。
        if (std.mem.eql(u8, key, override.key)) {
            // `resolveField` 在 comptime 用 `@field` 逐層解析點分路徑，
            // 讓巢狀欄位（例如 `ddns.redis.addr`）也能正確取到可寫的欄位指標。
            // `override.field` 是 comptime 常數，這個呼叫完全在編譯期完成。
            const field_ptr = resolveField(config, override.field);

            // `override.kind` 也是 comptime 常數，`switch` 的每個分支都能被編譯器靜態特化，
            // 不同 kind 的展開版本不會互相混合。
            switch (override.kind) {
                // 字串型別：直接把 value slice 寫入欄位。
                .str => field_ptr.* = value,
                // 布林型別：辨識 true/false/1/0/yes/no/on/off 等常見寫法。
                .bool => field_ptr.* = parseBoolOrKeep(value, field_ptr.*),
                // 無號 32 位整數：解析失敗時保留原值，不中斷整個覆寫流程。
                .u32 => field_ptr.* = std.fmt.parseUnsigned(u32, value, 10) catch field_ptr.*,
                // 無號 64 位整數：同上。
                .u64 => field_ptr.* = std.fmt.parseUnsigned(u64, value, 10) catch field_ptr.*,
                // JSON 字串陣列：例如 `["a.ddns.net","b.zapto.org"]`。
                // `Leaky` 表示解析後的字串記憶體交給外層 arena 統一回收。
                .str_arr => field_ptr.* = try std.json.parseFromSliceLeaky(
                    [][]const u8,
                    allocator,
                    value,
                    .{},
                ),
            }
            return;
        }
    }
}

/// 用 `@field` 逐層解析點分路徑，回傳最終欄位的可寫指標。
///
/// 因為 `path` 在呼叫端一定是 comptime 常數（來自 `env_overrides`），
/// 整個解析過程都在編譯期完成，執行期沒有任何字串掃描。
///
/// 例如 `"ddns.redis.addr"` 會被解析為：
/// `&config.ddns.redis.addr`（型別由 Zig 在 comptime 推導）。
fn resolveField(config: *AppConfig, comptime path: []const u8) *resolveFieldType(AppConfig, path) {
    // 委派給遞迴的 `resolveFieldImpl`，在 comptime 逐層解析點分路徑。
    return resolveFieldImpl(config, path);
}

/// `resolveField` 的型別層計算：在 comptime 算出點分路徑最終指向的型別。
fn resolveFieldType(comptime T: type, comptime path: []const u8) type {
    // env_overrides 會為每個環境變數特化一次這個函式；設定項目較多時，
    // Zig 預設的 1000 個 comptime 分支不足，明確提高上限而不影響執行期成本。
    @setEvalBranchQuota(10_000);
    // 找到第一個 `.` 的位置。
    const dot = comptime std.mem.indexOfScalar(u8, path, '.') orelse {
        // 沒有 `.`，代表這已經是最後一層，直接用 `@field` 取出型別。
        return @TypeOf(@field(@as(T, undefined), path));
    };
    // 有 `.`，先取出第一段欄位名稱，再遞迴往下一層。
    const head = path[0..dot];
    const tail = path[dot + 1 ..];
    const HeadType = @TypeOf(@field(@as(T, undefined), head));
    return resolveFieldType(HeadType, tail);
}

/// `resolveField` 的指標層實作：逐層解引用到最終欄位的可寫指標。
///
/// Zig 0.17 的 `orelse` block 內若有 `return`，有時會被編譯器誤判為 comptime context。
/// 這裡改用 comptime `if/else` 取代 `orelse {...}`，避免誤判。
fn resolveFieldImpl(ptr: anytype, comptime path: []const u8) *resolveFieldType(
    @typeInfo(@TypeOf(ptr)).pointer.child,
    path,
) {
    // 與 resolveFieldType 同理：這是純編譯期路徑展開，增加 quota 只影響編譯器。
    @setEvalBranchQuota(10_000);
    // `comptime` 確保條件在編譯期求值，產生的 if/else 是靜態分支，不是執行期分派。
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    if (comptime dot == null) {
        // 沒有 `.`，已到達最終欄位，直接回傳可寫指標。
        return &@field(ptr.*, path);
    } else {
        // 有 `.`，先取第一段欄位名稱，再往下遞迴。
        const head = comptime path[0..dot.?];
        const tail = comptime path[dot.? + 1 ..];
        return resolveFieldImpl(&@field(ptr.*, head), tail);
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

/// 只有原值非空時才改成遮罩，避免把空字串誤寫成看似有秘密。
fn redactIfPresent(value: *[]const u8) void {
    if (value.*.len == 0) return;
    value.* = masked_secret;
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
        \\  "dynu": {
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
        \\  },
        \\  "dashboard": {
        \\    "enabled": true,
        \\    "host": "127.0.0.1",
        \\    "port": 18080
        \\  }
        \\}
    ;

    const config = try parseJsonLeaky(allocator, json);

    // 確認真正需要的欄位都被正確解析出來。
    try std.testing.expect(!config.afraid.enabled);
    try std.testing.expectEqualStrings("https://freedns.afraid.org", config.afraid.url);
    try std.testing.expectEqualStrings("/dynamic/update.php?", config.afraid.path);
    try std.testing.expectEqualStrings("aaa", config.afraid.token);
    try std.testing.expect(config.dynu.enabled);
    try std.testing.expectEqualStrings("https://api.dynu.com/nic/update", config.dynu.url);
    try std.testing.expectEqualStrings("dynu-user", config.dynu.username);
    try std.testing.expect(!config.noip.enabled);
    try std.testing.expectEqualStrings("https://dynupdate.no-ip.com/nic/update", config.noip.url);
    try std.testing.expectEqualStrings("noip-user", config.noip.username);
    try std.testing.expectEqual(@as(usize, 2), config.noip.hostnames.len);
    try std.testing.expectEqualStrings("demo.ddns.net", config.noip.hostnames[0]);
    try std.testing.expect(!config.ddns.redis.enabled);
    try std.testing.expect(config.dashboard.enabled);
    try std.testing.expectEqualStrings("127.0.0.1", config.dashboard.host);
    try std.testing.expectEqual(@as(u32, 18080), config.dashboard.port);
}

test "redacted config masks secrets only when present" {
    const redacted = redactedForLog(.{
        .afraid = .{ .token = "afraid-secret" },
        .dynu = .{ .password = "dynu-secret" },
        .noip = .{ .password = "noip-secret" },
        .ddns = .{ .redis = .{ .password = "redis-secret" } },
    });

    try std.testing.expectEqualStrings(masked_secret, redacted.afraid.token);
    try std.testing.expectEqualStrings(masked_secret, redacted.dynu.password);
    try std.testing.expectEqualStrings(masked_secret, redacted.noip.password);
    try std.testing.expectEqualStrings(masked_secret, redacted.ddns.redis.password);
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
        \\DDNS_IPV4_PROVIDER=static:203.0.113.9
        \\DDNS_IPV6_PROVIDER=none
        \\CLOUDFLARE_RECORD_COMMENT=managed-by:dynip
        \\CLOUDFLARE_MANAGED_RECORD_COMMENT=managed-by:dynip
        \\CLOUDFLARE_HTTP_RETRY_COUNT=3
        \\DASHBOARD_ENABLED=true
        \\DASHBOARD_HOST=127.0.0.1
        \\DASHBOARD_PORT=18080
        \\LOG_CONSOLE_LEVEL=debug
        \\LOG_FILE_LEVEL=info
        \\LOG_SEQ_ENABLED=true
        \\LOG_SEQ_LEVEL=warn
        \\LOG_SEQ_SERVER_URL=http://seq.example.com:5341
        \\LOG_SEQ_API_KEY=example-seq-key
    ;

    try applyDotEnvTextOverridesLeaky(allocator, &config, dotenv_text);

    // 最後逐項確認：每個 key 都有落到正確欄位。
    try std.testing.expect(!config.afraid.enabled);
    try std.testing.expectEqualStrings("example-afraid-token", config.afraid.token);
    try std.testing.expect(config.dynu.enabled);
    try std.testing.expectEqualStrings("https://dynu.example.com/nic/update", config.dynu.url);
    try std.testing.expectEqualStrings("example-dynu-user", config.dynu.username);
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
    try std.testing.expectEqualStrings("static:203.0.113.9", config.ddns.ipv4_provider);
    try std.testing.expectEqualStrings("none", config.ddns.ipv6_provider);
    try std.testing.expectEqualStrings("managed-by:dynip", config.cloudflare.record_comment);
    try std.testing.expectEqualStrings("managed-by:dynip", config.cloudflare.managed_record_comment);
    try std.testing.expectEqual(@as(u32, 3), config.cloudflare.http_retry_count);
    try std.testing.expect(config.dashboard.enabled);
    try std.testing.expectEqualStrings("127.0.0.1", config.dashboard.host);
    try std.testing.expectEqual(@as(u32, 18080), config.dashboard.port);
    try std.testing.expectEqualStrings("debug", config.logging.console_level);
    try std.testing.expectEqualStrings("info", config.logging.file_level);
    try std.testing.expect(config.logging.seq.enabled);
    try std.testing.expectEqualStrings("warn", config.logging.seq.level);
    try std.testing.expectEqualStrings("http://seq.example.com:5341", config.logging.seq.server_url);
    try std.testing.expectEqualStrings("example-seq-key", config.logging.seq.api_key);
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
