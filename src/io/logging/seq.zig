//! Seq（CLEF）遠端日誌推送。
//!
//! 這裡刻意不使用 `src/io/http.zig` 的 helper，因為那個 helper 會寫 HTTP log；
//! logger 內部送 Seq 時再產生 HTTP log 就會形成遞迴。
//!
//! 服務名稱由呼叫端（`../logging.zig`）傳入，這個檔因此不需要知道檔案日誌的命名規則。

const std = @import("std");

/// 設定型別（`SeqLogging`）。
const config_mod = @import("../../base/config.zig");

/// 時間型別。
const format = @import("format.zig");

/// Seq CLEF ingestion endpoint。
const seq_clef_path = "/ingest/clef";

/// Seq CLEF content type。
const seq_clef_content_type = "application/vnd.serilog.clef";

/// Seq 遠端日誌 sink。
///
/// 這裡刻意不使用 `src/io/http.zig` 的 helper，因為那個 helper 會寫 HTTP log。
/// 如果 logger 內部送 Seq 時又產生 HTTP log，就會形成遞迴。
pub const SeqSink = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    endpoint: []const u8,
    api_key: []const u8,
    /// 送到 Seq 的 `Service` 欄位，由呼叫端傳入。
    ///
    /// 刻意用參數而不是直接取檔案日誌那邊的服務名稱，這個檔才不必知道
    /// 檔名規則，也就不會回頭依賴 `rotate.zig`。
    service: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        seq_config: config_mod.SeqLogging,
        service: []const u8,
    ) !?SeqSink {
        if (!seq_config.enabled) return null;
        if (seq_config.server_url.len == 0 or seq_config.api_key.len == 0) return null;

        const base_url = trimTrailingSlashes(seq_config.server_url);
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ base_url, seq_clef_path },
        );
        errdefer allocator.free(endpoint);

        const api_key = try allocator.dupe(u8, seq_config.api_key);
        errdefer allocator.free(api_key);

        return .{
            .allocator = allocator,
            .client = .{
                .allocator = allocator,
                .io = io,
            },
            .endpoint = endpoint,
            .api_key = api_key,
            .service = service,
        };
    }

    pub fn deinit(self: *SeqSink) void {
        self.client.deinit();
        self.allocator.free(self.endpoint);
        self.allocator.free(self.api_key);
    }

    pub fn write(
        self: *SeqSink,
        level: std.log.Level,
        scope_name: ?[]const u8,
        message: []const u8,
        now: format.LocalDateTime,
    ) !void {
        var timestamp_buffer: [32]u8 = undefined;
        const timestamp = try formatSeqTimestamp(&timestamp_buffer, now);

        const event = SeqEvent{
            .@"@t" = timestamp,
            .@"@mt" = message,
            .@"@l" = seqLevelText(level),
            .SourceContext = scope_name,
            .Service = self.service,
        };

        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);

        var writer: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &body);
        errdefer writer.deinit();
        try std.json.Stringify.value(event, .{}, &writer.writer);
        try writer.writer.writeByte('\n');
        body = writer.toArrayList();

        try self.post(body.items);
    }

    fn post(self: *SeqSink, body: []const u8) !void {
        const uri = try std.Uri.parse(self.endpoint);
        const headers = [_]std.http.Header{
            .{ .name = "X-Seq-ApiKey", .value = self.api_key },
        };

        var request = try self.client.request(.POST, uri, .{
            .keep_alive = true,
            .headers = .{
                .content_type = .{ .override = seq_clef_content_type },
                .accept_encoding = .omit,
            },
            .extra_headers = &headers,
        });
        defer request.deinit();
        request.accept_encoding = @splat(false);
        request.accept_encoding[@backingInt(std.http.ContentEncoding.identity)] = true;

        const mutable_body = try self.allocator.dupe(u8, body);
        defer self.allocator.free(mutable_body);
        try request.sendBodyComplete(mutable_body);

        var redirect_buffer: [1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        const reader = response.reader(&.{});
        _ = reader.discardRemaining() catch {};

        if (response.head.status.class() != .success) {
            return error.SeqIngestionFailed;
        }
    }
};

/// 移除 URL 尾端多餘的 `/`。
fn trimTrailingSlashes(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

/// Seq 使用的 CLEF event 格式。
const SeqEvent = struct {
    @"@t": []const u8,
    @"@mt": []const u8,
    @"@l": []const u8,
    SourceContext: ?[]const u8,
    Service: []const u8,
};

/// 把 Zig log level 轉成 Seq / Serilog 常見 level 名稱。
pub fn seqLevelText(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "Error",
        .warn => "Warning",
        .info => "Information",
        .debug => "Debug",
    };
}

/// 產生 Seq CLEF `@t` 欄位需要的 ISO-like timestamp。
fn formatSeqTimestamp(buffer: []u8, now: format.LocalDateTime) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
        .{ now.year, now.month, now.day, now.hour, now.minute, now.second },
    );
}
