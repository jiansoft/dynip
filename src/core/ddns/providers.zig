const std = @import("std");
const config_mod = @import("../../base/config.zig");
const http = @import("../../io/http.zig");
const utils = @import("utils.zig");

const ddns_connect_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(5),
    .clock = .awake,
} };
const http_log_body_preview_len = http.body_preview_len;

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

pub fn containsExpectedAfraidResponse(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "Updated") != null or
        std.mem.indexOf(u8, body, "has not changed") != null;
}

pub fn containsGoodOrNochg(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "good") != null or
        std.mem.indexOf(u8, text, "nochg") != null;
}

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
