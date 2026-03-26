//! Redis 包裝模組。
//!
//! 這一版不再手寫 RESP 協定，
//! 而是改用第三方套件 `zig-okredis` 當底層 client。
//!
//! 專案外部其實還是只看到三個主要 API：
//! - `containsKey(...)`
//! - `setEx(...)`
//! - `ping(...)`
//!
//! 這樣其他模組，例如 `ddns.zig`，就不用知道底層 client 已經換掉。

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
const config_mod = @import("config.zig");
/// 匯入 `zig-okredis`。
///
/// 這個 module 是在 `build.zig` 透過 dependency 掛進來的。
const okredis = @import("okredis");

/// 建立 Redis 專用的 log scope。
///
/// 之後 log 會顯示成 `(redis)`，方便和 `(http)` 或一般 service log 區分。
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

/// 一條短生命週期的 Redis 連線工作階段。
///
/// 目前這個專案沒有做 connection pool，
/// 而是每次：
/// - 查 `EXISTS`
/// - 寫 `SETEX`
/// - 做 `PING`
///
/// 都建立一條連線，用完就關掉。
const Session = struct {
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
    /// `zig-okredis` 提供的高階 Redis client。
    client: Client,

    /// 建立一條新的 Redis session。
    fn connect(io: std.Io, config: config_mod.Redis) !Session {
        // 先把像 `192.168.1.10:6379` 這樣的字串拆成 host 與 port。
        const endpoint = try splitHostPort(config.addr);
        // 然後真的打開 TCP 連線。
        const stream = try connectStream(io, endpoint.host, endpoint.port);
        errdefer stream.close(io);

        // 先宣告一個未初始化的 session。
        // 等等會把欄位一個一個填進去。
        var session: Session = undefined;
        session.io = io;
        session.stream = stream;

        // reader / writer 都必須綁定到自己的 buffer。
        session.reader = session.stream.reader(io, &session.reader_buffer);
        session.writer = session.stream.writer(io, &session.writer_buffer);

        // 如果有密碼，就組出 AUTH 資訊。
        // 如果沒有密碼，就讓 okredis 看到 `null`，表示不做 AUTH。
        const auth: ?Auth = if (config.password.len == 0)
            null
        else
            .{
                .user = if (config.account.len == 0) null else config.account,
                .pass = config.password,
            };

        // 初始化 okredis client。
        //
        // `Client.init(...)` 會：
        // 1. 視情況先做 AUTH
        // 2. 接著送 `HELLO 3`
        // 3. 確認 Redis 支援 RESP3
        session.client = try Client.init(
            io,
            &session.reader.interface,
            &session.writer.interface,
            auth,
        );

        redis_log.info("connect redis via okredis addr={s} db={d}", .{ config.addr, config.db });

        // 如果指定的不是預設 DB 0，就再補一個 `SELECT`。
        if (config.db != 0) {
            var db_buffer: [32]u8 = undefined;
            const db_text = try std.fmt.bufPrint(&db_buffer, "{d}", .{config.db});
            try session.client.send(void, .{ "SELECT", db_text });
        }

        return session;
    }

    /// 關閉這條 TCP 連線。
    fn deinit(self: *Session) void {
        self.stream.close(self.io);
    }
};

/// 對外提供的 `EXISTS` 包裝。
///
/// `ddns.zig` 只需要知道 key 是否存在，
/// 不需要碰到底層 `okredis.Client`。
pub fn containsKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.Redis,
    key: []const u8,
) !bool {
    // 這個函式本身不需要 allocator，
    // 但保留同樣的參數形狀，能讓外部 API 不必改。
    _ = allocator;

    var session = try Session.connect(io, config);
    defer session.deinit();

    // `EXISTS key` 會回整數：
    // - 1 代表存在
    // - 0 代表不存在
    const count = try session.client.send(i64, .{ "EXISTS", key });
    return count > 0;
}

/// 對外提供的 `SETEX` 包裝。
///
/// 成功時 Redis 會回 `OK`，而 `client.send(void, ...)`
/// 在沒有錯誤或 nil 的情況下就會直接通過。
pub fn setEx(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.Redis,
    key: []const u8,
    value: []const u8,
    ttl_seconds: u64,
) !void {
    _ = allocator;

    var session = try Session.connect(io, config);
    defer session.deinit();

    // Redis 指令的 TTL 參數是字串，
    // 所以先把數字轉成文字。
    var ttl_buffer: [32]u8 = undefined;
    const ttl_text = try std.fmt.bufPrint(&ttl_buffer, "{d}", .{ttl_seconds});

    try session.client.send(void, .{ "SETEX", key, ttl_text, value });
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
    var session = try Session.connect(io, config);
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

test "live redis ping returns pong" {
    // 這是一個真的會連線到 Redis 的測試。
    // 它會讀目前專案根目錄下的 `app.json` / `.env`，
    // 然後使用裡面的 Redis 設定做一次 `PING`。
    std.debug.print("[live redis test] step 1: start test\n", .{});

    // 這裡直接使用 Zig 測試框架提供的 allocator。
    // 如果有記憶體漏掉，測試本身就會失敗。
    const allocator = std.testing.allocator;
    std.debug.print("[live redis test] step 2: use std.testing.allocator\n", .{});

    // 建立 Zig 0.16 的 threaded IO 環境。
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    std.debug.print("[live redis test] step 3: init threaded io\n", .{});
    const io = threaded.io();
    std.debug.print("[live redis test] step 4: acquire io handle\n", .{});

    // 設定資料適合放在 arena 裡，
    // 因為整個測試過程都會一直用到它。
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    std.debug.print("[live redis test] step 5: init arena allocator for config\n", .{});

    const app_config = try config_mod.loadLeaky(arena.allocator(), io, config_mod.default_config_path);
    std.debug.print(
        "[live redis test] step 6: loaded config, redis addr={s}, db={d}\n",
        .{ app_config.ddns.redis.addr, app_config.ddns.redis.db },
    );

    const pong = try ping(allocator, io, app_config.ddns.redis);
    defer allocator.free(pong);
    std.debug.print("[live redis test] step 7: sent PING and received reply={s}\n", .{pong});

    try std.testing.expectEqualStrings("PONG", pong);
    std.debug.print("[live redis test] step 8: assert reply == PONG\n", .{});
}
