const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const WSADATA = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*:0]u8,
};

pub const ws2_32 = if (builtin.os.tag == .windows) struct {
    pub extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSADATA) callconv(.winapi) c_int;
    pub extern "ws2_32" fn closesocket(s: std.posix.socket_t) callconv(.winapi) c_int;
    pub extern "ws2_32" fn connect(s: std.posix.socket_t, name: ?*const anyopaque, namelen: c_int) callconv(.winapi) c_int;
} else struct {};

pub var windows_sockets_started = false;

pub fn ensureWindowsSocketsStarted() !void {
    if (comptime builtin.os.tag != .windows) return;
    if (windows_sockets_started) return;

    var data: WSADATA = undefined;
    const rc = ws2_32.WSAStartup(0x0202, &data);
    if (rc != 0) return error.WindowsSocketStartupFailed;
    windows_sockets_started = true;
}

pub fn castSocket(rc: anytype) std.posix.socket_t {
    if (comptime builtin.os.tag == .windows) {
        return @ptrFromInt(@as(usize, @bitCast(@as(isize, rc))));
    } else {
        return @intCast(rc);
    }
}

pub fn createUdpSocket(family: std.posix.sa_family_t) !std.posix.socket_t {
    try ensureWindowsSocketsStarted();

    const cloexec: u32 = if (comptime builtin.os.tag == .windows)
        0
    else if (comptime @hasDecl(std.posix.SOCK, "CLOEXEC"))
        std.posix.SOCK.CLOEXEC
    else
        0;
    const flags: u32 = std.posix.SOCK.DGRAM | cloexec;
    const rc = std.posix.system.socket(family, flags, std.posix.IPPROTO.UDP);
    if (rc == -1) return error.SocketCreationFailed;
    return castSocket(rc);
}

pub fn createTcpSocket(family: std.posix.sa_family_t) !std.posix.socket_t {
    try ensureWindowsSocketsStarted();

    const cloexec: u32 = if (comptime builtin.os.tag == .windows)
        0
    else if (comptime @hasDecl(std.posix.SOCK, "CLOEXEC"))
        std.posix.SOCK.CLOEXEC
    else
        0;
    const flags: u32 = std.posix.SOCK.STREAM | cloexec;
    const rc = std.posix.system.socket(family, flags, std.posix.IPPROTO.TCP);
    if (rc == -1) return error.SocketCreationFailed;
    return castSocket(rc);
}

pub fn closeSocket(fd: std.posix.socket_t) void {
    if (comptime builtin.os.tag == .windows) {
        _ = ws2_32.closesocket(fd);
    } else {
        _ = std.posix.system.close(fd);
    }
}

pub fn connectSocket(fd: std.posix.socket_t, addr: anytype, len: std.posix.socklen_t) !void {
    if (comptime builtin.os.tag == .windows) {
        const rc = ws2_32.connect(fd, @ptrCast(addr), @intCast(len));
        if (rc == -1) return error.ConnectionFailed;
    } else {
        const rc = std.posix.system.connect(fd, @ptrCast(addr), len);
        if (rc == -1) return error.ConnectionFailed;
    }
}

pub fn setSocketTimeout(fd: std.posix.socket_t, timeout_val: std.posix.timeval) !void {
    const opt_bytes = std.mem.asBytes(&timeout_val);
    const rc = std.posix.system.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, opt_bytes.ptr, @intCast(opt_bytes.len));
    if (rc == -1) {
        return error.SetSocketTimeoutFailed;
    }
}

pub fn sendtoSocket(
    fd: std.posix.socket_t,
    buf: []const u8,
    flags: u32,
    dest_addr: *const std.posix.sockaddr,
    addrlen: std.posix.socklen_t,
) !usize {
    const rc = std.posix.system.sendto(fd, buf.ptr, @intCast(buf.len), @intCast(flags), dest_addr, addrlen);
    if (rc == -1) {
        return error.SendFailed;
    }
    return @intCast(rc);
}

pub fn recvfromSocket(
    fd: std.posix.socket_t,
    buf: []u8,
    flags: u32,
    src_addr: *std.posix.sockaddr,
    addrlen: *std.posix.socklen_t,
) !usize {
    const rc = std.posix.system.recvfrom(fd, buf.ptr, @intCast(buf.len), @intCast(flags), src_addr, addrlen);
    if (rc == -1) {
        return error.ReceiveFailed;
    }
    return @intCast(rc);
}

pub fn ipAddressToPosix(a: std.Io.net.IpAddress) union(enum) { ip4: std.posix.sockaddr.in, ip6: std.posix.sockaddr.in6 } {
    return switch (a) {
        .ip4 => |ip4| .{
            .ip4 = .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            },
        },
        .ip6 => |ip6| .{
            .ip6 = .{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            },
        },
    };
}

pub fn parseHostPort(addr: []const u8) !struct { host: []const u8, port: u16 } {
    if (addr.len == 0) return error.InvalidRedisAddress;
    if (addr[0] == '[') {
        const end_index = std.mem.indexOfScalar(u8, addr, ']') orelse return error.InvalidRedisAddress;
        if (end_index + 2 > addr.len or addr[end_index + 1] != ':') return error.InvalidRedisAddress;
        const host = addr[1..end_index];
        const port = try std.fmt.parseUnsigned(u16, addr[end_index + 2 ..], 10);
        return .{ .host = host, .port = port };
    } else {
        const colon_index = std.mem.indexOfScalar(u8, addr, ':') orelse return error.InvalidRedisAddress;
        const host = addr[0..colon_index];
        const port = try std.fmt.parseUnsigned(u16, addr[colon_index + 1 ..], 10);
        return .{ .host = host, .port = port };
    }
}

pub fn checkTcpPortReachable(allocator: std.mem.Allocator, io: std.Io, host: []const u8, port: u16) !void {
    _ = allocator;
    try ensureWindowsSocketsStarted();

    const ip_addr = std.Io.net.IpAddress.parse(host, port) catch blk: {
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
        break :blk stun_addr;
    };

    const posix_addr = ipAddressToPosix(ip_addr);
    const socket = try createTcpSocket(switch (posix_addr) {
        .ip4 => std.posix.AF.INET,
        .ip6 => std.posix.AF.INET6,
    });
    defer closeSocket(socket);

    switch (posix_addr) {
        .ip4 => |*addr| try connectSocket(socket, addr, @sizeOf(std.posix.sockaddr.in)),
        .ip6 => |*addr| try connectSocket(socket, addr, @sizeOf(std.posix.sockaddr.in6)),
    }
}

pub fn shouldSkipMaintenanceWindow() bool {
    if (builtin.os.tag == .windows) {
        const SYSTEMTIME = extern struct {
            wYear: u16,
            wMonth: u16,
            wDayOfWeek: u16,
            wDay: u16,
            wHour: u16,
            wMinute: u16,
            wSecond: u16,
            wMilliseconds: u16,
        };
        const kernel32 = struct {
            extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
        };

        var local_time: SYSTEMTIME = undefined;
        kernel32.GetLocalTime(&local_time);
        return shouldSkipMaintenanceWindowAt(local_time.wHour, local_time.wMinute);
    } else {
        var now: c.time_t = c.time(null);
        var local_tm: c.struct_tm = undefined;
        _ = c.localtime_r(&now, &local_tm) orelse return false;
        return shouldSkipMaintenanceWindowAt(local_tm.tm_hour, local_tm.tm_min);
    }
}

pub fn shouldSkipMaintenanceWindowAt(hour: c_int, minute: c_int) bool {
    return hour == 2 and minute >= 0 and minute < 5;
}

pub fn isUnreservedUrlByte(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~';
}

pub fn appendUrlEncoded(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    for (value) |char| {
        if (isUnreservedUrlByte(char)) {
            try buffer.append(allocator, char);
            continue;
        }

        var escaped: [3]u8 = undefined;
        _ = try std.fmt.bufPrint(&escaped, "%{X:0>2}", .{char});
        try buffer.appendSlice(allocator, &escaped);
    }
}

pub fn appendQueryParam(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !void {
    try buffer.appendSlice(allocator, key);
    try buffer.append(allocator, '=');
    try appendUrlEncoded(buffer, allocator, value);
}

pub fn buildBasicAuthorization(
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    defer allocator.free(raw);

    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);

    _ = std.base64.standard.Encoder.encode(encoded, raw);
    return std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
}
