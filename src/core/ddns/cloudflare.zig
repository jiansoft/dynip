//! Cloudflare DNS API provider.
//!
//! 這個模組只負責 Cloudflare HTTP/JSON 協定；排程、Redis retry 與 dashboard
//! 仍由 ddns.zig 協調。輸入一個驗證過的 IP 後，會更新對應的 A 或 AAAA record。

const std = @import("std");
const config_mod = @import("../../base/config.zig");
const http = @import("../../io/http.zig");
const c = @import("c");

/// Cloudflare REST API 固定根網址。
const api_base_url = "https://api.cloudflare.com/client/v4";

/// Cloudflare record 的中繼資料通常比排程更新間隔穩定得多。
/// 使用短時間快取能減少 API 呼叫，同時仍能在合理時間內發現人工 DNS 修改。
const record_cache_ttl_seconds: i64 = 60;

/// 一筆已存在 record 的快取。所有 slice 都由 `cache_allocator` 擁有並存活到行程結束；
/// 設定的 DDNS record 數量通常很少，因此以設定數量為上限的簡單快取已足夠。
const CachedRecord = struct {
    key: []u8,
    id: []u8,
    content: []u8,
    expires_at: i64,
};

/// 排程工作可能呼叫 Cloudflare provider，同時 dashboard 會讀取 snapshot。
/// 若未來 refresh 改為並行執行，這把 mutex 仍可讓快取讀寫保持安全。
/// 用 `std.Io.Mutex` 而不是 `std.atomic.Mutex`：後者只有 `tryLock`，當通用鎖用就得
/// 自己寫 `while (!tryLock()) yield()` 的忙等迴圈。`std.Io.Mutex.lock` 走 futex，
/// 等不到鎖的執行緒會真的睡著，由 unlock 喚醒。
var record_cache_mutex: std.Io.Mutex = .init;
var record_cache: std.ArrayList(CachedRecord) = .empty;

/// 快取自有資料使用的 allocator。
///
/// 先前用 `std.heap.page_allocator` 配置 record id / content 這類幾十位元組的字串，
/// 每筆至少佔一整個 page。`smp_allocator` 是 thread-safe 的通用 allocator，
/// 適合這種「長壽命行程、小配置、多執行緒」的用途。
const cache_allocator = std.heap.smp_allocator;

/// DNS record 對應的位址家族。
pub const IpFamily = enum {
    /// IPv4 對應 Cloudflare A record。
    ipv4,
    /// IPv6 對應 Cloudflare AAAA record。
    ipv6,
};

/// 從已驗證的 IP 字串判斷 IPv4 或 IPv6。
pub fn familyForIp(ip: []const u8) !IpFamily {
    return switch (try std.Io.net.IpAddress.parse(ip, 0)) {
        .ip4 => .ipv4,
        .ip6 => .ipv6,
    };
}

/// 將 IP family 轉換成 Cloudflare DNS record type。
pub fn recordType(family: IpFamily) []const u8 {
    return switch (family) {
        .ipv4 => "A",
        .ipv6 => "AAAA",
    };
}

/// Cloudflare response 的共用 envelope。實際資料放在 result。
fn Envelope(comptime Result: type) type {
    return struct {
        success: bool,
        result: Result,
        errors: []const ApiError = &.{},
    };
}

/// API 錯誤中可供人類閱讀的最小欄位。
const ApiError = struct {
    code: u32 = 0,
    message: []const u8 = "",
};

/// 查詢既有 DNS record 時需要的最小資料。
const Record = struct {
    id: []const u8,
    content: []const u8,
    /// Cloudflare record comment 是 ownership selector 的依據；舊 record 沒有 comment 時
    /// API 可能省略欄位，因此提供空字串預設值。
    comment: []const u8 = "",
};

/// POST 建立 DNS record 的 JSON request body。
const CreateBody = struct {
    type: []const u8,
    name: []const u8,
    content: []const u8,
    proxied: bool,
    ttl: u32,
    comment: []const u8,
};

/// PATCH 時只修改 content，避免覆蓋既有 record 的 proxy、TTL、comment。
const PatchBody = struct {
    content: []const u8,
};

/// 更新設定中全部 hostname 的 A 或 AAAA record。
///
/// allocator 預期是單次 refresh 的 Arena allocator，因此所有 JSON、URL、Bearer
/// header 的暫存配置都會隨 refresh 結束一次釋放。
pub fn update(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Cloudflare,
    ip: []const u8,
) !void {
    if (config.api_token.len == 0) return error.MissingCloudflareApiToken;
    if (config.zone_id.len == 0) return error.MissingCloudflareZoneId;
    if (config.hostnames.len == 0) return error.MissingCloudflareHostnames;

    const family = try familyForIp(ip);
    for (config.hostnames) |hostname| {
        if (hostname.len == 0) return error.InvalidCloudflareHostname;
        try updateOne(allocator, client, config, hostname, ip, family);
    }
}

/// 對一個 hostname 執行 list、比較、PATCH 或 POST 的收斂流程。
fn updateOne(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Cloudflare,
    hostname: []const u8,
    ip: []const u8,
    family: IpFamily,
) !void {
    const existing = try findRecord(allocator, client, config, hostname, family);
    if (existing) |record| {
        if (std.mem.eql(u8, record.content, ip)) return;
        return patchRecord(allocator, client, config, record.id, ip);
    }
    return createRecord(allocator, client, config, hostname, ip, family);
}

/// 查詢同名同型別的 record；null 表示 API 成功但 record 不存在。
fn findRecord(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Cloudflare,
    hostname: []const u8,
    family: IpFamily,
) !?Record {
    const cache_key = try makeCacheKey(allocator, config.zone_id, hostname, family);
    if (cacheLookup(client.io, cache_key)) |cached| return cached;

    const url = try listRecordUrl(allocator, config.zone_id, hostname, family);
    const response = try send(allocator, client, url, config.api_token, .GET, null, config.http_retry_count);
    defer allocator.free(response.body);
    try http.ensureSuccessStatus(response.status, response.body);

    const parsed = try std.json.parseFromSliceLeaky(Envelope([]Record), allocator, response.body, .{
        .ignore_unknown_fields = true,
    });
    if (!parsed.success) return reportApiFailure(parsed.errors);
    const record = try selectManagedRecord(parsed.result, config.managed_record_comment);
    if (record == null) return null;
    cacheStore(client.io, cache_key, record.?);
    return record;
}

/// 從同名同型別的 Cloudflare 回應中選出「本 instance 擁有」的唯一 record。
///
/// selector 空字串是相容模式，接受無 comment 的舊設定；若有兩筆以上同樣可管理，
/// 寧可停止並交給操作者清理，也絕不任意更新 API 回傳的第一筆。
fn selectManagedRecord(records: []const Record, selector: []const u8) !?Record {
    var selected: ?Record = null;
    for (records) |record| {
        if (selector.len != 0 and !std.mem.eql(u8, record.comment, selector)) continue;
        if (selected != null) return error.MultipleManagedCloudflareRecords;
        selected = record;
    }
    return selected;
}

/// 使用 PATCH 只變更 IP，保留 Cloudflare 端原有的非 IP 設定。
fn patchRecord(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Cloudflare,
    record_id: []const u8,
    ip: []const u8,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/zones/{s}/dns_records/{s}", .{
        api_base_url, config.zone_id, record_id,
    });
    const response = try sendJson(allocator, client, url, config.api_token, .PATCH, PatchBody{ .content = ip }, config.http_retry_count);
    defer allocator.free(response.body);
    try ensureSuccessfulResponse(allocator, response);
    cacheUpdateContent(client.io, record_id, ip);
}

/// 建立不易碰撞的行程內快取 key。必須包含 zone ID 與 record type，
/// 因為同一 hostname 合法情況下可同時擁有彼此獨立的 A 與 AAAA record。
fn makeCacheKey(allocator: std.mem.Allocator, zone_id: []const u8, hostname: []const u8, family: IpFamily) ![]u8 {
    // `std.fmt.allocPrint` 會依格式字串組出一個全新的文字 key，並用傳入的
    // `allocator` 配置記憶體；函式成功後回傳的 `[]u8` 由呼叫端的 allocator 擁有。
    // 本模組的呼叫端使用單輪 refresh 的 Arena allocator，所以 refresh 結束時
    // 這個暫存 key 會自動釋放，不需要在每個 return 分支手動 free。
    //
    // 格式 `"{s}|{s}|{s}"` 有三個 `{s}`：`{s}` 的意思是把對應參數當 UTF-8
    // 字串 slice 寫入；中間的 `|` 是刻意選用的分隔符，讓三段資料不會黏在一起。
    // 例如 zone_id=`zone-a`、family=`ipv6`、hostname=`home.example.com`，最後會是：
    // `zone-a|AAAA|home.example.com`。
    //
    // 三個欄位缺一不可：同 hostname 可以在不同 zone 存在，也可以同時有 A 和
    // AAAA record。把 zone、record type、hostname 全放進 key，才能確保它們各自
    // 使用獨立的 cache entry，不會把 IPv4 的 record ID/content 誤拿給 IPv6 使用。
    return std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ zone_id, recordType(family), hostname });
}

/// 建立 DNS record List API URL。分離成純函式，讓 query encoding 與 A/AAAA
/// 選擇可在不發網路請求的情況下驗證。
fn listRecordUrl(allocator: std.mem.Allocator, zone_id: []const u8, hostname: []const u8, family: IpFamily) ![]u8 {
    // Hostname 會出現在 query string；例如 wildcard `*` 不能直接放入 URL，
    // 必須先 percent-encode，否則 Cloudflare 可能收到不同的搜尋條件。
    const name = try encodeQueryValue(allocator, hostname);
    // `recordType(family)` 把內部 enum 轉成 Cloudflare API 要的 "A" / "AAAA"。
    // allocPrint 的結果由傳入 allocator 擁有，findRecord 的 arena 結束時會一起釋放。
    return std.fmt.allocPrint(
        allocator,
        "{s}/zones/{s}/dns_records?type={s}&name={s}",
        .{ api_base_url, zone_id, recordType(family), name },
    );
}

/// 回傳未過期項目的值複本。回傳 slice 屬於行程快取，呼叫端不可釋放它們。
fn cacheLookup(io: std.Io, key: []const u8) ?Record {
    // 新增項目時 ArrayList 可能重新配置記憶體，因此讀寫都必須取得同一把鎖。
    // 回傳的 Record 是小型值複本，內含由 `cache_allocator` 擁有的穩定 slice；
    // 鎖釋放後它仍然有效。
    record_cache_mutex.lockUncancelable(io);
    defer record_cache_mutex.unlock(io);
    // 快取策略刻意採粗粒度的 60 秒，因此 Unix 秒已足夠。
    const now: i64 = @intCast(c.time(null));
    for (record_cache.items) |entry| {
        // 此處忽略而不刪除過期項目，讓讀取操作不需要配置或搬移 ArrayList。
        // 下一次成功 API 查詢會由 cacheStore 直接取代該項目。
        if (entry.expires_at > now and std.mem.eql(u8, entry.key, key)) {
            return .{ .id = entry.id, .content = entry.content };
        }
    }
    return null;
}

/// 新增或取代既有 record 快取項目。必須由 `cache_allocator` 複製資料，
/// 因為 JSON 回應記憶體屬於呼叫端 arena，refresh 結束後就會消失。
fn cacheStore(io: std.Io, key: []const u8, record: Record) void {
    // JSON parser 產生的 slice 借用 refresh arena。一定要複製到 `cache_allocator`，
    // 因為 arena 會在 refresh 後 deinit，而快取的生命週期比它長。
    record_cache_mutex.lockUncancelable(io);
    defer record_cache_mutex.unlock(io);
    const allocator = cache_allocator;
    const now: i64 = @intCast(c.time(null));
    for (record_cache.items) |*entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;
        // 這是更新既有快取項目。保留 key 的配置，但替換新 Cloudflare 回應帶回的兩個欄位。
        allocator.free(entry.id);
        allocator.free(entry.content);
        entry.id = allocator.dupe(u8, record.id) catch return;
        entry.content = allocator.dupe(u8, record.content) catch return;
        entry.expires_at = now + record_cache_ttl_seconds;
        return;
    }
    // 沒有相符 key 時新增一筆自有項目。個別配置失敗只代表不快取；
    // 呼叫端仍會使用剛取得的 API 回應，因此不影響 DNS 更新正確性。
    record_cache.append(allocator, .{
        .key = allocator.dupe(u8, key) catch return,
        .id = allocator.dupe(u8, record.id) catch return,
        .content = allocator.dupe(u8, record.content) catch return,
        .expires_at = now + record_cache_ttl_seconds,
    }) catch {};
}

/// PATCH 以 record ID 識別目標，所以成功後更新同 ID 的全部快取項目。
/// 這可避免下一輪 refresh 拿舊 content 比較後，發出不必要的第二次 PATCH。
fn cacheUpdateContent(io: std.Io, record_id: []const u8, content: []const u8) void {
    // 呼叫此函式前 PATCH 已成功；更新快取值可避免下次排程以舊 IP content 比較，
    // 進而重複發送 PATCH。
    record_cache_mutex.lockUncancelable(io);
    defer record_cache_mutex.unlock(io);
    const allocator = cache_allocator;
    const now: i64 = @intCast(c.time(null));
    for (record_cache.items) |*entry| {
        if (!std.mem.eql(u8, entry.id, record_id)) continue;
        const replacement = allocator.dupe(u8, content) catch return;
        allocator.free(entry.content);
        entry.content = replacement;
        entry.expires_at = now + record_cache_ttl_seconds;
    }
}

/// 建立不存在的 record；只在建立時套用設定的 proxied 和 ttl。
fn createRecord(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Cloudflare,
    hostname: []const u8,
    ip: []const u8,
    family: IpFamily,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/zones/{s}/dns_records", .{ api_base_url, config.zone_id });
    const response = try sendJson(allocator, client, url, config.api_token, .POST, CreateBody{
        .type = recordType(family),
        .name = hostname,
        .content = ip,
        .proxied = config.proxied,
        .ttl = config.ttl,
        .comment = config.record_comment,
    }, config.http_retry_count);
    defer allocator.free(response.body);
    try ensureSuccessfulResponse(allocator, response);
}

/// 建立 Bearer header 後送出無 JSON body 的 Cloudflare request。
fn send(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    token: []const u8,
    method: std.http.Method,
    body: ?[]const u8,
    retry_count: u32,
) !http.FetchTextResponse {
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    const headers = [_]std.http.Header{.{ .name = "authorization", .value = bearer }};
    var retries_used: u32 = 0;
    while (true) {
        const response = http.requestText(allocator, client, url, .{
            .method = method,
            .body = body,
            .headers = .{ .privileged_headers = &headers },
        }) catch |err| {
            if (retries_used >= retry_count) return err;
            retries_used += 1;
            try waitBeforeRetry(client, retries_used);
            continue;
        };
        if (!isTransientStatus(response.status) or retries_used >= retry_count) return response;
        allocator.free(response.body);
        retries_used += 1;
        try waitBeforeRetry(client, retries_used);
    }
}

/// 將 Zig struct 序列化為 JSON，並加上 Cloudflare Bearer header。
fn sendJson(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    token: []const u8,
    method: std.http.Method,
    value: anytype,
    retry_count: u32,
) !http.FetchTextResponse {
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    const headers = [_]std.http.Header{.{ .name = "authorization", .value = bearer }};
    var retries_used: u32 = 0;
    while (true) {
        const response = http.requestJson(allocator, client, url, value, .{
            .request = .{ .method = method, .headers = .{ .privileged_headers = &headers } },
        }) catch |err| {
            if (retries_used >= retry_count) return err;
            retries_used += 1;
            try waitBeforeRetry(client, retries_used);
            continue;
        };
        if (!isTransientStatus(response.status) or retries_used >= retry_count) return response;
        allocator.free(response.body);
        retries_used += 1;
        try waitBeforeRetry(client, retries_used);
    }
}

/// 只有 Cloudflare rate limit（429）與 server error（5xx）可安全立即重試。
fn isTransientStatus(status: std.http.Status) bool {
    const code = @backingInt(status);
    return code == 429 or (code >= 500 and code < 600);
}

/// 指數退避：第 1 次等待 250ms、第 2 次 500ms，最大 4 秒。
/// `std.Io` 的 sleep 讓這個等待可沿用目前 runtime，而不是自行阻塞 OS thread。
fn waitBeforeRetry(client: *std.http.Client, retries_used: u32) !void {
    const shift = @min(retries_used - 1, 4);
    const milliseconds: i64 = 250 * (@as(i64, 1) << @intCast(shift));
    std.log.warn("retrying transient cloudflare api failure: attempt={d}, wait_ms={d}", .{ retries_used, milliseconds });
    try client.io.sleep(.fromMilliseconds(milliseconds), .awake);
}

/// HTTP 2xx 仍可能包含 success=false；兩個層級都必須驗證。
fn ensureSuccessfulResponse(allocator: std.mem.Allocator, response: http.FetchTextResponse) !void {
    try http.ensureSuccessStatus(response.status, response.body);
    const parsed = try std.json.parseFromSliceLeaky(Envelope(std.json.Value), allocator, response.body, .{
        .ignore_unknown_fields = true,
    });
    if (!parsed.success) return reportApiFailure(parsed.errors);
}

/// 將 Cloudflare API 的細節記錄到 log，並回傳統一錯誤給 retry 層。
fn reportApiFailure(errors: []const ApiError) anyerror {
    if (errors.len != 0) std.log.err("cloudflare api error: code={d}, message={s}", .{ errors[0].code, errors[0].message });
    return error.CloudflareApiFailed;
}

/// URL query value 的最小 percent encoder，避免 hostname 的 wildcard 等字元破壞 URL。
fn encodeQueryValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            var escaped: [3]u8 = undefined;
            _ = try std.fmt.bufPrint(&escaped, "%{X:0>2}", .{byte});
            try output.appendSlice(allocator, &escaped);
        }
    }
    return output.toOwnedSlice(allocator);
}

test "cloudflare list request targets the selected record family" {
    const allocator = std.testing.allocator;
    const url = try listRecordUrl(allocator, "zone", "*.example.com", .ipv6);
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://api.cloudflare.com/client/v4/zones/zone/dns_records?type=AAAA&name=%2A.example.com",
        url,
    );
}

test "cloudflare patch body changes only record content" {
    // ArrayList + allocating writer 模擬真正 requestJson 序列化前的輸出位置。
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    defer writer.deinit();
    // PATCH body 只應有 content；TTL/proxied 等既有設定要由 Cloudflare 保留。
    try std.json.Stringify.value(PatchBody{ .content = "2001:db8::1" }, .{}, &writer.writer);
    buffer = writer.toArrayList();
    try std.testing.expectEqualStrings("{\"content\":\"2001:db8::1\"}", buffer.items);
}

test "cloudflare post body creates an A record with configured options" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    defer writer.deinit();
    try std.json.Stringify.value(CreateBody{
        .type = recordType(.ipv4),
        .name = "home.example.com",
        .content = "1.2.3.4",
        .proxied = true,
        .ttl = 120,
        .comment = "managed-by:dynip",
    }, .{}, &writer.writer);
    buffer = writer.toArrayList();
    try std.testing.expectEqualStrings("{\"type\":\"A\",\"name\":\"home.example.com\",\"content\":\"1.2.3.4\",\"proxied\":true,\"ttl\":120,\"comment\":\"managed-by:dynip\"}", buffer.items);
}

test "cloudflare ownership selector only returns the tagged record" {
    const records = [_]Record{
        .{ .id = "foreign", .content = "203.0.113.1", .comment = "managed-by:other" },
        .{ .id = "ours", .content = "203.0.113.2", .comment = "managed-by:dynip" },
    };
    const selected = (try selectManagedRecord(&records, "managed-by:dynip")).?;
    try std.testing.expectEqualStrings("ours", selected.id);
}

test "cloudflare ownership selector refuses ambiguous records" {
    const records = [_]Record{
        .{ .id = "one", .content = "203.0.113.1", .comment = "managed-by:dynip" },
        .{ .id = "two", .content = "203.0.113.2", .comment = "managed-by:dynip" },
    };
    try std.testing.expectError(error.MultipleManagedCloudflareRecords, selectManagedRecord(&records, "managed-by:dynip"));
}

test "cloudflare retries only rate limits and server errors" {
    try std.testing.expect(isTransientStatus(@fromBackingInt(@intCast(429))));
    try std.testing.expect(isTransientStatus(@fromBackingInt(@intCast(503))));
    try std.testing.expect(!isTransientStatus(.bad_request));
}

test "cloudflare record cache ttl expires at its boundary" {
    // 快取判斷使用嚴格大於 (`expires_at > now`)；剛好等於 expires_at 就要重新 List。
    const created_at: i64 = 100;
    try std.testing.expect(created_at + record_cache_ttl_seconds > 159);
    try std.testing.expect(!(created_at + record_cache_ttl_seconds > 160));
}
