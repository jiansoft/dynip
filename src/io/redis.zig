//! Redis 包裝模組。
//!
//! 這一版不再手寫 RESP 協定，
//! 而是改用第三方套件 `zig-okredis` 當底層客戶端。
//!
//! 專案外部其實還是只看到三個主要 API：
//! - `containsKey(...)`
//! - `get(...)`
//! - `hGet(...)`
//! - `hSetFields(...)`
//! - `setEx(...)`
//! - `ddnsDedupeCheckAndRemember(...)`
//! - `ping(...)`
//!
//! 這樣其他模組，例如 `ddns.zig`，就不用知道底層客戶端已經換掉。

/// 匯入 Zig 標準函式庫。
///
/// 這個檔案會用到：
/// - TCP 連線
/// - 緩衝 reader / writer
/// - 字串格式化
/// - 單元測試
const std = @import("std");
/// 匯入全域設定模組。
///
/// Redis 的位址、帳號、密碼與 DB index 都從這裡讀。
const config_mod = @import("../base/config.zig");
/// 匯入 `zig-okredis`。
///
/// 這個模組是在 `build.zig` 透過 dependency 掛進來的。
const okredis = @import("okredis");

/// 建立 Redis 專用的日誌分類。
///
/// 之後 log 會顯示成 `(redis)`，方便和 `(http)` 或一般服務日誌區分。
const redis_log = std.log.scoped(.redis);

/// 每條 TCP 讀取緩衝區大小。
///
/// 這塊記憶體會交給 `stream.reader(...)` 使用。
const read_buffer_len = 4096;
/// 每條 TCP 寫入緩衝區大小。
///
/// 這塊記憶體會交給 `stream.writer(...)` 使用。
const write_buffer_len = 1024;

/// 只是幫型別取一個比較短的別名，方便閱讀。
const Client = okredis.Client;
/// `zig-okredis` 的 `AUTH` 結構型別。
const Auth = Client.Auth;
/// `std.Io.net.Stream` 的簡短別名。
const Stream = std.Io.net.Stream;

/// DDNS dedupe 在 Redis 上單次往返需要的輸入。
pub const DdnsDedupeParams = struct {
    cache_key: []const u8,
    cache_value: []const u8,
    current_ip_key: []const u8,
    ttl_seconds: u64,
};

/// DDNS dedupe 單 session 檢查結果。
pub const DdnsDedupeResult = struct {
    cache_hit: bool,
};

/// 一條短生命週期的 Redis 連線工作階段。
///
/// 目前這個專案沒有做 connection pool，
/// 而是每次：
/// - 查 `EXISTS`
/// - 寫 `SETEX`
/// - 做 `PING`
///
/// 都建立一條連線，用完就關掉。
pub const Session = struct {
    /// Zig 的 IO 物件。
    io: std.Io,
    /// 底層 TCP stream。
    stream: Stream,
    /// reader 需要的固定緩衝區。
    reader_buffer: [read_buffer_len]u8 = undefined,
    /// writer 需要的固定緩衝區。
    writer_buffer: [write_buffer_len]u8 = undefined,
    /// 綁在這條 stream 上的 reader。
    reader: Stream.Reader,
    /// 綁在這條 stream 上的 writer。
    writer: Stream.Writer,
    /// `zig-okredis` 提供的高階 Redis 客戶端。
    client: Client,

    /// 在呼叫端提供的穩定記憶體位置上初始化 Redis session。
    ///
    /// `okredis.Client` 會保存指向 reader / writer interface 的指標，所以這個
    /// struct 初始化後不能再被搬移；因此這裡不回傳 by-value `Session`。
    pub fn init(self: *Session, io: std.Io, config: config_mod.Redis) !void {
        // 先把像 `192.168.1.10:6379` 這樣的字串拆成 host 與 port。
        const endpoint = try splitHostPort(config.addr);
        // 然後真的打開 TCP 連線。
        const stream = try connectStream(io, endpoint.host, endpoint.port);
        errdefer stream.close(io);

        self.io = io;
        self.stream = stream;

        // reader / writer 都必須綁定到自己的 buffer。
        self.reader = self.stream.reader(io, &self.reader_buffer);
        self.writer = self.stream.writer(io, &self.writer_buffer);

        // 如果有密碼，就組出 AUTH 資訊。
        // 如果沒有密碼，就讓 okredis 看到 `null`，表示不做 AUTH。
        const auth: ?Auth = if (config.password.len == 0)
            null
        else
            .{
                .user = if (config.account.len == 0) null else config.account,
                .pass = config.password,
            };

        // 初始化 okredis 客戶端。
        //
        // `Client.init(...)` 會：
        // 1. 視情況先做 AUTH
        // 2. 接著送 `HELLO 3`
        // 3. 確認 Redis 支援 RESP3
        self.client = try Client.init(
            io,
            &self.reader.interface,
            &self.writer.interface,
            auth,
        );

        redis_log.debug("connect redis via okredis addr={s} db={d}", .{ config.addr, config.db });

        // 如果指定的不是預設 DB 0，就再補一個 `SELECT`。
        if (config.db != 0) {
            var db_buffer: [32]u8 = undefined;
            const db_text = try std.fmt.bufPrint(&db_buffer, "{d}", .{config.db});
            try self.client.send(void, .{ "SELECT", db_text });
        }
    }

    /// 關閉這條 TCP 連線。
    pub fn deinit(self: *Session) void {
        self.stream.close(self.io);
    }

    /// 同一條 Redis 連線上執行 `EXISTS key`。
    pub fn containsKey(self: *Session, key: []const u8) !bool {
        const count = try self.client.send(i64, .{ "EXISTS", key });
        return count > 0;
    }

    /// 同一條 Redis 連線上執行 `GET key`。
    pub fn get(self: *Session, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        return self.client.sendAlloc(?[]u8, allocator, .{ "GET", key });
    }

    /// 同一條 Redis 連線上執行 `HGET key field`。
    pub fn hGet(self: *Session, allocator: std.mem.Allocator, key: []const u8, field: []const u8) !?[]u8 {
        return self.client.sendAlloc(?[]u8, allocator, .{ "HGET", key, field });
    }

    /// 同一條 Redis 連線上執行多欄位 `HSET key field value ...`。
    ///
    /// 先前這裡把 6 欄與 7 欄各展開成一組硬編 tuple，欄位數只要不是這兩個值就回
    /// `error.UnsupportedRedisHashFieldCount`。現在改成先攤平成 `[]const []const u8`
    /// 再送出：okredis 的序列化器遇到「元素型別不是 u8 的 slice」會把它展開成多個
    /// bulk string 參數（見 vendor/okredis/src/serializer.zig），因此仍然是單一 HSET
    /// 命令、單次來回，但欄位數不再寫死，也少掉三十多行重複程式碼。
    pub fn hSetFields(self: *Session, key: []const u8, fields: []const HashField) !void {
        if (fields.len == 0) return;
        if (fields.len > max_hash_fields) return error.TooManyRedisHashFields;

        // 攤平成 field/value 交錯排列，正好是 HSET 期望的參數順序。
        // 用 stack 陣列而不是配置：欄位數有上限，而且這些 slice 只在本次 send 期間有效。
        var flat: [max_hash_fields * 2][]const u8 = undefined;
        for (fields, 0..) |field, index| {
            flat[index * 2] = field.field;
            flat[index * 2 + 1] = field.value;
        }

        _ = try self.client.send(i64, .{ "HSET", key, flat[0 .. fields.len * 2] });
    }

    /// 同一條 Redis 連線上執行 `SETEX key ttl value`。
    pub fn setEx(self: *Session, key: []const u8, value: []const u8, ttl_seconds: u64) !void {
        var ttl_buffer: [32]u8 = undefined;
        const ttl_text = try std.fmt.bufPrint(&ttl_buffer, "{d}", .{ttl_seconds});
        try self.client.send(void, .{ "SETEX", key, ttl_text, value });
    }
};

/// Redis Hash 的單一欄位名稱與值。
///
/// key 由 `hSetFields` 的參數統一指定，因此不必每個欄位各帶一份 key，
/// 也就不需要再於執行期檢查「所有欄位是否共用同一個 key」。
pub const HashField = struct {
    field: []const u8,
    value: []const u8,
};

/// 單次 `hSetFields` 可寫入的欄位數上限，決定攤平用 stack 陣列的大小。
/// 目前欄位最多的呼叫端是 provider state（7 欄），這裡留足餘裕。
const max_hash_fields = 32;

// 註：先前這裡還有 containsKey / get / hGet / hSetFields / setEx 五個模組層包裝，
// 每一個都自己 `Session.init` → TCP 連線 + AUTH + SELECT → 用完就關。DDNS 的降級
// 路徑一輪會連續呼叫 setEx 三次以上，等於一輪 refresh 付三次以上完整握手。
// 這些包裝與 `Session` 上的同名方法完全重複，因此直接移除；呼叫端改為自行開一條
// `Session` 並在整段流程中重用（見 core/ddns.zig）。

/// 以單一 Redis session 完成 DDNS dedupe：
/// 1. `EXISTS MyPublicIP:{ip}`
/// 2. 沒命中時寫回 `MyPublicIP:{ip}`
/// 3. 再更新固定 key `MyPublicIP`
pub fn ddnsDedupeCheckAndRemember(
    io: std.Io,
    config: config_mod.Redis,
    params: DdnsDedupeParams,
) !DdnsDedupeResult {
    var session: Session = undefined;
    try session.init(io, config);
    defer session.deinit();

    return ddnsDedupeCheckAndRememberWithSession(&session, params);
}

/// 把 DDNS dedupe 的 Redis 指令序列抽成可測的 session-level helper。
fn ddnsDedupeCheckAndRememberWithSession(session: anytype, params: DdnsDedupeParams) !DdnsDedupeResult {
    if (try session.containsKey(params.cache_key)) {
        return .{ .cache_hit = true };
    }

    try session.setEx(params.cache_key, params.cache_value, params.ttl_seconds);
    try session.setEx(params.current_ip_key, params.cache_value, params.ttl_seconds);
    return .{ .cache_hit = false };
}

/// 做一次真正的 `PING`，並回傳 Redis 回的字串。
///
/// 這裡用 `sendAlloc([]u8, ...)`，所以回傳的字串是動態配置的。
/// 呼叫端在用完之後要自己 `free(...)`。
pub fn ping(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.Redis,
) ![]u8 {
    var session: Session = undefined;
    try session.init(io, config);
    defer session.deinit();

    return session.client.sendAlloc([]u8, allocator, .{"PING"});
}

/// 先嘗試把 host 當成 IP 解析，失敗再走 DNS 名稱連線。
fn connectStream(io: std.Io, host: []const u8, port: u16) !Stream {
    const options: std.Io.net.IpAddress.ConnectOptions = .{
        .mode = .stream,
        .protocol = .tcp,
    };

    // 如果 host 本身就是 IP，例如 `127.0.0.1`，
    // 那就直接解析成 `IpAddress`。
    const ip_address = std.Io.net.IpAddress.parse(host, port) catch {
        // 否則把它當成主機名稱，例如 `localhost` 或某台內網主機。
        const host_name = try std.Io.net.HostName.init(host);
        return std.Io.net.HostName.connect(host_name, io, port, options);
    };
    return ip_address.connect(io, options);
}

/// 解析 `host:port` 設定字串。
///
/// 支援：
/// - `localhost:6379`
/// - `127.0.0.1:6379`
/// - `[::1]:6379`
fn splitHostPort(addr: []const u8) !struct { host: []const u8, port: u16 } {
    if (addr.len == 0) return error.InvalidRedisAddress;

    // IPv6 內本身有很多 `:`，
    // 所以要用 `[::1]:6379` 這種格式區分 host 與 port。
    if (addr[0] == '[') {
        const end_index = std.mem.indexOfScalar(u8, addr, ']') orelse return error.InvalidRedisAddress;
        if (end_index + 2 > addr.len or addr[end_index + 1] != ':') return error.InvalidRedisAddress;

        const host = addr[1..end_index];
        const port = try std.fmt.parseUnsigned(u16, addr[end_index + 2 ..], 10);
        if (host.len == 0) return error.InvalidRedisAddress;
        return .{ .host = host, .port = port };
    }

    // 一般 host 或 IPv4 直接取最後一個 `:` 當作 port 分隔點。
    const separator_index = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.InvalidRedisAddress;
    const host = addr[0..separator_index];
    const port = try std.fmt.parseUnsigned(u16, addr[separator_index + 1 ..], 10);
    if (host.len == 0) return error.InvalidRedisAddress;
    return .{ .host = host, .port = port };
}

test "split host and port for hostname" {
    const parsed = try splitHostPort("localhost:6379");
    try std.testing.expectEqualStrings("localhost", parsed.host);
    try std.testing.expectEqual(@as(u16, 6379), parsed.port);
}

test "split host and port for bracket ipv6" {
    const parsed = try splitHostPort("[::1]:6380");
    try std.testing.expectEqualStrings("::1", parsed.host);
    try std.testing.expectEqual(@as(u16, 6380), parsed.port);
}

test "ddns dedupe helper returns cache hit without writes" {
    const FakeSession = struct {
        contains_key_result: bool = true,
        setex_calls: usize = 0,

        fn containsKey(self: *@This(), key: []const u8) !bool {
            try std.testing.expectEqualStrings("MyPublicIP:1.2.3.4", key);
            return self.contains_key_result;
        }

        fn setEx(self: *@This(), key: []const u8, value: []const u8, ttl_seconds: u64) !void {
            _ = key;
            _ = value;
            _ = ttl_seconds;
            self.setex_calls += 1;
        }
    };

    var session = FakeSession{};
    const result = try ddnsDedupeCheckAndRememberWithSession(&session, .{
        .cache_key = "MyPublicIP:1.2.3.4",
        .cache_value = "1.2.3.4",
        .current_ip_key = "MyPublicIP",
        .ttl_seconds = 60,
    });

    try std.testing.expect(result.cache_hit);
    try std.testing.expectEqual(@as(usize, 0), session.setex_calls);
}

test "ddns dedupe helper writes both redis keys on miss" {
    const FakeSession = struct {
        contains_key_result: bool = false,
        setex_calls: usize = 0,
        seen_keys: [2][]const u8 = .{ "", "" },
        seen_values: [2][]const u8 = .{ "", "" },
        seen_ttls: [2]u64 = .{ 0, 0 },

        fn containsKey(self: *@This(), key: []const u8) !bool {
            try std.testing.expectEqualStrings("MyPublicIP:1.2.3.4", key);
            return self.contains_key_result;
        }

        fn setEx(self: *@This(), key: []const u8, value: []const u8, ttl_seconds: u64) !void {
            self.seen_keys[self.setex_calls] = key;
            self.seen_values[self.setex_calls] = value;
            self.seen_ttls[self.setex_calls] = ttl_seconds;
            self.setex_calls += 1;
        }
    };

    var session = FakeSession{};
    const result = try ddnsDedupeCheckAndRememberWithSession(&session, .{
        .cache_key = "MyPublicIP:1.2.3.4",
        .cache_value = "1.2.3.4",
        .current_ip_key = "MyPublicIP",
        .ttl_seconds = 86400,
    });

    try std.testing.expect(!result.cache_hit);
    try std.testing.expectEqual(@as(usize, 2), session.setex_calls);
    try std.testing.expectEqualStrings("MyPublicIP:1.2.3.4", session.seen_keys[0]);
    try std.testing.expectEqualStrings("MyPublicIP", session.seen_keys[1]);
    try std.testing.expectEqualStrings("1.2.3.4", session.seen_values[0]);
    try std.testing.expectEqualStrings("1.2.3.4", session.seen_values[1]);
    try std.testing.expectEqual(@as(u64, 86400), session.seen_ttls[0]);
    try std.testing.expectEqual(@as(u64, 86400), session.seen_ttls[1]);
}

/// 只有設定 `DYNIP_LIVE_TESTS=1` 時才執行會連外部服務的測試。
///
/// 這類測試預設關閉的原因有三個：
/// 1. 它們需要真實的 Redis 憑證與可用的外網，在 CI 或離線開發時必定失敗。
/// 2. 它們讓 `zig build test` 的結果取決於本機網路狀態，而不是程式碼本身。
/// 3. 這個 Redis 測試在 build runner 的 `--listen=-` 模式下會讓測試行程以
///    非零碼結束，導致 build runner 重跑整個測試二進位，也就是實際上會對
///    正式 Redis 送出兩次 PING。
fn liveTestsEnabled() bool {
    const value = std.c.getenv("DYNIP_LIVE_TESTS") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

test "live redis ping returns pong" {
    // 這是一個真的會連線到 Redis 的測試。
    // 它會讀目前專案根目錄下的 `app.json` / `.env`，
    // 然後使用裡面的 Redis 設定做一次 `PING`。
    if (!liveTestsEnabled()) return error.SkipZigTest;

    // 這裡直接使用 Zig 測試框架提供的 allocator。
    // 如果有記憶體漏掉，測試本身就會失敗。
    const allocator = std.testing.allocator;

    // 建立 threaded IO 環境。
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 設定資料適合放在 arena 裡，
    // 因為整個測試過程都會一直用到它。
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const app_config = try config_mod.loadLeaky(arena.allocator(), io, config_mod.default_config_path);

    const pong = try ping(allocator, io, app_config.ddns.redis);
    defer allocator.free(pong);

    try std.testing.expectEqualStrings("PONG", pong);
}
