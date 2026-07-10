//! DDNS 模組專用的底層工具與跨平台系統轉接器 (Platform Shim & Network Utilities)。
//!
//! 職責包含：
//! - Windows Winsock (ws2_32) 的初始化與跨平台 Socket 底層封裝。
//! - 網路位址轉型與解析 (Host & Port 解析、IP 位址轉 POSIX 佈局)。
//! - 本機 TCP 連線可達性檢測 (DNS 解析與阻塞式連線)。
//! - 本地時間維護時段判斷 (02:00 - 02:04 跳過更新邏輯)。
//! - HTTP 請求 URL 編碼與 Basic Auth 認證標頭生成。

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

/// Windows 專用的 Winsock 系統初始化資訊結構體 (WSADATA)。
///
/// 當在 Windows 系統呼叫 WSAStartup 時，系統會將 Windows Sockets 實作的詳細資訊填入此結構。
/// 雖然本程式目前不直接讀取這些欄位，但配置的記憶體佈局必須嚴格符合 Win32 ABI。
pub const WSADATA = extern struct {
    /// 呼叫端預期使用的 Windows Sockets 規範版本 (例如 0x0202 代表 2.2 版本)。
    wVersion: u16,
    /// 此 DLL 可支援的 Windows Sockets 規範最高版本。
    wHighVersion: u16,
    /// 描述 Windows Sockets 實作特性的 Null 結尾字串。
    szDescription: [257]u8,
    /// 描述狀態或設定資訊的 Null 結尾字串。
    szSystemStatus: [129]u8,
    /// 可同時開啟的最大 Socket 數量 (在版本 2.2 後已被忽略)。
    iMaxSockets: u16,
    /// 原始資料包 (Datagram) 的最大長度 (在版本 2.2 後已被忽略)。
    iMaxUdpDg: u16,
    /// 指向供應商特定資訊的指標 (在版本 2.2 後已被忽略)。
    lpVendorInfo: ?[*:0]u8,
};

/// 依據作業系統條件編譯導出 Windows Sockets API (ws2_32.dll)。
///
/// 若目前編譯目標為 Windows 系統，則導出 WSAStartup、closesocket 與 connect 等系統 API；
/// 若為 Linux 或其他 POSIX 系統，則導出空結構體，確保編譯不會出錯。
pub const ws2_32 = if (builtin.os.tag == .windows) struct {
    /// 初始化 Windows Sockets DLL。每個使用 Socket 的 Windows 行程都必須在最開始呼叫此函數。
    ///
    /// - `wVersionRequired`: 請求的最高 Winsock 版本 (高位元組為主版本，低位元組為副版本)。
    /// - `lpWSAData`: 接收 Winsock 詳細資訊的結構體指標。
    /// - 回傳值: 成功時回傳 0，失敗時回傳特定的錯誤代碼。
    pub extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSADATA) callconv(.winapi) c_int;
    
    /// 關閉 Windows 系統的 Socket。
    ///
    /// - `s`: 要關閉的 Windows Socket控制代碼 (Handle)。
    /// - 回傳值: 成功時回傳 0，失敗時回傳 -1 (SOCKET_ERROR)。
    pub extern "ws2_32" fn closesocket(s: std.posix.socket_t) callconv(.winapi) c_int;
    
    /// 對指定的 Windows Socket 建立 TCP 連線。
    ///
    /// - `s`: 已建立的 Socket 描述符。
    /// - `name`: 指向 sockaddr 結構體的指標，內含目標 IP 與 Port。
    /// - `namelen`: sockaddr 結構體的長度。
    /// - 回傳值: 成功時回傳 0，失敗時回傳 -1 (SOCKET_ERROR)。
    pub extern "ws2_32" fn connect(s: std.posix.socket_t, name: ?*const anyopaque, namelen: c_int) callconv(.winapi) c_int;
} else struct {};

/// 行程內 Windows Sockets 是否已經啟動的狀態變數。
pub var windows_sockets_started = false;

/// 確保 Windows Sockets 驅動程式已正確啟動。
///
/// 本函數會檢查當前平台，若為 Windows 且尚未初始化 Winsock，
/// 則調用 `WSAStartup` 載入網路 DLL (版本 2.2)。
/// 若為 Linux/WSL 等 POSIX 環境，則無須執行任何動作直接回傳。
pub fn ensureWindowsSocketsStarted() !void {
    if (comptime builtin.os.tag != .windows) return;
    if (windows_sockets_started) return;

    var data: WSADATA = undefined;
    // 傳入 0x0202 要求初始化 Winsock 2.2
    const rc = ws2_32.WSAStartup(0x0202, &data);
    if (rc != 0) return error.WindowsSocketStartupFailed;
    windows_sockets_started = true;
}

/// 將底層 C API 回傳的 Socket 轉型為 Zig 標準庫通用的 `std.posix.socket_t`。
///
/// 在 Windows 上，Socket 本質上是個 Handle (指標長度的不透明指針)；
/// 而在 Linux/Unix 上，Socket 則是一個帶正負號的 32 位元整數描述符。
/// 透過編譯期 (comptime) 判定，使用 `@ptrFromInt` 與 `@bitCast` 進行無開銷的位元級安全轉型。
pub fn castSocket(rc: anytype) std.posix.socket_t {
    if (comptime builtin.os.tag == .windows) {
        return @ptrFromInt(@as(usize, @bitCast(@as(isize, rc))));
    } else {
        return @intCast(rc);
    }
}

/// 建立跨平台的 UDP Socket。
///
/// - `family`: 協議族，例如 `AF.INET` (IPv4) 或 `AF.INET6` (IPv6)。
/// - 針對 Windows 與 POSIX 系統，自動附加 `SOCK.CLOEXEC` 旗標以防止子行程洩漏描述符。
/// - 回傳值: 建立成功的 Socket 描述符，或回傳 `SocketCreationFailed` 錯誤。
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

/// 建立跨平台的 TCP Socket。
///
/// - `family`: 協議族，例如 `AF.INET` (IPv4) 或 `AF.INET6` (IPv6)。
/// - 用於檢測目標 TCP 連接埠的可達性。
/// - 回傳值: 建立成功的 Socket 描述符，或回傳 `SocketCreationFailed` 錯誤。
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

/// 跨平台關閉指定的 Socket。
///
/// - `fd`: 要關閉的 Socket 描述符。
/// - Windows 系統會調用 `closesocket()`，而 Linux/Unix 則直接呼叫 POSIX `close()`。
pub fn closeSocket(fd: std.posix.socket_t) void {
    if (comptime builtin.os.tag == .windows) {
        _ = ws2_32.closesocket(fd);
    } else {
        _ = std.posix.system.close(fd);
    }
}

/// 跨平台建立 Socket 連線。
///
/// - `fd`: 已建立的 Socket 描述符。
/// - `addr`: 目標系統位址結構 (例如 sockaddr_in 或 sockaddr_in6)。
/// - `len`: 位址結構的記憶體大小。
pub fn connectSocket(fd: std.posix.socket_t, addr: anytype, len: std.posix.socklen_t) !void {
    if (comptime builtin.os.tag == .windows) {
        const rc = ws2_32.connect(fd, @ptrCast(addr), @intCast(len));
        if (rc == -1) return error.ConnectionFailed;
    } else {
        const rc = std.posix.system.connect(fd, @ptrCast(addr), len);
        if (rc == -1) return error.ConnectionFailed;
    }
}

/// 設定 Socket 接收資料的逾時時間 (SO_RCVTIMEO)。
///
/// - `fd`: 目標 Socket 描述符。
/// - `timeout_val`: 包含秒數與微秒數的 timeval 結構體。
pub fn setSocketTimeout(fd: std.posix.socket_t, timeout_val: std.posix.timeval) !void {
    const opt_bytes = std.mem.asBytes(&timeout_val);
    const rc = std.posix.system.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        opt_bytes.ptr,
        @intCast(opt_bytes.len),
    );
    if (rc == -1) {
        return error.SetSocketTimeoutFailed;
    }
}

/// UDP Socket 發送資料包的跨平台封裝函數。
///
/// - `fd`: 已建立的 UDP Socket。
/// - `buf`: 要發送的二進位資料緩衝區。
/// - `flags`: 系統發送旗標，預設傳入 0。
/// - `dest_addr`: 目標主機的 socket 位址資訊。
/// - `addrlen`: 位址資訊結構體的長度。
/// - 回傳值: 成功發送的位元組數。
pub fn sendtoSocket(
    fd: std.posix.socket_t,
    buf: []const u8,
    flags: u32,
    dest_addr: *const std.posix.sockaddr,
    addrlen: std.posix.socklen_t,
) !usize {
    const rc = std.posix.system.sendto(
        fd,
        buf.ptr,
        @intCast(buf.len),
        @intCast(flags),
        dest_addr,
        addrlen,
    );
    if (rc == -1) {
        return error.SendFailed;
    }
    return @intCast(rc);
}

/// UDP Socket 接收資料包的跨平台封裝函數。
///
/// - `fd`: 處於監聽或等待狀態的 UDP Socket。
/// - `buf`: 用於接收資料的緩衝區。
/// - `flags`: 系統接收旗標，預設傳入 0。
/// - `src_addr`: 接收來源端主機的 socket 位址資訊。
/// - `addrlen`: 接收來源端的位址結構體長度指標。
/// - 回傳值: 成功接收到的實際位元組數。
pub fn recvfromSocket(
    fd: std.posix.socket_t,
    buf: []u8,
    flags: u32,
    src_addr: *std.posix.sockaddr,
    addrlen: *std.posix.socklen_t,
) !usize {
    const rc = std.posix.system.recvfrom(
        fd,
        buf.ptr,
        @intCast(buf.len),
        @intCast(flags),
        src_addr,
        addrlen,
    );
    if (rc == -1) {
        return error.ReceiveFailed;
    }
    return @intCast(rc);
}

/// 將 Zig 高階 `std.Io.net.IpAddress` 轉換為底層 C ABI 規格的 POSIX 網路位址聯集。
///
/// 由於 Zig 的 `IpAddress` 是適合 Zig 的抽象表示，但在進行底層的 socket 連線或發送系統呼叫時，
/// 必須傳入 C ABI 相容的 `sockaddr_in` (IPv4) 或 `sockaddr_in6` (IPv6) 結構。
/// 此函數會自動處理 Port 位元組順序 (Endianness) 至網路位元組順序 (Big Endian) 的轉換。
pub fn ipAddressToPosix(a: std.Io.net.IpAddress) union(enum) {
    /// 包含 C ABI 相容的 IPv4 網路位址結構。
    ip4: std.posix.sockaddr.in,
    /// 包含 C ABI 相容的 IPv6 網路位址結構。
    ip6: std.posix.sockaddr.in6,
} {
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

/// 解析含有 Host 與 Port 的位址字串 (支援標準格式與 IPv6 中括號格式)。
///
/// 支援以下兩種輸入格式：
/// 1. 標準 IPv4 或網域名稱格式，例如: `127.0.0.1:6379` 或 `localhost:6379`
/// 2. 含有中括號包覆的 IPv6 格式，例如: `[::1]:6379`
///
/// - `addr`: 待解析的字串 slice。
/// - 回傳值: 解析成功後回傳含有 `host` 與 `port` 的結構體，若字串不合規範則拋出 `InvalidRedisAddress`。
pub fn parseHostPort(addr: []const u8) !struct { host: []const u8, port: u16 } {
    if (addr.len == 0) return error.InvalidRedisAddress;
    // 檢查是否為 IPv6 的中括號寫法
    if (addr[0] == '[') {
        const end_index = std.mem.indexOfScalar(u8, addr, ']') orelse return error.InvalidRedisAddress;
        if (end_index + 2 > addr.len or addr[end_index + 1] != ':') return error.InvalidRedisAddress;
        const host = addr[1..end_index];
        const port = try std.fmt.parseUnsigned(u16, addr[end_index + 2 ..], 10);
        return .{ .host = host, .port = port };
    } else {
        // 標準主機位址:連接埠號格式
        const colon_index = std.mem.indexOfScalar(u8, addr, ':') orelse return error.InvalidRedisAddress;
        const host = addr[0..colon_index];
        const port = try std.fmt.parseUnsigned(u16, addr[colon_index + 1 ..], 10);
        return .{ .host = host, .port = port };
    }
}

/// 測試目標 TCP 伺服器是否可以建立連線 (常規阻塞式 TCP 連線檢測)。
///
/// 適用於程式啟動時，檢查 Redis 伺服器是否能順利連接。
/// 若傳入主機名 (Host)，會先使用 `std.Io.net.HostName` 透過背景佇列異步解析 DNS，
/// 接著嘗試連接，確保若連接埠不通時，不會阻斷主排程器載入。
///
/// - `allocator`: 用於 DNS 解析時需要的記憶體分配器 (在此由介面傳入，暫不分配)。
/// - `io`: 執行異步操作所需的 I/O 引擎。
/// - `host`: 伺服器主機名或 IP 地址。
/// - `port`: 目標 TCP 連接埠。
pub fn checkTcpPortReachable(allocator: std.mem.Allocator, io: std.Io, host: []const u8, port: u16) !void {
    _ = allocator;
    try ensureWindowsSocketsStarted();

    // 優先嘗試解析成 IP，若解析失敗則代表是域名，進入 DNS Lookup
    const ip_addr = std.Io.net.IpAddress.parse(host, port) catch blk: {
        const host_name = try std.Io.net.HostName.init(host);

        var canonical_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        var lookup_buffer: [1]std.Io.net.HostName.LookupResult = undefined;
        var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
        // 送出 DNS 背景查詢工作
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

    // 建立阻塞式 TCP 連線，完成可達性測試
    switch (posix_addr) {
        .ip4 => |*addr| try connectSocket(socket, addr, @sizeOf(std.posix.sockaddr.in)),
        .ip6 => |*addr| try connectSocket(socket, addr, @sizeOf(std.posix.sockaddr.in6)),
    }
}

/// 檢查目前本地時間是否正落在凌晨維護時段 (02:00 - 02:04)。
///
/// 這是為了解決特定 DDNS 供應商在每日凌晨重置或維護而產生的連線阻斷問題。
/// 支援跨平台獲取時間：
/// - Windows: 呼叫 Win32 `GetLocalTime` 取得 `SYSTEMTIME` 結構。
/// - Linux / POSIX: 呼叫 C `localtime_r` 將 `time_t` 轉換為本地時間結構。
pub fn shouldSkipMaintenanceWindow() bool {
    if (builtin.os.tag == .windows) {
        // Win32 SYSTEMTIME 結構體佈局。
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

/// 判斷傳入的小時與分鐘是否在維護時間區間 (02:00 - 02:04) 內。
///
/// - `hour`: 小時 (0 - 23)。
/// - `minute`: 分鐘 (0 - 59)。
/// - 回傳值: 若落在該時段回傳 `true`，否則為 `false`。
pub fn shouldSkipMaintenanceWindowAt(hour: c_int, minute: c_int) bool {
    return hour == 2 and minute >= 0 and minute < 5;
}

/// 判斷指定的字元是否為 RFC 3986 規範中不需進行百分比編碼的字元 (Unreserved)。
///
/// 包含所有英文字母、數字以及 `-`、`_`、`.`、`~`。
pub fn isUnreservedUrlByte(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~';
}

/// 將字串值進行 URL 百分比編碼 (Percent-Encoding) 並追加至指定的 ArrayList 中。
///
/// 非 unreserved 字元會被轉化成 `%XX` 的十六進位格式 (例如空格會轉為 `%20`)。
///
/// - `buffer`: 指向存放編碼結果的 ArrayList 緩衝區。
/// - `allocator`: 用於動態調整緩衝區大小的分配器。
/// - `value`: 需要被 URL 編碼的原始字串。
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

/// 格式化一個 URL Query Parameter 片段 (例如 `key=value`) 並追加至 ArrayList。
///
/// - `buffer`: 目標 ArrayList 緩衝區。
/// - `allocator`: 分配器指標。
/// - `key`: Query 鍵值名稱。
/// - `value`: 待編碼的參數數值。
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

/// 將使用者帳號密碼格式化為 HTTP Basic Authorization 認證字串。
///
/// 處理步驟：
/// 1. 將帳密拼接為 `username:password`。
/// 2. 使用 Base64 演算法對該拼接字串進行編碼。
/// 3. 加上 `Basic ` 前綴並回傳結果。
///
/// - `allocator`: 用於生成拼接與 Base64 編碼字串的記憶體分配器。
/// - `username`: 認證帳號。
/// - `password`: 認證密碼。
/// - 回傳值: 配置於 Heap 上的 `Basic Base64String` 認證字串，呼叫端需負責釋放該字串記憶體。
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
