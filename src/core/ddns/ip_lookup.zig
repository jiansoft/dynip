const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const http = @import("../../io/http.zig");

const PublicIpService = types.PublicIpService;
const PublicIpLookup = types.PublicIpLookup;

const public_ip_connect_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(3),
    .clock = .awake,
} };

pub var primary_source_counter: usize = 0;

const Endpoint = struct {
    const PublicIp = struct {
        const stun = "stun.l.google.com:19302";
        const cloudflare_trace = "https://one.one.one.one/cdn-cgi/trace";
    };
};

pub fn serviceName(service: PublicIpService) []const u8 {
    return switch (service) {
        .stun => "stun",
        .cloudflare_trace => "cloudflare",
    };
}

pub fn publicIpServiceUrl(service: PublicIpService) []const u8 {
    return switch (service) {
        .stun => Endpoint.PublicIp.stun,
        .cloudflare_trace => Endpoint.PublicIp.cloudflare_trace,
    };
}

pub fn getPublicIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
) !PublicIpLookup {
    const current_round = primary_source_counter;
    primary_source_counter +%= 1;

    const primary_pair: [2]PublicIpService = if (current_round % 2 == 0)
        .{ .stun, .cloudflare_trace }
    else
        .{ .cloudflare_trace, .stun };

    var error_buffer: [512]u8 = undefined;
    var error_writer: std.Io.Writer = .fixed(&error_buffer);
    var stun_error: ?[]const u8 = null;

    for (primary_pair) |service| {
        if (tryFetchFromService(allocator, client, service, &error_writer, &stun_error)) |lookup| {
            return lookup;
        }
    }

    std.log.err("failed to get public ip from all services: {s}", .{error_buffer[0..error_writer.bytes_written]});
    return error.PublicIpLookupFailed;
}

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
        .stun_error = stun_error.*,
    };
}

fn appendPublicIpLookupError(
    writer: *std.Io.Writer,
    service: PublicIpService,
    err: anyerror,
) void {
    if (writer.bytes_written != 0) {
        writer.writeAll(" | ") catch return;
    }
    writer.print("{s}: {}", .{ serviceName(service), err }) catch {};
}

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

pub fn parseStunResponse(
    allocator: std.mem.Allocator,
    response: []const u8,
    transaction_id: []const u8,
) ![]const u8 {
    if (response.len < 20) return error.StunResponseTooShort;
    if (response[0] != 0x01 or response[1] != 0x01) return error.InvalidStunMessageType;
    if (!std.mem.eql(u8, response[8..20], transaction_id)) return error.StunTransactionIdMismatch;

    const msg_len = std.mem.readInt(u16, response[2..][0..2], .big);
    if (20 + msg_len > response.len) return error.InvalidStunMessageLength;

    var offset: usize = 20;
    const end = 20 + msg_len;
    while (offset + 4 <= end) {
        const attr_type = std.mem.readInt(u16, response[offset..][0..2], .big);
        const attr_len = std.mem.readInt(u16, response[offset + 2 ..][0..2], .big);
        offset += 4;

        if (offset + attr_len > end) return error.InvalidStunAttributeLength;

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

    const timeout = if (comptime @hasField(std.posix.timeval, "tv_sec"))
        std.posix.timeval{ .tv_sec = 2, .tv_usec = 0 }
    else
        std.posix.timeval{ .sec = 2, .usec = 0 };
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

pub fn normalizePublicIp(text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyPublicIpResponse;

    _ = std.Io.net.IpAddress.parse(trimmed, 0) catch return error.InvalidPublicIpResponse;
    return trimmed;
}
