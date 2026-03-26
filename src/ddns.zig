//! DDNS 更新流程。
//!
//! 職責包含：
//! - 取得目前對外公網 IP。
//! - 判斷是否需要略過凌晨維護時段。
//! - 比對 Redis 內的 `MyPublicIP:{ip}` key，沿用 Rust 版去重邏輯。
//! - 依序更新 Afraid / Dynu / No-IP。

/// 匯入編譯期提供的目標平台資訊。
///
/// 例如目前是不是 Windows，就會從這裡判斷。
const builtin = @import("builtin");
/// 匯入 Zig 標準函式庫。
///
/// HTTP client、字串處理、JSON、記憶體配置等通用能力都從這裡來。
const std = @import("std");
/// 匯入本專案的設定模組。
///
/// 這樣 DDNS 流程就能讀到 `app.json` / `.env` 載入後的設定值。
const config_mod = @import("config.zig");
/// 匯入本專案的 Redis client。
///
/// DDNS 去重現在要真的查 Redis，所以 refresh 流程會呼叫這個模組。
const redis = @import("redis.zig");
/// 建立 HTTP 專用的 log scope。
///
/// 之後用 `http_log.info(...)` 時，日誌就會帶上 `(http)` 這個分類。
const http_log = std.log.scoped(.http);

/// 匯入 C 的 `time.h`。
///
/// 這裡主要是為了呼叫 `time`、`localtime_r` 之類的時間 API。
const c = @cImport({
    @cInclude("time.h");
});

/// 只有在 Windows 平台時才匯入 Win32 API。
///
/// 非 Windows 平台則放一個空 struct，讓後面的程式仍然能編譯。
const win = if (builtin.os.tag == .windows)
    @cImport({
        @cInclude("windows.h");
    })
else
    struct {};

/// 單次 refresh 的結果。
pub const RefreshStatus = enum {
    /// 有真的更新到至少一個 DDNS 服務。
    updated,
    /// 因為 Redis 裡的 `MyPublicIP:{ip}` 還在，所以這次直接跳過。
    skipped_cached_ip,
    /// 因為現在落在凌晨維護時間，所以這次直接跳過。
    skipped_maintenance_window,
};

/// 取得 public IP 時，可能依序嘗試的來源站。
const PublicIpService = enum {
    /// `https://api.ipify.org`
    ipify,
    /// `https://ipconfig.io/ip`
    ipconfig,
    /// `https://ipinfo.io/ip`
    ipinfo,
    /// `https://ipv4.seeip.org`
    seeip,
    /// `https://api.myip.com`
    myip,
    /// `https://api.bigdatacloud.net/data/client-ip`
    bigdatacloud,
};

/// 這一輪更新所有 DDNS 供應商後的統計結果。
const ServiceSummary = struct {
    /// 總共嘗試了幾個供應商。
    attempted: usize = 0,
    /// 其中有幾個供應商最後成功。
    succeeded: usize = 0,
};

/// 本地 `fetchText(...)` helper 回傳的資料。
const FetchTextResponse = struct {
    /// HTTP 狀態碼，例如 200、404。
    status: std.http.Status,
    /// 完整 response body。
    body: []u8,
};

/// 寫 HTTP request / response log 時，網址預覽用的暫存 buffer 長度。
const http_log_url_buffer_len = 512;
/// 寫 HTTP body 預覽時，最多保留的字元數。
const http_log_body_preview_len = 256;
/// Redis 關閉時，退回本機去重用的快取資料。
const LocalDedupeEntry = struct {
    key: []u8,
    expires_at: i64,
};
/// 本機去重狀態的互斥鎖。
var local_dedupe_mutex: std.atomic.Mutex = .unlocked;
/// 本機去重用的記憶體快取。
var local_dedupe_entries: std.ArrayListUnmanaged(LocalDedupeEntry) = .empty;

/// 集中管理這個模組會打到的第三方網址。
///
/// 之後如果要：
/// - 更換 public IP 來源站
/// - 調整 Dynu / No-IP API base URL
/// - 統一檢查目前到底有哪些外部端點
///
/// 就只需要看這一個區塊，不用在整份 `ddns.zig` 到處找字串常數。
const Endpoint = struct {
    /// 所有 public IP 來源站的網址。
    const PublicIp = struct {
        /// 直接回傳純文字 IP。
        const ipify = "https://api.ipify.org";
        /// 直接回傳純文字 IP。
        const ipconfig = "https://ipconfig.io/ip";
        /// 直接回傳純文字 IP。
        const ipinfo = "https://ipinfo.io/ip";
        /// 直接回傳純文字 IP。
        const seeip = "https://ipv4.seeip.org";
        /// 回傳 JSON，IP 欄位名稱是 `ip`。
        const myip = "https://api.myip.com";
        /// 回傳 JSON，IP 欄位名稱是 `ipString`。
        const bigdatacloud = "https://api.bigdatacloud.net/data/client-ip";
    };

    /// Dynu 更新 API base URL。
    const dynu_update = "https://api.dynu.com/nic/update";
    /// No-IP 更新 API base URL。
    const noip_update = "https://dynupdate.no-ip.com/nic/update";
};

/// 下次抓 public IP 時，從哪個來源站開始嘗試。
///
/// 這樣每次 refresh 不會永遠都從第一個來源站開始打，
/// 而是會做簡單的 round-robin。
var next_public_ip_index: usize = 0;

/// 執行一次 DDNS 更新檢查。
pub fn refresh(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.AppConfig,
) !RefreshStatus {
    // 先看現在是否落在「故意略過更新」的維護時間。
    if (shouldSkipMaintenanceWindow()) {
        std.log.info("skip ddns refresh during 02:00-02:04 local maintenance window", .{});
        return .skipped_maintenance_window;
    }

    // 建立一個 arena allocator，讓這一輪 refresh 內的暫時字串與 JSON 解析結果
    // 都集中配置在同一塊記憶體裡。
    var arena = std.heap.ArenaAllocator.init(allocator);
    // 這一輪 refresh 結束時，把 arena 一次整包釋放掉。
    defer arena.deinit();
    // `scratch` 是這一輪 refresh 專用的 allocator。
    const scratch = arena.allocator();

    // 建一個 HTTP client，後面抓 public IP 與更新 DDNS 都會用到它。
    var client: std.http.Client = .{
        .allocator = scratch,
        .io = io,
    };
    // 用完後關掉 client。
    defer client.deinit();

    // 先抓目前對外的公網 IP。
    const ip_now = try getPublicIp(scratch, &client);
    // 再組出和 Rust 專案相同格式的 Redis key。
    const cache_key = try buildPublicIpCacheKey(scratch, ip_now);
    // 先算出這次 dedupe 要用的 TTL。
    const ttl_seconds = if (config.ddns.dedupe_ttl_seconds == 0)
        @as(u64, 60 * 60 * 24)
    else
        config.ddns.dedupe_ttl_seconds;

    // 先做 dedupe 檢查：
    // - Redis 啟用時走 Redis
    // - Redis 關閉時改成本機記憶體
    if (try isDedupeHit(scratch, io, config.ddns.redis, cache_key)) {
        return .skipped_cached_ip;
    }

    // 真的去更新所有有完成設定的 DDNS 供應商。
    const summary = try updateDdnsServices(scratch, &client, config, ip_now);
    // 一個供應商都沒啟用，視為設定錯誤。
    if (summary.attempted == 0) return error.NoEnabledDdnsService;
    // 有嘗試，但全部失敗，就把整輪 refresh 視為失敗。
    if (summary.succeeded == 0) return error.AllDdnsUpdatesFailed;

    // 至少有一個供應商更新成功後，才把這個 IP 寫進 dedupe cache。
    try rememberDedupe(scratch, io, config.ddns.redis, cache_key, ip_now, ttl_seconds);

    // 最後寫一筆總結 log，讓你知道這輪使用哪個 IP，以及成功幾個供應商。
    std.log.info(
        "ddns refresh completed: ip={s}, succeeded={d}/{d}",
        .{ ip_now, summary.succeeded, summary.attempted },
    );
    return .updated;
}

/// 把目前公網 IP 轉成和 Rust 版相同的 Redis key 格式。
fn buildPublicIpCacheKey(allocator: std.mem.Allocator, ip: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "MyPublicIP:{s}", .{ip});
}

/// 固定用來保存「目前最新 public IP」的 Redis key。
fn currentPublicIpRedisKey() []const u8 {
    return "MyPublicIP";
}

/// 檢查目前這個 IP 是否已經在去重快取裡。
fn isDedupeHit(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    cache_key: []const u8,
) !bool {
    if (!redis_config.enabled) {
        if (localDedupeContains(cache_key)) {
            std.log.info(
                "skip ddns refresh because local cache key already exists: {s}",
                .{cache_key},
            );
            return true;
        }
        return false;
    }

    // 這裡刻意沿用 Rust 版的容錯策略：
    // - 如果 Redis 查詢失敗，只記 warn
    // - 但整個 DDNS refresh 仍然繼續跑
    return redis.containsKey(allocator, io, redis_config, cache_key) catch |err| blk: {
        std.log.warn(
            "failed to check redis key before ddns refresh: key={s}, error={}",
            .{ cache_key, err },
        );
        break :blk false;
    };
}

/// 記住這次成功更新過的 IP，避免 TTL 內重複更新。
fn rememberDedupe(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    cache_key: []const u8,
    ip: []const u8,
    ttl_seconds: u64,
) !void {
    if (!redis_config.enabled) {
        try localDedupeSet(cache_key, ttl_seconds);
        std.log.info("ddns local cache updated: key={s}, ttl={d}s", .{ cache_key, ttl_seconds });
        return;
    }

    try redis.setEx(
        allocator,
        io,
        redis_config,
        cache_key,
        ip,
        ttl_seconds,
    );
    try redis.setEx(
        allocator,
        io,
        redis_config,
        currentPublicIpRedisKey(),
        ip,
        ttl_seconds,
    );
    std.log.info("ddns redis cache updated: key={s}, ttl={d}s", .{ cache_key, ttl_seconds });
    std.log.info(
        "ddns redis current public ip updated: key={s}, ip={s}, ttl={d}s",
        .{ currentPublicIpRedisKey(), ip, ttl_seconds },
    );
}

/// 取得目前 Unix 秒數。
fn currentUnixSeconds() i64 {
    return @intCast(c.time(null));
}

/// 本機去重：檢查 key 是否還在 TTL 內。
fn localDedupeContains(key: []const u8) bool {
    return localDedupeContainsAt(key, currentUnixSeconds());
}

/// 本機去重：把 key 記到 TTL 過期為止。
fn localDedupeSet(key: []const u8, ttl_seconds: u64) !void {
    try localDedupeSetAt(key, ttl_seconds, currentUnixSeconds());
}

/// 供正式流程與測試共用的本機去重查詢邏輯。
fn localDedupeContainsAt(key: []const u8, now_seconds: i64) bool {
    lockLocalDedupe();
    defer unlockLocalDedupe();

    pruneExpiredLocalDedupeLocked(now_seconds);

    for (local_dedupe_entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
}

/// 供正式流程與測試共用的本機去重寫入邏輯。
fn localDedupeSetAt(key: []const u8, ttl_seconds: u64, now_seconds: i64) !void {
    lockLocalDedupe();
    defer unlockLocalDedupe();

    pruneExpiredLocalDedupeLocked(now_seconds);

    const expires_at = now_seconds + @as(i64, @intCast(ttl_seconds));
    for (local_dedupe_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.expires_at = expires_at;
            return;
        }
    }

    try local_dedupe_entries.append(std.heap.page_allocator, .{
        .key = try std.heap.page_allocator.dupe(u8, key),
        .expires_at = expires_at,
    });
}

/// 把已過期的本機去重項目從記憶體移除。
fn pruneExpiredLocalDedupeLocked(now_seconds: i64) void {
    var index: usize = 0;
    while (index < local_dedupe_entries.items.len) {
        if (local_dedupe_entries.items[index].expires_at > now_seconds) {
            index += 1;
            continue;
        }

        std.heap.page_allocator.free(local_dedupe_entries.items[index].key);
        _ = local_dedupe_entries.orderedRemove(index);
    }
}

fn resetLocalDedupeState() void {
    lockLocalDedupe();
    defer unlockLocalDedupe();

    for (local_dedupe_entries.items) |entry| {
        std.heap.page_allocator.free(entry.key);
    }
    local_dedupe_entries.clearRetainingCapacity();
}

/// 取得本機去重資料的短臨界區鎖。
fn lockLocalDedupe() void {
    while (!local_dedupe_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

/// 釋放本機去重資料的短臨界區鎖。
fn unlockLocalDedupe() void {
    local_dedupe_mutex.unlock();
}

/// 依序更新所有有設定完成的 DDNS 供應商。
fn updateDdnsServices(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    ip: []const u8,
) !ServiceSummary {
    // 先從 0 開始累計這一輪更新統計。
    var summary = ServiceSummary{};

    // Afraid 要同時滿足：
    // 1. `enabled = true`
    // 2. token 有填值
    //
    // 只要 `enabled = false`，就算 IP 有變化，這輪也不會更新 Afraid。
    if (config.afraid.enabled and config.afraid.token.len != 0) {
        // `attempted += 1` 代表：
        // 我們已經決定這一輪要真的去碰一次 Afraid API。
        summary.attempted += 1;
        // Zig 的 `if (foo()) { ... } else |err| { ... }` 寫法代表：
        // 如果成功就走前面，如果回傳 error 就把 error 綁到 `err`。
        if (updateAfraid(allocator, client, config.afraid)) {
            // Afraid 真的更新成功時，成功數量加 1。
            summary.succeeded += 1;
        } else |err| {
            // 失敗時不讓整輪直接中斷，而是先記錄錯誤。
            std.log.err("afraid update failed: {}", .{err});
        }
    }

    // Dynu 要同時滿足：
    // 1. `enabled = true`
    // 2. username 有值
    // 3. password 有值
    if (config.dyny.enabled and config.dyny.username.len != 0 and config.dyny.password.len != 0) {
        // 因為設定完整，所以這次也把 Dynu 算進「有嘗試」。
        summary.attempted += 1;
        if (updateDynu(allocator, client, config.dyny, ip)) {
            // Dynu 成功就累計成功數。
            summary.succeeded += 1;
        } else |err| {
            // 失敗時只記錄，不中斷其他供應商。
            std.log.err("dynu update failed: {}", .{err});
        }
    }

    // No-IP 要同時滿足：
    // 1. `enabled = true`
    // 2. username / password 都有值
    // 3. 至少有一個 hostname
    if (config.noip.enabled and config.noip.username.len != 0 and config.noip.password.len != 0 and config.noip.hostnames.len != 0) {
        // 這裡同樣代表：No-IP 被納入這輪實際嘗試。
        summary.attempted += 1;
        if (updateNoIp(allocator, client, config.noip, ip)) {
            // 只要整個 No-IP 更新流程成功，就加到成功數。
            summary.succeeded += 1;
        } else |err| {
            // 記錄 No-IP 的失敗原因。
            std.log.err("no-ip update failed: {}", .{err});
        }
    }

    // 把最後統計結果回給呼叫端。
    return summary;
}

/// 呼叫 Afraid.org 的同步 API。
fn updateAfraid(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Afraid,
) !void {
    // 先把 Afraid 更新網址組出來。
    const url = try buildAfraidUrl(allocator, config);
    // 打 HTTP GET。
    const response = try fetchText(allocator, client, url, &.{});
    // 用完 body 後要記得釋放。
    defer allocator.free(response.body);

    // 先確認 HTTP 狀態碼是 2xx。
    try ensureSuccessStatus(response.status, response.body);
    // Afraid 回應如果包含 `Updated`，就把預覽內容打進 log。
    if (std.mem.indexOf(u8, response.body, "Updated") != null) {
        // 這塊 buffer 只是臨時拿來裝 log 預覽文字。
        var preview_buffer: [http_log_body_preview_len]u8 = undefined;
        // `bodyPreviewForLog(...)` 會把太長或有換行的內容整理成較安全的 log 文字。
        std.log.info("afraid response: {s}", .{bodyPreviewForLog(&preview_buffer, response.body)});
    }
}

/// 呼叫 Dynu 的 DDNS API。
fn updateDynu(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Dynu,
    ip: []const u8,
) !void {
    // Dynu 需要把目前 IP 也組進更新網址。
    const url = try buildDynuUrl(allocator, config, ip);
    // 真正把請求送出去。
    const response = try fetchText(allocator, client, url, &.{});
    // 用完 body 之後歸還記憶體。
    defer allocator.free(response.body);

    // 先確保不是 404 / 500 這種 HTTP 層級錯誤。
    try ensureSuccessStatus(response.status, response.body);
    // Dynu 常見成功回應是 `good` 或 `nochg`。
    // 如果不是這兩種，就把它視為非預期內容。
    if (!containsGoodOrNochg(response.body)) {
        return error.UnexpectedDynuResponse;
    }
    // 建一塊暫時 buffer，讓回應內容可以整理後寫進 log。
    var preview_buffer: [http_log_body_preview_len]u8 = undefined;
    std.log.info("dynu response: {s}", .{bodyPreviewForLog(&preview_buffer, response.body)});
}

/// 呼叫 No-IP 的 DDNS API。
fn updateNoIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.NoIp,
    ip: []const u8,
) !void {
    // No-IP 是用 HTTP Basic Auth，所以先把帳密轉成 header 值。
    const auth_value = try buildBasicAuthorization(allocator, config.username, config.password);
    // 把 authorization header 放進固定長度陣列。
    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_value },
    };

    // No-IP 可能一次要更新多個 hostname，所以逐一迴圈。
    for (config.hostnames) |hostname| {
        // 先為這一個 hostname 組出更新網址。
        const url = try buildNoIpUrl(allocator, config, hostname, ip);
        // 再帶著 Basic Auth header 送出請求。
        const response = try fetchText(allocator, client, url, &headers);
        // 每個 hostname 的 response body 用完都要釋放。
        defer allocator.free(response.body);

        // 先確認 HTTP 本身有沒有成功。
        try ensureSuccessStatus(response.status, response.body);
        // No-IP 成功回應也會是 `good` 或 `nochg`。
        if (!containsGoodOrNochg(response.body)) {
            return error.UnexpectedNoIpResponse;
        }
        // 準備 log 用的暫時 buffer。
        var preview_buffer: [http_log_body_preview_len]u8 = undefined;
        std.log.info("no-ip response ({s}): {s}", .{
            hostname,
            bodyPreviewForLog(&preview_buffer, response.body),
        });
    }
}

/// 取得目前外部公網 IP。
fn getPublicIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
) ![]const u8 {
    // 這裡把所有 public IP 來源站集中成一個固定陣列，
    // 之後會依序嘗試。
    const services = [_]PublicIpService{
        .ipify,
        .ipconfig,
        .ipinfo,
        .seeip,
        .myip,
        .bigdatacloud,
    };

    // 記住這次從哪個 index 開始試。
    const start_index = next_public_ip_index;
    // 提前把下一次的起始 index 更新掉，達到輪流換站的效果。
    next_public_ip_index = (next_public_ip_index + 1) % services.len;

    // 如果所有來源站都失敗，就把每個錯誤接起來，最後一次打出。
    var error_text = std.ArrayList(u8).empty;
    // `error_text` 內部可能會長大配置記憶體，所以最後要釋放。
    defer error_text.deinit(allocator);

    // 最多試滿所有來源站一次。
    for (0..services.len) |offset| {
        // `(start_index + offset) % services.len` 可以實作循環往後取值。
        const service = services[(start_index + offset) % services.len];
        // 嘗試用目前這個來源站抓 IP。
        const ip = fetchPublicIpFromService(allocator, client, service) catch |err| {
            // 如果這一站失敗，就把錯誤資訊接到 `error_text` 後面。
            if (error_text.items.len != 0) {
                // 已經有前一個錯誤時，先補分隔符號。
                try error_text.appendSlice(allocator, " | ");
            }
            // 例如會接成：`ipify: error.EmptyPublicIpResponse`
            try error_text.print(allocator, "{s}: {}", .{ serviceName(service), err });
            // 改試下一站。
            continue;
        };
        // 只要有一站成功，就直接回傳。
        return ip;
    }

    // 走到這裡代表全部來源站都失敗。
    std.log.err("failed to get public ip from all services: {s}", .{error_text.items});
    return error.PublicIpLookupFailed;
}

/// 針對單一來源站點抓取 IP。
fn fetchPublicIpFromService(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    service: PublicIpService,
) ![]const u8 {
    // 先從集中管理區塊拿到這個來源站對應的網址。
    const url = publicIpServiceUrl(service);

    // `switch` 會根據來源站種類，決定要打哪個 API 或怎麼解析回應。
    return switch (service) {
        // 這四個站都直接回純文字 IP，所以共用同一個 helper。
        .ipify, .ipconfig, .ipinfo, .seeip => fetchTextIp(allocator, client, url),
        // `myip` 會回 JSON，所以走 JSON 解析 helper。
        .myip => fetchMyIpJson(allocator, client, url),
        // `bigdatacloud` 也回 JSON，但欄位名稱不同，所以另一個 helper。
        .bigdatacloud => fetchBigDataCloudJson(allocator, client, url),
    };
}

/// 把 public IP 來源站 enum 轉成實際要打的網址。
fn publicIpServiceUrl(service: PublicIpService) []const u8 {
    return switch (service) {
        // 每個 enum 值都對應到 `Endpoint.PublicIp` 裡集中管理的網址常數。
        .ipify => Endpoint.PublicIp.ipify,
        .ipconfig => Endpoint.PublicIp.ipconfig,
        .ipinfo => Endpoint.PublicIp.ipinfo,
        .seeip => Endpoint.PublicIp.seeip,
        .myip => Endpoint.PublicIp.myip,
        .bigdatacloud => Endpoint.PublicIp.bigdatacloud,
    };
}

/// 從「直接回純文字 IP」的來源站抓取公網 IP。
fn fetchTextIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
) ![]const u8 {
    // 這類來源站直接回傳純文字 IP，所以只要 GET 之後做基本檢查即可。
    const response = try fetchText(allocator, client, url, &.{});
    // `response.body` 是動態配置出來的字串，用完一定要釋放。
    defer allocator.free(response.body);

    // HTTP 不是 2xx 的話，這裡就會直接回錯。
    try ensureSuccessStatus(response.status, response.body);
    // 把 body 裡可能的空白、換行整理掉，順便驗證這真的是 IP。
    const normalized = try normalizePublicIp(response.body);
    // `normalized` 只是指向 `response.body` 裡的一段 slice。
    // 因為後面會 `free(response.body)`，所以這裡要另外複製一份給呼叫端持有。
    return allocator.dupe(u8, normalized);
}

/// 從 `api.myip.com` 的 JSON 回應中取出公網 IP。
fn fetchMyIpJson(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
) ![]const u8 {
    // 這個來源站回的是 JSON，不是純文字 IP。
    // 真正網址不寫死在這裡，而是由呼叫端從集中管理區塊傳進來。
    const response = try fetchText(allocator, client, url, &.{});
    defer allocator.free(response.body);

    // 先處理 HTTP 層面的成功 / 失敗。
    try ensureSuccessStatus(response.status, response.body);

    // 這個匿名 struct 只描述我們這次真正要用到的欄位。
    const Parsed = struct {
        // `api.myip.com` 的 JSON 會有 `"ip": "1.2.3.4"` 這種欄位。
        ip: []const u8,
    };
    // 用標準庫 JSON parser 把 response body 反序列化。
    const parsed = try std.json.parseFromSlice(Parsed, allocator, response.body, .{
        // 其他欄位像 country / cc 我們目前沒用到，所以忽略它們。
        .ignore_unknown_fields = true,
    });
    // `parsed` 內部也持有記憶體，所以用完要 deinit。
    defer parsed.deinit();

    // 取出 JSON 裡的 `ip` 欄位，再做一次標準化與驗證。
    const normalized = try normalizePublicIp(parsed.value.ip);
    // 同樣複製一份新的字串給呼叫端。
    return allocator.dupe(u8, normalized);
}

/// 從 BigDataCloud 的 JSON 回應中取出公網 IP。
fn fetchBigDataCloudJson(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
) ![]const u8 {
    // 這個來源站也回 JSON。
    // 真正網址同樣由呼叫端從集中管理區塊傳進來。
    const response = try fetchText(allocator, client, url, &.{});
    defer allocator.free(response.body);

    // 先確認 HTTP 請求本身沒失敗。
    try ensureSuccessStatus(response.status, response.body);

    // BigDataCloud 的欄位名稱是 `ipString`。
    const Parsed = struct {
        // 對應 JSON 裡的 `"ipString": "1.2.3.4"`。
        ipString: []const u8,
    };
    // 把 body 反序列化成只含 `ipString` 欄位的 struct。
    const parsed = try std.json.parseFromSlice(Parsed, allocator, response.body, .{
        .ignore_unknown_fields = true,
    });
    // JSON parser 內部配置的記憶體要記得清掉。
    defer parsed.deinit();

    // 把欄位值整理成穩定的 IP 格式。
    const normalized = try normalizePublicIp(parsed.value.ipString);
    // 再複製一份可長期持有的字串回傳出去。
    return allocator.dupe(u8, normalized);
}

/// 將第三方回傳的文字修正成穩定的 IP 格式。
fn normalizePublicIp(text: []const u8) ![]const u8 {
    // 先把前後空白、CRLF 去掉。
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    // 如果清理完是空字串，就代表這份回應不能用。
    if (trimmed.len == 0) return error.EmptyPublicIpResponse;

    // `IpAddress.parse(...)` 拿來驗證這段字串是不是真的像 IPv4 / IPv6。
    _ = std.Io.net.IpAddress.parse(trimmed, 0) catch return error.InvalidPublicIpResponse;
    // 驗證通過後，就把清理好的 slice 回傳。
    return trimmed;
}

/// 確認 HTTP 狀態碼是不是 2xx。
fn ensureSuccessStatus(status: std.http.Status, body: []const u8) !void {
    // `status.class()` 會把 200 / 201 / 204 這種歸到 `.success`。
    if (status.class() != .success) {
        // 非 2xx 時，先準備一小段 body 預覽幫助除錯。
        var preview_buffer: [http_log_body_preview_len]u8 = undefined;
        std.log.err("unexpected http status {d}: {s}", .{
            @intFromEnum(status),
            bodyPreviewForLog(&preview_buffer, body),
        });
        // 再把錯誤往外丟，讓上層知道這次 HTTP 失敗。
        return error.UnexpectedHttpStatus;
    }
}

/// 判斷某個 DDNS 回應內容是否代表成功或「已經是最新」。
fn containsGoodOrNochg(text: []const u8) bool {
    // `good` 表示真的更新成功，`nochg` 表示對方認定已經是最新 IP。
    // 這兩種對我們來說都算成功。
    return std.mem.indexOf(u8, text, "good") != null or
        std.mem.indexOf(u8, text, "nochg") != null;
}

/// 把 enum 值轉成較好讀的站名字串。
fn serviceName(service: PublicIpService) []const u8 {
    return switch (service) {
        // 把 enum 轉成適合寫進 log 的短字串。
        .ipify => "ipify",
        .ipconfig => "ipconfig",
        .ipinfo => "ipinfo",
        .seeip => "seeip",
        .myip => "myip",
        .bigdatacloud => "bigdatacloud",
    };
}

/// 發出單次 GET 請求並把 body 收成字串。
fn fetchText(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    extra_headers: []const std.http.Header,
) !FetchTextResponse {
    // 建立一個空的 ArrayList，稍後讓 HTTP client 把 body 直接寫進去。
    var body = std.ArrayList(u8).empty;
    // 如果中途失敗，才需要在錯誤路徑上清理它。
    errdefer body.deinit(allocator);

    // 把 ArrayList 包成 writer，這樣 `client.fetch(...)` 才知道 body 要寫去哪裡。
    var response_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body);
    errdefer response_writer.deinit();

    // 先組出一份遮罩過敏感值的網址，專門拿來寫 log。
    var log_url_buffer: [http_log_url_buffer_len]u8 = undefined;
    const log_url = urlForLog(&log_url_buffer, url);
    http_log.info("request GET {s}", .{log_url});

    const result = client.fetch(.{
        // 告訴 HTTP client：這次要打的是哪個 URL。
        .location = .{ .url = url },
        // 目前這個 helper 固定只做 GET。
        .method = .GET,
        // 把 response body 寫到前面建立好的 `response_writer`。
        .response_writer = &response_writer.writer,
        // 額外 header 例如 No-IP 的 Basic Auth 也從這裡帶入。
        .extra_headers = extra_headers,
    }) catch |err| {
        // 請求本身失敗時，先寫 error log，再把錯誤往外丟。
        http_log.err("request GET {s} failed: {}", .{ log_url, err });
        return err;
    };

    // `fromArrayList` 之後，資料其實暫時握在 `response_writer` 手上。
    // 要先把 ownership 交回 `body`，`body.items` 才會真的有 HTTP 回應內容。
    body = response_writer.toArrayList();
    // 根據狀態碼和 body 內容寫 response log。
    logHttpResponse(log_url, result.status, body.items);

    // 把 ArrayList 轉成真正屬於呼叫端的 slice。
    return .{
        // 原封不動把 HTTP 狀態碼帶出去。
        .status = result.status,
        // `toOwnedSlice` 會把目前 ArrayList 裡的資料交成一塊獨立字串。
        .body = try body.toOwnedSlice(allocator),
    };
}

/// 根據 status code 與 body 內容寫出一筆 HTTP response 日誌。
fn logHttpResponse(
    log_url: []const u8,
    status: std.http.Status,
    body: []const u8,
) void {
    // 先把 body 整理成適合輸出的短預覽。
    var preview_buffer: [http_log_body_preview_len]u8 = undefined;
    const body_preview = bodyPreviewForLog(&preview_buffer, body);

    // 2xx 當成成功。
    if (status.class() == .success) {
        http_log.info(
            "response GET {s} status={d} bytes={d}",
            .{ log_url, @intFromEnum(status), body.len },
        );
        // body 有內容時，再另外打一筆 debug 級別的 preview。
        if (body_preview.len != 0) {
            http_log.debug("response body GET {s}: {s}", .{ log_url, body_preview });
        }
        // 成功情況寫完就可以結束。
        return;
    }

    // 非 2xx 就當錯誤，一次把狀態碼和 body preview 都記下來。
    http_log.err(
        "response GET {s} status={d} bytes={d} body={s}",
        .{ log_url, @intFromEnum(status), body.len, body_preview },
    );
}

/// 產生適合寫進 log 的網址版本，並把敏感資訊遮掉。
fn urlForLog(buffer: []u8, url: []const u8) []const u8 {
    // 如果網址長到超過 buffer，就回一個固定提示字串。
    if (url.len > buffer.len) return "<http-url-too-long>";

    // 先把原始網址複製到可修改的 buffer。
    @memcpy(buffer[0..url.len], url);
    const output = buffer[0..url.len];

    // 依序遮掉 query string 或 path 裡的敏感欄位。
    maskQueryValue(output, "username");
    maskQueryValue(output, "password");
    maskQueryValue(output, "token");
    maskQueryTailAfterPrefix(output, "/dynamic/update.php?");
    // 回傳的是「已遮罩」版本，不是原始網址。
    return output;
}

/// 遮掉 query string 裡像 `password=...` 這種值。
fn maskQueryValue(text: []u8, key: []const u8) void {
    // `start_index` 表示：下一次從哪個位置開始往後找。
    var start_index: usize = 0;

    // 從 `start_index` 開始找下一個 `key` 出現位置。
    while (std.mem.indexOfPos(u8, text, start_index, key)) |key_index| {
        const equals_index = key_index + key.len;
        // 後面不是 `=` 的話，就不是 `key=value` 格式。
        if (equals_index >= text.len or text[equals_index] != '=') {
            start_index = equals_index;
            continue;
        }

        // 確保前一個字元是 `?` 或 `&`，避免誤遮到其他地方的同名片段。
        if (key_index != 0 and text[key_index - 1] != '?' and text[key_index - 1] != '&') {
            start_index = equals_index;
            continue;
        }

        // 從 `=` 後面一路找到下一個 `&` 或 `#`。
        var value_end = equals_index + 1;
        while (value_end < text.len and text[value_end] != '&' and text[value_end] != '#') : (value_end += 1) {}

        // 把真正的值改成 `*`。
        maskSlice(text[equals_index + 1 .. value_end]);
        // 下次從這次 value 的結尾往後繼續找。
        start_index = value_end;
    }
}

/// 遮掉像 `/dynamic/update.php?<token>` 這種 query 尾端 token。
fn maskQueryTailAfterPrefix(text: []u8, prefix: []const u8) void {
    const prefix_index = std.mem.indexOf(u8, text, prefix) orelse return;
    const value_start = prefix_index + prefix.len;
    var value_end = value_start;

    while (value_end < text.len and text[value_end] != '&' and text[value_end] != '#') : (value_end += 1) {}
    maskSlice(text[value_start..value_end]);
}

/// 把一段字串原地改成 `*****`。
fn maskSlice(text: []u8) void {
    // `|*char|` 表示我們拿到的是可寫入的字元指標。
    for (text) |*char| {
        // `char.*` 代表「把指標指到的那個字元改掉」。
        char.* = '*';
    }
}

/// 把 HTTP body 整理成一段短字串，適合寫進 log。
fn bodyPreviewForLog(buffer: []u8, body: []const u8) []const u8 {
    // buffer 長度如果是 0，就不可能產生預覽。
    if (buffer.len == 0) return "";

    // 如果 body 比 buffer 還長，就代表最後需要截斷。
    const needs_ellipsis = body.len > buffer.len;
    // 如果需要在尾端補 `...`，就先預留三個位置。
    const preview_limit = if (needs_ellipsis and buffer.len >= 3) buffer.len - 3 else buffer.len;

    // `out_index` 指向目前已經寫到 buffer 的哪個位置。
    var out_index: usize = 0;
    // `body_index` 指向目前正在讀原始 body 的哪個位置。
    var body_index: usize = 0;
    // 逐字掃描 body，把適合顯示的內容複製到 buffer。
    while (body_index < body.len and out_index < preview_limit) : (body_index += 1) {
        const char = body[body_index];
        // 把 CRLF / tab 改成空白，非可列印字元改成 `?`。
        buffer[out_index] = switch (char) {
            '\r', '\n', '\t' => ' ',
            else => if (std.ascii.isPrint(char)) char else '?',
        };
        // 每寫入一個字元，就把輸出位置往後推一格。
        out_index += 1;
    }

    // 移掉尾端多餘空白。
    while (out_index > 0 and buffer[out_index - 1] == ' ') {
        out_index -= 1;
    }

    // 如果有截斷，就在尾端補 `...`。
    if (needs_ellipsis and buffer.len >= 3) {
        buffer[out_index..][0] = '.';
        buffer[out_index..][1] = '.';
        buffer[out_index..][2] = '.';
        // 三個點都算新寫進去的字元。
        out_index += 3;
    }

    // 最後只回傳目前真的有寫入內容的那一段。
    return buffer[0..out_index];
}

/// 依照設定組出 Afraid 的同步網址。
fn buildAfraidUrl(
    allocator: std.mem.Allocator,
    config: config_mod.Afraid,
) ![]u8 {
    // 先拿出設定裡的 base URL。
    var prefix = config.url;
    // 如果尾端有多個 `/`，先修掉，避免最後網址變成 `//dynamic/...`。
    while (prefix.len != 0 and prefix[prefix.len - 1] == '/') {
        prefix = prefix[0 .. prefix.len - 1];
    }

    return std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ prefix, config.path, config.token },
    );
}

/// 依照設定組出 Dynu 的更新網址。
///
/// 注意密碼不會以明文送出，而是先做 SHA-256。
fn buildDynuUrl(
    allocator: std.mem.Allocator,
    config: config_mod.Dynu,
    ip: []const u8,
) ![]u8 {
    // Rust 版是把密碼先做 SHA-256，再把雜湊值送給 Dynu。
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    // 這一行真的做 SHA-256 計算。
    std.crypto.hash.sha2.Sha256.hash(config.password, &digest, .{});
    // 把 bytes 轉成 16 進位小寫字串。
    const password_hex = std.fmt.bytesToHex(digest, .lower);

    var prefix = config.url;
    // 如果設定值尾端多帶了 `/`，先修掉，避免 query string 前面變成 `/?...`。
    while (prefix.len != 0 and prefix[prefix.len - 1] == '/') {
        prefix = prefix[0 .. prefix.len - 1];
    }

    return std.fmt.allocPrint(
        allocator,
        "{s}?username={s}&password={s}&myip={s}",
        // 這裡會把 base URL、username、雜湊後密碼、目前 IP 拼成完整網址。
        .{ prefix, config.username, &password_hex, ip },
    );
}

/// 依照 hostname 與 IP 組出 No-IP 的更新網址。
fn buildNoIpUrl(
    allocator: std.mem.Allocator,
    config: config_mod.NoIp,
    hostname: []const u8,
    ip: []const u8,
) ![]u8 {
    var prefix = config.url;
    // 如果設定值尾端多帶了 `/`，也先修掉。
    while (prefix.len != 0 and prefix[prefix.len - 1] == '/') {
        prefix = prefix[0 .. prefix.len - 1];
    }

    // No-IP 把 hostname 與 myip 放在 query string。
    return std.fmt.allocPrint(
        allocator,
        "{s}?hostname={s}&myip={s}",
        // 這三個值依序就是：base URL、主機名稱、目前 IP。
        .{ prefix, hostname, ip },
    );
}

/// 把帳號密碼轉成 HTTP Basic Authorization header 值。
fn buildBasicAuthorization(
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
) ![]u8 {
    // HTTP Basic Auth 的原始格式是 `username:password`。
    const raw = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    // `raw` 是一塊新的動態字串，用完要釋放。
    defer allocator.free(raw);

    // 算出 base64 編碼後會需要多少空間。
    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    // 配出一塊剛好夠放 base64 結果的記憶體。
    const encoded = try allocator.alloc(u8, encoded_len);
    // `encoded` 只是中間結果，最後組完 header 就不需要了。
    defer allocator.free(encoded);

    // 真的做 base64 編碼。
    _ = std.base64.standard.Encoder.encode(encoded, raw);
    // 最後補上 `Basic ` 前綴，變成標準 Authorization header 值。
    return std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
}

/// 判斷是否落在 Rust 版原本會略過的凌晨維護時段。
fn shouldSkipMaintenanceWindow() bool {
    // Windows 沒有 `localtime_r`，所以改走 Win32 API `GetLocalTime`。
    if (builtin.os.tag == .windows) {
        var local_time: win.SYSTEMTIME = undefined;
        // 把目前本地時間寫進 `local_time`。
        win.GetLocalTime(&local_time);
        // 再把時、分丟給共用 helper 判斷。
        return shouldSkipMaintenanceWindowAt(local_time.wHour, local_time.wMinute);
    } else {
        // 非 Windows 走 POSIX 的 `localtime_r`。
        // 先取得現在的 Unix 秒數。
        var now: c.time_t = c.time(null);
        // 再準備一個 `tm` 結構來接「拆開後的本地時間」。
        var local_tm: c.struct_tm = undefined;
        // `orelse return false` 代表：如果 `localtime_r` 失敗，就乾脆不要略過。
        _ = c.localtime_r(&now, &local_tm) orelse return false;
        return shouldSkipMaintenanceWindowAt(local_tm.tm_hour, local_tm.tm_min);
    }
}

/// 真正的規則很單純：
/// 只要時間落在 02:00 到 02:04，就略過。
fn shouldSkipMaintenanceWindowAt(hour: c_int, minute: c_int) bool {
    return hour == 2 and minute >= 0 and minute < 5;
}

test "normalize public ip trims and validates ipv4" {
    // 測純文字 IP 前後夾了空白與換行時，仍能被清成乾淨格式。
    const normalized = try normalizePublicIp(" 1.2.3.4\r\n");
    try std.testing.expectEqualStrings("1.2.3.4", normalized);
}

test "normalize public ip accepts ipv6" {
    // 也要接受 IPv6。
    const normalized = try normalizePublicIp("2001:db8::1");
    try std.testing.expectEqualStrings("2001:db8::1", normalized);
}

test "maintenance window helper matches rust behavior" {
    // 這個測試確認凌晨 2:00 到 2:04 都會被略過。
    try std.testing.expect(shouldSkipMaintenanceWindowAt(2, 0));
    try std.testing.expect(shouldSkipMaintenanceWindowAt(2, 4));
    try std.testing.expect(!shouldSkipMaintenanceWindowAt(2, 5));
    try std.testing.expect(!shouldSkipMaintenanceWindowAt(1, 59));
}

test "dynu url hashes password before sending" {
    const allocator = std.testing.allocator;
    // 把 demo 帳密與 IP 組成 Dynu 更新網址。
    const url = try buildDynuUrl(
        allocator,
        .{ .username = "demo", .password = "secret" },
        "1.2.3.4",
    );
    // 測試結束時把暫時字串釋放掉。
    defer allocator.free(url);

    // 檢查 username 與 IP 都有出現在網址裡。
    try std.testing.expect(std.mem.indexOf(u8, url, "username=demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "myip=1.2.3.4") != null);
    // 檢查送出去的是 SHA-256 後的密碼，不是原文。
    try std.testing.expect(std.mem.indexOf(u8, url, "password=2bb80d537b1da3e38bd30361aa855686") != null);
}

test "basic authorization header starts with basic" {
    const allocator = std.testing.allocator;
    // Basic Auth 的 header 一定要以 `Basic ` 開頭。
    const value = try buildBasicAuthorization(allocator, "user", "pass");
    // 這個 header 字串也是動態配置的。
    defer allocator.free(value);

    try std.testing.expect(std.mem.startsWith(u8, value, "Basic "));
}

test "url for log masks afraid token and dynu password" {
    // 先測 Afraid 新語法 query token 是否會被遮掉。
    var afraid_buffer: [http_log_url_buffer_len]u8 = undefined;
    const afraid_url = urlForLog(&afraid_buffer, "https://freedns.afraid.org/dynamic/update.php?secret-token");
    try std.testing.expectEqualStrings("https://freedns.afraid.org/dynamic/update.php?************", afraid_url);

    // 再測 Dynu query string 裡的帳密是否會被遮掉。
    var dynu_buffer: [http_log_url_buffer_len]u8 = undefined;
    const dynu_url = urlForLog(
        &dynu_buffer,
        "https://api.dynu.com/nic/update?username=demo&password=abcdef&myip=1.2.3.4",
    );
    try std.testing.expectEqualStrings(
        "https://api.dynu.com/nic/update?username=****&password=******&myip=1.2.3.4",
        dynu_url,
    );
}

test "build afraid url supports new freedns syntax" {
    const allocator = std.testing.allocator;
    const url = try buildAfraidUrl(
        allocator,
        .{
            .url = "https://freedns.afraid.org",
            .path = "/dynamic/update.php?",
            .token = "demo-token",
        },
    );
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://freedns.afraid.org/dynamic/update.php?demo-token",
        url,
    );
}

test "body preview for log removes line breaks" {
    // 預覽內容不應該把原本的 CRLF 直接帶進 log。
    var buffer: [32]u8 = undefined;
    const preview = bodyPreviewForLog(&buffer, "nochg 1.2.3.4\r\n");
    try std.testing.expectEqualStrings("nochg 1.2.3.4", preview);
}

test "public ip cache key matches rust format" {
    const allocator = std.testing.allocator;
    // Redis 去重 key 必須和 Rust 版完全同格式，才能沿用同一套資料。
    const key = try buildPublicIpCacheKey(allocator, "1.2.3.4");
    // 記得釋放 `allocPrint(...)` 配出的字串。
    defer allocator.free(key);

    try std.testing.expectEqualStrings("MyPublicIP:1.2.3.4", key);
}

test "current public ip redis key matches expected format" {
    try std.testing.expectEqualStrings("MyPublicIP", currentPublicIpRedisKey());
}

test "local dedupe cache respects ttl" {
    resetLocalDedupeState();
    defer resetLocalDedupeState();

    try std.testing.expect(!localDedupeContainsAt("MyPublicIP:1.2.3.4", 100));
    try localDedupeSetAt("MyPublicIP:1.2.3.4", 60, 100);
    try std.testing.expect(localDedupeContainsAt("MyPublicIP:1.2.3.4", 120));
    try std.testing.expect(!localDedupeContainsAt("MyPublicIP:1.2.3.4", 160));
}
