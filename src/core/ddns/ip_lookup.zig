//! 查詢目前對外 public IP。依序嘗試 UDP STUN 與 Cloudflare trace，
//! 並把第一個成功結果交給上層；兩者都失敗時才回傳錯誤。
const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const http = @import("../../io/http.zig");

const PublicIpService = types.PublicIpService;
const PublicIpLookup = types.PublicIpLookup;
const IpFamily = types.IpFamily;

/// Cloudflare HTTP 連線逾時。STUN 使用 socket 層的接收逾時，兩者不是同一機制。
const public_ip_connect_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(3),
    .clock = .awake,
} };

/// 每次查詢遞增，以輪替第一優先來源，避免所有請求永久集中於同一個服務。
/// 此變數沒有鎖；目前排程使用方式假設查詢不會同時執行。
pub var primary_source_counter: usize = 0;

/// 集中管理服務端點，避免散落的 URL 字串難以修改或測試。
const Endpoint = struct {
    /// public IP 服務的端點集合。
    const PublicIp = struct {
        /// Google 公開 STUN 端點，格式為 host:port 而非 URL。
        const stun = "stun.l.google.com:19302";
        /// Cloudflare trace 端點，回應含有 `ip=` 行。
        const cloudflare_trace = "https://one.one.one.one/cdn-cgi/trace";
    };
};

/// 將來源 enum 轉成供 log、snapshot 與 dashboard 使用的固定文字。
pub fn serviceName(service: PublicIpService) []const u8 {
    return switch (service) {
        .stun => "stun",
        .cloudflare_trace => "cloudflare",
    };
}

/// 取得指定來源的端點字串。回傳 static slice，不需釋放。
pub fn publicIpServiceUrl(service: PublicIpService) []const u8 {
    return switch (service) {
        .stun => Endpoint.PublicIp.stun,
        .cloudflare_trace => Endpoint.PublicIp.cloudflare_trace,
    };
}

/// 查詢 public IP 的主要入口。兩個來源的優先順序會在每次呼叫輪替；
/// error_writer 收集每個失敗原因，以便兩者皆失敗時輸出單一診斷訊息。
/// 成功的 ip 是以傳入 allocator 配置，呼叫端必須負責釋放。
pub fn getPublicIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
) !PublicIpLookup {
    const current_round = primary_source_counter;
    primary_source_counter +%= 1;
    return getPublicIpWithPrimary(allocator, client, if (current_round % 2 == 0) .stun else .cloudflare_trace);
}

/// 以呼叫端明確指定的第一來源取得 public IP。本函式不讀寫全域輪替計數，
/// 因此同一個 scheduler 週期的 IPv4、IPv6 可共用相同優先來源。
pub fn getPublicIpWithPrimary(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    primary: PublicIpService,
) !PublicIpLookup {
    const primary_pair: [2]PublicIpService = if (primary == .stun)
        .{ .stun, .cloudflare_trace }
    else
        .{ .cloudflare_trace, .stun };

    // fixed writer 的 `end` 是有效內容長度；buffer 剩餘部分為 undefined，不能直接列印。
    var error_buffer: [512]u8 = undefined;
    var error_writer: std.Io.Writer = .fixed(&error_buffer);
    var stun_error: ?[]const u8 = null;

    for (primary_pair) |service| {
        if (tryFetchFromService(allocator, client, service, &error_writer, &stun_error)) |lookup| {
            return lookup;
        }
    }

    std.log.err("failed to get public ip from all services: {s}", .{error_buffer[0..error_writer.end]});
    return error.PublicIpLookupFailed;
}

/// 嘗試單一服務。失敗時不向上傳遞錯誤，而是附加錯誤文字後回傳 null，
/// 讓 getPublicIp 可以繼續嘗試 fallback；成功時回傳 optional 的有效值。
fn tryFetchFromService(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    service: PublicIpService,
    error_writer: *std.Io.Writer,
    stun_error: *?[]const u8,
) ?PublicIpLookup {
    std.log.debug("try public ip service: service={s}, endpoint={s}", .{
        serviceName(service),
        publicIpServiceUrl(service),
    });

    const ip = fetchPublicIpFromService(allocator, client, service) catch |err| {
        if (service == .stun) {
            stun_error.* = @errorName(err);
        }
        std.log.debug("public ip service failed: service={s}, error={s}", .{
            serviceName(service),
            @errorName(err),
        });
        appendPublicIpLookupError(error_writer, service, err);
        return null;
    };

    std.log.debug("public ip service succeeded: service={s}, ip={s}", .{
        serviceName(service),
        ip,
    });
    return .{
        .ip = ip,
        .service = service,
        .family = familyForIp(ip) catch unreachable,
        .stun_error = stun_error.*,
    };
}

/// 從已驗證文字 IP 判斷位址族。normalizePublicIp 已經用同一解析器驗證過輸入；
/// 這個 helper 仍保留錯誤回傳，方便獨立呼叫者安全使用。
pub fn familyForIp(ip: []const u8) !IpFamily {
    return switch (try std.Io.net.IpAddress.parse(ip, 0)) {
        .ip4 => .ipv4,
        .ip6 => .ipv6,
    };
}

/// 以指定位址族查詢公開 IP。仍只使用既有的 STUN 與 Cloudflare Trace 來源；
/// 若本次輪替後取得的結果不是要求的位址族，回傳 PublicIpFamilyUnavailable。
pub fn getPublicIpForFamily(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    family: IpFamily,
    primary: PublicIpService,
    provider: []const u8,
) !PublicIpLookup {
    // 非 auto provider 不走 STUN/Cloudflare fallback，而是嚴格使用使用者指定來源。
    // 這讓測試、容器與只有單一 family 的網路可預期地控制行為。
    if (!std.mem.eql(u8, provider, "auto")) {
        return getPublicIpFromConfiguredProvider(allocator, client, family, provider);
    }

    const lookup = try getPublicIpWithPrimary(allocator, client, primary);
    if (lookup.family == family) return lookup;
    // getPublicIpWithPrimary 配置了結果字串；這筆結果不屬於要求的 family，
    // 在進行 fallback 前必須釋放，避免雙 stack 長時間執行時累積配置。
    allocator.free(lookup.ip);

    // 第一來源成功但回傳另一種位址族時，不應立刻放棄。本輪仍可改用另一個
    // 已允許的來源取得目標 family；這不會增加第三方 public-IP 服務。
    const fallback_primary: PublicIpService = if (primary == .stun) .cloudflare_trace else .stun;
    const fallback = try getPublicIpWithPrimary(allocator, client, fallback_primary);
    if (fallback.family != family) {
        allocator.free(fallback.ip);
        return error.PublicIpFamilyUnavailable;
    }
    return fallback;
}

/// 解析 `ddns.ipv4_provider` / `ddns.ipv6_provider` 的設定值。
///
/// 支援的格式刻意保持簡單且不執行 shell：
/// - `none`：此 family 不由本程式管理。
/// - `stun`、`cloudflare_trace`：固定使用內建來源。
/// - `url:<url>`：向 URL 讀取一行純文字 IP。
/// - `file:<absolute-path>`：讀取檔案第一個非空、非註解行，適合測試注入。
/// - `static:<ip>`：直接使用固定 IP，適合單元/整合測試。
fn getPublicIpFromConfiguredProvider(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    family: IpFamily,
    provider: []const u8,
) !PublicIpLookup {
    if (std.mem.eql(u8, provider, "none")) return error.PublicIpFamilyDisabled;

    if (std.mem.eql(u8, provider, "stun") or std.mem.eql(u8, provider, "cloudflare_trace")) {
        const service: PublicIpService = if (std.mem.eql(u8, provider, "stun")) .stun else .cloudflare_trace;
        const ip = try fetchPublicIpFromService(allocator, client, service);
        const detected_family = try familyForIp(ip);
        if (detected_family != family) {
            allocator.free(ip);
            return error.PublicIpFamilyMismatch;
        }
        return .{ .ip = ip, .service = service, .family = family };
    }

    if (stripProviderPrefix(provider, "static:")) |ip_text| {
        return configuredTextLookup(allocator, ip_text, family, .cloudflare_trace);
    }
    if (stripProviderPrefix(provider, "file:")) |path| {
        // `readFileAlloc` 限制為 4 KiB，因為這不是一般資料檔，而是一個小型測試/注入介面。
        const text = try std.Io.Dir.cwd().readFileAlloc(client.io, path, allocator, .limited(4096));
        return configuredTextLookup(allocator, firstIpLine(text), family, .cloudflare_trace);
    }
    if (stripProviderPrefix(provider, "url:")) |url| {
        const ip = try fetchPlainTextIp(allocator, client, url, family);
        return .{ .ip = ip, .service = .cloudflare_trace, .family = family };
    }
    return error.InvalidPublicIpProvider;
}

/// Zig 0.17.0 尚未提供 `std.mem.stripIfStartsWith`，因此在此集中實作
/// 相同語意：前綴相符時回傳剩餘字串，不相符則回傳 null。
/// 把版本相容細節留在這個小 helper，可讓上方 provider parser 維持易讀。
fn stripProviderPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

/// 從 static 或 file 的文字取得 IP，並保證它符合被要求的 family。
fn configuredTextLookup(allocator: std.mem.Allocator, text: []const u8, family: IpFamily, service: PublicIpService) !PublicIpLookup {
    const normalized = try normalizePublicIp(text);
    if (try familyForIp(normalized) != family) return error.PublicIpFamilyMismatch;
    return .{ .ip = try allocator.dupe(u8, normalized), .service = service, .family = family };
}

/// file provider 只取第一個可用資料行；空白行與 `#` 註解讓測試 fixture 更易閱讀。
fn firstIpLine(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0 and trimmed[0] != '#') return trimmed;
    }
    return "";
}

fn lookupMatchesFamily(lookup: PublicIpLookup, family: IpFamily) bool {
    // 將這個很小的判斷抽出，可獨立測試 fallback 不會接受另一種 IP family。
    return lookup.family == family;
}

/// 下載純文字 IP 並檢查它和呼叫者要求的位址族一致，避免 DNS/Proxy 配置錯誤
/// 導致 IPv4 流程取得 IPv6（或反過來）後寫入錯誤 DNS record。
fn fetchPlainTextIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    expected_family: IpFamily,
) ![]const u8 {
    const response = try http.fetchText(allocator, client, url, &.{}, .{
        .connect_timeout = public_ip_connect_timeout,
    });
    defer allocator.free(response.body);
    try http.ensureSuccessStatus(response.status, response.body);
    const normalized = try normalizePublicIp(response.body);
    if (try familyForIp(normalized) != expected_family) return error.PublicIpFamilyMismatch;
    return allocator.dupe(u8, normalized);
}

/// 以 `服務名: 錯誤` 格式追加到 fixed writer。writer 容量用盡時忽略額外文字，
/// 因為錯誤訊息不得再遮蔽原本的查詢失敗。
fn appendPublicIpLookupError(
    writer: *std.Io.Writer,
    service: PublicIpService,
    err: anyerror,
) void {
    if (writer.end != 0) {
        writer.writeAll(" | ") catch return;
    }
    writer.print("{s}: {}", .{ serviceName(service), err }) catch {};
}

/// 依 service enum 分派至 STUN 或 HTTP 實作。anyerror 讓兩條底層錯誤集合可統一回傳。
pub fn fetchPublicIpFromService(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    service: PublicIpService,
) anyerror![]const u8 {
    const url = publicIpServiceUrl(service);
    return switch (service) {
        .stun => fetchStunIp(allocator, client.io, url),
        .cloudflare_trace => fetchCloudflareTraceIp(allocator, client, url),
    };
}

/// 下載 Cloudflare trace 純文字回應，逐行尋找 `ip=`，再用標準庫驗證 IPv4/IPv6 格式。
/// response.body 由 HTTP helper 配置，因此 defer 在函式結束時釋放它。
fn fetchCloudflareTraceIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
) ![]const u8 {
    const response = try http.fetchText(allocator, client, url, &.{}, .{
        .connect_timeout = public_ip_connect_timeout,
    });
    defer allocator.free(response.body);

    try http.ensureSuccessStatus(response.status, response.body);

    var iter = std.mem.splitScalar(u8, response.body, '\n');
    while (iter.next()) |line| {
        const trimmed_line = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;

        if (std.mem.startsWith(u8, trimmed_line, "ip=")) {
            const ip_value = trimmed_line["ip=".len..];
            const normalized = try normalizePublicIp(ip_value);
            return allocator.dupe(u8, normalized);
        }
    }

    return error.CloudflareTraceIpNotFound;
}

/// 解析 STUN Binding Success Response 的 XOR-MAPPED-ADDRESS attribute。
/// response 和 transaction_id 都是借用 slice；成功時回傳格式化後、由 allocator 擁有的 IP 字串。
pub fn parseStunResponse(
    allocator: std.mem.Allocator,
    response: []const u8,
    transaction_id: []const u8,
) ![]const u8 {
    if (response.len < 20) return error.StunResponseTooShort;
    if (response[0] != 0x01 or response[1] != 0x01) return error.InvalidStunMessageType;
    if (!std.mem.eql(u8, response[8..20], transaction_id)) return error.StunTransactionIdMismatch;

    // STUN header 中的長度與 attribute 數字皆採網路位元組序（big endian）。
    const msg_len = std.mem.readInt(u16, response[2..][0..2], .big);
    if (20 + msg_len > response.len) return error.InvalidStunMessageLength;

    var offset: usize = 20;
    const end = 20 + msg_len;
    while (offset + 4 <= end) {
        const attr_type = std.mem.readInt(u16, response[offset..][0..2], .big);
        const attr_len = std.mem.readInt(u16, response[offset + 2 ..][0..2], .big);
        offset += 4;

        if (offset + attr_len > end) return error.InvalidStunAttributeLength;

        // 0x0020 是 XOR-MAPPED-ADDRESS；它以 magic cookie / transaction ID XOR，
        // 可避免 NAT 對封包內看似 IP 的內容做錯誤改寫。
        if (attr_type == 0x0020) {
            if (attr_len < 8) return error.InvalidXorMappedAddressLength;
            const family = response[offset + 1];
            if (family == 1) { // IPv4
                const x_ip = response[offset + 4 .. offset + 8];
                const magic = [4]u8{ 0x21, 0x12, 0xA4, 0x42 };
                const ip = [4]u8{
                    x_ip[0] ^ magic[0],
                    x_ip[1] ^ magic[1],
                    x_ip[2] ^ magic[2],
                    x_ip[3] ^ magic[3],
                };
                return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
            } else if (family == 2) { // IPv6
                if (attr_len < 20) return error.InvalidXorMappedAddressLength;
                const x_ip = response[offset + 4 .. offset + 20];
                var magic_and_tx: [16]u8 = undefined;
                std.mem.writeInt(u32, magic_and_tx[0..4], 0x2112A442, .big);
                @memcpy(magic_and_tx[4..16], transaction_id);

                var ip: [16]u8 = undefined;
                for (0..16) |i| {
                    ip[i] = x_ip[i] ^ magic_and_tx[i];
                }
                return try std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
                    ip[0], ip[1], ip[2],  ip[3],  ip[4],  ip[5],  ip[6],  ip[7],
                    ip[8], ip[9], ip[10], ip[11], ip[12], ip[13], ip[14], ip[15],
                });
            }
        }
        offset += (attr_len + 3) & ~@as(usize, 3);
    }

    return error.XorMappedAddressNotFound;
}

/// 向 STUN server 發送 20-byte Binding Request，接收回應並交由 parseStunResponse 解碼。
/// DNS 使用 Zig I/O queue 非同步取得位址，UDP send/receive 仍以 socket 系統呼叫完成。
pub fn fetchStunIp(allocator: std.mem.Allocator, io: std.Io, stun_endpoint: []const u8) ![]const u8 {
    const colon_idx = std.mem.indexOfScalar(u8, stun_endpoint, ':') orelse return error.InvalidStunEndpoint;
    const host = stun_endpoint[0..colon_idx];
    const port_str = stun_endpoint[colon_idx + 1 ..];
    const port = try std.fmt.parseUnsigned(u16, port_str, 10);

    const host_name = try std.Io.net.HostName.init(host);

    var canonical_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    var lookup_buffer: [1]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    var lookup_future = io.async(std.Io.net.HostName.lookup, .{ host_name, io, &lookup_queue, .{
        .port = port,
        .canonical_name_buffer = &canonical_name_buffer,
    } });
    defer lookup_future.cancel(io) catch {};

    var resolved_addr: ?std.Io.net.IpAddress = null;
    while (lookup_queue.getOne(io)) |dns_result| switch (dns_result) {
        .address => |address| {
            if (resolved_addr == null) {
                resolved_addr = address;
            }
        },
        .canonical_name => continue,
    } else |err| switch (err) {
        error.Canceled => return err,
        error.Closed => {},
    }

    try lookup_future.await(io);

    const stun_addr = resolved_addr orelse return error.DnsResolutionFailed;
    const posix_addr = utils.ipAddressToPosix(stun_addr);

    const socket = try utils.createUdpSocket(switch (posix_addr) {
        .ip4 => std.posix.AF.INET,
        .ip6 => std.posix.AF.INET6,
    });
    defer utils.closeSocket(socket);

    // 欄位名在 Windows 與 Linux 都是 `sec`/`usec`，不需要相容分支。
    const timeout: std.posix.timeval = .{ .sec = 2, .usec = 0 };
    try utils.setSocketTimeout(socket, timeout);

    var request: [20]u8 = undefined;
    request[0] = 0x00;
    request[1] = 0x01;
    request[2] = 0x00;
    request[3] = 0x00;
    request[4] = 0x21;
    request[5] = 0x12;
    request[6] = 0xA4;
    request[7] = 0x42;
    // STUN transaction ID 必須剛好 12 bytes；回應必須帶著相同 ID 才是本請求的回覆。
    const transaction_id = "antigravity1";
    @memcpy(request[8..20], transaction_id);

    _ = switch (posix_addr) {
        .ip4 => |*addr| try utils.sendtoSocket(socket, &request, 0, @ptrCast(addr), @sizeOf(std.posix.sockaddr.in)),
        .ip6 => |*addr| try utils.sendtoSocket(socket, &request, 0, @ptrCast(addr), @sizeOf(std.posix.sockaddr.in6)),
    };

    var response: [512]u8 = undefined;
    var from_addr: std.posix.sockaddr = undefined;
    var from_len: std.posix.socklen_t = @intCast(@sizeOf(std.posix.sockaddr));
    const recv_len = try utils.recvfromSocket(socket, &response, 0, &from_addr, &from_len);

    return try parseStunResponse(allocator, response[0..recv_len], transaction_id);
}

/// 去除空白後用 std.Io.net.IpAddress.parse 驗證輸入，並回傳借用原始 text 的 trimmed slice。
/// 注意：本函式不配置記憶體，呼叫端仍需維持 text 的生命週期。
pub fn normalizePublicIp(text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyPublicIpResponse;

    _ = std.Io.net.IpAddress.parse(trimmed, 0) catch return error.InvalidPublicIpResponse;
    return trimmed;
}

test "family fallback accepts only the requested address family" {
    const ipv4 = PublicIpLookup{ .ip = "203.0.113.10", .service = .stun, .family = .ipv4 };
    const ipv6 = PublicIpLookup{ .ip = "2001:db8::10", .service = .cloudflare_trace, .family = .ipv6 };

    try std.testing.expect(!lookupMatchesFamily(ipv4, .ipv6));
    try std.testing.expect(lookupMatchesFamily(ipv6, .ipv6));
}

test "configured static provider isolates the requested family" {
    const lookup = try configuredTextLookup(std.testing.allocator, "2001:db8::42", .ipv6, .cloudflare_trace);
    defer std.testing.allocator.free(lookup.ip);
    try std.testing.expectEqual(IpFamily.ipv6, lookup.family);
    try std.testing.expectEqualStrings("2001:db8::42", lookup.ip);
    try std.testing.expectError(error.PublicIpFamilyMismatch, configuredTextLookup(std.testing.allocator, "203.0.113.42", .ipv6, .stun));
}

test "file provider text accepts first non-comment ip line" {
    try std.testing.expectEqualStrings("203.0.113.42", firstIpLine("# test fixture\n\n 203.0.113.42\r\n"));
}

test "provider prefix helper returns only matching suffix" {
    try std.testing.expectEqualStrings("203.0.113.42", stripProviderPrefix("static:203.0.113.42", "static:").?);
    try std.testing.expect(stripProviderPrefix("stun", "static:") == null);
}
