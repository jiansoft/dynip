//! DDNS 外部通知整合。
//!
//! Healthchecks 與 Uptime Kuma 使用簡單 HTTP ping；通用 webhook 則接收 JSON。
//! 通知失敗只寫 warning，絕不影響原本已完成的 DDNS 更新流程。

const std = @import("std");
const config_mod = @import("../../base/config.zig");
const http = @import("../../io/http.zig");

/// 送往 webhook 的事件類型。
pub const Event = enum {
    /// 本輪 DDNS refresh 已成功完成。
    success,
    /// 本輪 DDNS refresh 失敗。
    failure,
    /// 前一輪失敗、本輪成功，代表服務已恢復。
    recovered,
};

/// webhook JSON body。event 名稱使用 enum tag，錯誤名稱沒有錯誤時為 null。
const WebhookPayload = struct {
    event: []const u8,
    error_name: ?[]const u8,
};

/// 將通知事件集中轉成 wire-format 文字，避免 webhook payload 與測試各自維護字串。
fn eventName(event: Event) []const u8 {
    // @tagName 會把 enum `.recovered` 轉為 webhook 的穩定文字 "recovered"。
    return @tagName(event);
}

fn webhookPayload(event: Event, error_name: ?[]const u8) WebhookPayload {
    // 集中在此處建立 payload，可確保 success/recovered 都送 null error，
    // 而 failure 才攜帶原始 Zig error 名稱。
    return .{ .event = eventName(event), .error_name = error_name };
}

/// 送出成功事件：Healthchecks/Uptime Kuma 皆 ping，webhook 則收到 success/recovered。
pub fn notifySuccess(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Notifications,
    recovered: bool,
) void {
    ping(allocator, client, config.healthchecks_url, "healthchecks");
    ping(allocator, client, config.uptime_kuma_url, "uptime kuma");
    sendWebhook(allocator, client, config.webhook_url, if (recovered) .recovered else .success, null);
}

/// 送出失敗事件。Healthchecks 與 Uptime Kuma 的失敗格式各有差異，為避免猜測
/// URL 語意，這裡只向可攜的通用 webhook 傳送 failure 與 Zig error 名稱。
pub fn notifyFailure(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Notifications,
    err: anyerror,
) void {
    sendWebhook(allocator, client, config.webhook_url, .failure, @errorName(err));
}

/// 對單一 push URL 送 GET。沒有設定時直接略過，不建立 HTTP request。
fn ping(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, name: []const u8) void {
    if (url.len == 0) return;
    const response = http.requestText(allocator, client, url, .{}) catch |err| {
        std.log.warn("failed to send {s} ping: {}", .{ name, err });
        return;
    };
    defer allocator.free(response.body);
    http.ensureSuccessStatus(response.status, response.body) catch |err| {
        std.log.warn("{s} ping returned failure: {}", .{ name, err });
    };
}

/// 將事件轉成 JSON 並 POST 到使用者 webhook。HTTP helper 會避免在 log 印出 body。
fn sendWebhook(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    event: Event,
    error_name: ?[]const u8,
) void {
    if (url.len == 0) return;
    const response = http.requestJson(allocator, client, url, webhookPayload(event, error_name), .{}) catch |err| {
        std.log.warn("failed to send notification webhook: {}", .{err});
        return;
    };
    defer allocator.free(response.body);
    http.ensureSuccessStatus(response.status, response.body) catch |err| {
        std.log.warn("notification webhook returned failure: {}", .{err});
    };
}

test "notification webhook payload covers success failure and recovered" {
    const success = webhookPayload(.success, null);
    try std.testing.expectEqualStrings("success", success.event);
    try std.testing.expect(success.error_name == null);

    const failure = webhookPayload(.failure, "AllDdnsUpdatesFailed");
    try std.testing.expectEqualStrings("failure", failure.event);
    try std.testing.expectEqualStrings("AllDdnsUpdatesFailed", failure.error_name.?);

    const recovered = webhookPayload(.recovered, null);
    try std.testing.expectEqualStrings("recovered", recovered.event);
    try std.testing.expect(recovered.error_name == null);
}
