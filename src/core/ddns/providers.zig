//! 各 DDNS 廠商的 HTTP 協定細節。協調、重試與 Redis 狀態不在本檔處理。
const std = @import("std");
const config_mod = @import("../../base/config.zig");
const http = @import("../../io/http.zig");
const utils = @import("utils.zig");

/// 每一個供應商 HTTP 連線最多等待五秒，避免單一服務卡住整個排程。
const ddns_connect_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(5),
    .clock = .awake,
} };
/// 記錄回應時使用的固定 preview 長度，避免將敏感或超大 body 寫入 log。
const http_log_body_preview_len = http.body_preview_len;

/// 呼叫 FreeDNS/Afraid 更新 URL，並驗證其文字回應確實代表更新或 IP 未變。
/// url 由本函式配置；HTTP helper 消費 URL 的期間內有效，回傳後由 arena/呼叫端回收。
pub fn updateAfraid(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Afraid,
) !void {
    const url = try buildAfraidUrl(allocator, config);
    const response = try http.fetchText(allocator, client, url, &.{}, .{
        .connect_timeout = ddns_connect_timeout,
    });
    defer allocator.free(response.body);

    try http.ensureSuccessStatus(response.status, response.body);
    if (!containsExpectedAfraidResponse(response.body)) {
        return error.UnexpectedAfraidResponse;
    }
    var preview_buffer: [http_log_body_preview_len]u8 = undefined;
    std.log.debug("afraid response: {s}", .{http.bodyPreviewForLog(&preview_buffer, response.body)});
}

/// 呼叫 Dynu 更新 API。密碼在 URL 建立時會先 SHA-256 雜湊，不會以明文傳送。
pub fn updateDynu(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Dynu,
    ip: []const u8,
) !void {
    const url = try buildDynuUrl(allocator, config, ip);
    const response = try http.fetchText(allocator, client, url, &.{}, .{
        .connect_timeout = ddns_connect_timeout,
    });
    defer allocator.free(response.body);

    try http.ensureSuccessStatus(response.status, response.body);
    if (!containsGoodOrNochg(response.body)) {
        return error.UnexpectedDynuResponse;
    }
    var preview_buffer: [http_log_body_preview_len]u8 = undefined;
    std.log.debug("dynu response: {s}", .{http.bodyPreviewForLog(&preview_buffer, response.body)});
}

/// 逐一更新 No-IP 設定中的所有 hostname，使用 HTTP Basic Authorization。
/// 任一 hostname 失敗即回傳錯誤，讓上層將這個 provider 視為本輪失敗。
pub fn updateNoIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.NoIp,
    ip: []const u8,
) !void {
    const auth_value = try utils.buildBasicAuthorization(allocator, config.username, config.password);
    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_value },
    };

    for (config.hostnames) |hostname| {
        const url = try buildNoIpUrl(allocator, config, hostname, ip);
        const response = try http.fetchText(allocator, client, url, &headers, .{
            .connect_timeout = ddns_connect_timeout,
        });
        defer allocator.free(response.body);

        try http.ensureSuccessStatus(response.status, response.body);
        if (!containsGoodOrNochg(response.body)) {
            return error.UnexpectedNoIpResponse;
        }
        var preview_buffer: [http_log_body_preview_len]u8 = undefined;
        std.log.debug("no-ip response ({s}): {s}", .{
            hostname,
            http.bodyPreviewForLog(&preview_buffer, response.body),
        });
    }
}

/// 判斷 Afraid 的成功回應；服務商以 "Updated" 或 "has not changed" 表示可接受結果。
pub fn containsExpectedAfraidResponse(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "Updated") != null or
        std.mem.indexOf(u8, body, "has not changed") != null;
}

/// 判斷 Dynu / No-IP 的共同成功代碼：`good` 是已更新，`nochg` 是 IP 已相同。
pub fn containsGoodOrNochg(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "good") != null or
        std.mem.indexOf(u8, text, "nochg") != null;
}

/// 建立 Afraid token URL。回傳的 heap slice 由呼叫端以同一 allocator 釋放。
/// prefix 尾端的 `/` 會先移除，避免與 config.path 的開頭 `/` 拼出雙斜線。
pub fn buildAfraidUrl(
    allocator: std.mem.Allocator,
    config: config_mod.Afraid,
) ![]u8 {
    var prefix = config.url;
    while (prefix.len != 0 and prefix[prefix.len - 1] == '/') {
        prefix = prefix[0 .. prefix.len - 1];
    }

    return std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ prefix, config.path, config.token },
    );
}

/// 建立 Dynu GET URL。password 先做 SHA-256 並轉小寫十六進位，所有 query value 都 percent-encode。
/// `errdefer` 只在中途錯誤時釋放 ArrayList；成功時所有權移交給 toOwnedSlice 的回傳值。
pub fn buildDynuUrl(
    allocator: std.mem.Allocator,
    config: config_mod.Dynu,
    ip: []const u8,
) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(config.password, &digest, .{});
    const password_hex = std.fmt.bytesToHex(digest, .lower);

    var prefix = config.url;
    while (prefix.len != 0 and prefix[prefix.len - 1] == '/') {
        prefix = prefix[0 .. prefix.len - 1];
    }

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);

    try url.appendSlice(allocator, prefix);
    try url.append(allocator, '?');
    try utils.appendQueryParam(&url, allocator, "username", config.username);
    try url.append(allocator, '&');
    try utils.appendQueryParam(&url, allocator, "password", &password_hex);
    try url.append(allocator, '&');
    try utils.appendQueryParam(&url, allocator, "myip", ip);

    return url.toOwnedSlice(allocator);
}

/// 建立 No-IP 更新 URL；帳密不在 URL，而是由 updateNoIp 放入 Authorization header。
/// hostname 與 IP 都會 URL encode，避免保留字元改變 query 的意義。
pub fn buildNoIpUrl(
    allocator: std.mem.Allocator,
    config: config_mod.NoIp,
    hostname: []const u8,
    ip: []const u8,
) ![]u8 {
    var prefix = config.url;
    while (prefix.len != 0 and prefix[prefix.len - 1] == '/') {
        prefix = prefix[0 .. prefix.len - 1];
    }

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);

    try url.appendSlice(allocator, prefix);
    try url.append(allocator, '?');
    try utils.appendQueryParam(&url, allocator, "hostname", hostname);
    try url.append(allocator, '&');
    try utils.appendQueryParam(&url, allocator, "myip", ip);

    return url.toOwnedSlice(allocator);
}
