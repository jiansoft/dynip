//! 共用的 HTTP 文字請求與日誌輔助工具。
//!
//! 這個模組目前支援：
//! - GET / POST 等文字型 HTTP 請求。
//! - 直接送出 JSON request body。
//! - 統一管理 standard headers / extra headers / privileged headers。
//! - 連線 timeout 設定。
//! - 整理 HTTP 日誌，避免把敏感資訊直接寫進 log。

/// 匯入 Zig 標準函式庫。
///
/// HTTP 客戶端、JSON、ArrayList、字串處理與 log 都由這裡提供。
const std = @import("std");
const default_accept_encoding: [@typeInfo(std.http.ContentEncoding).@"enum".fields.len]bool = initDefaultAcceptEncoding();

/// 建立 HTTP 專用的日誌分類。
///
/// 之後用 `http_log.info(...)` 時，日誌會標記成 `(http)`。
const http_log = std.log.scoped(.http);

/// `urlForLog` 需要的暫存緩衝區長度。
///
/// 因為這個模組不想為了寫 log 額外配置記憶體，
/// 所以會先準備固定大小的 stack 緩衝區來複製網址。
pub const log_url_buffer_len: usize = 512;

/// `bodyPreviewForLog` 需要的暫存緩衝區長度。
///
/// HTTP 回應內容可能很大，不適合整份都寫進 log，
/// 所以只會取前面一小段做預覽。
pub const body_preview_len: usize = 256;

/// 單次 HTTP 文字請求的結果。
///
/// `status` 是 HTTP 狀態碼，`body` 是整份 HTTP 回應內容。
pub const FetchTextResponse = struct {
    /// 伺服器回的 HTTP 狀態碼，例如 200、404、500。
    status: std.http.Status,
    /// 完整 HTTP 回應內容。
    ///
    /// 呼叫端拿到後，要自己決定何時 `allocator.free(...)`。
    body: []u8,
};

/// 控制單次 HTTP request 的 timeout 行為。
///
/// 目前 Zig 標準庫最穩定可控制的是 connect 階段，
/// 因此這裡先提供 `connect` timeout。
pub const RequestTimeouts = struct {
    /// DNS lookup / TCP connect / TLS connect 階段的 timeout。
    ///
    /// 預設用 `.none`，
    /// 代表如果呼叫端沒有特別指定，就不主動在 connect 階段超時。
    connect: std.Io.Timeout = .none,
};

/// 控制 standard headers 與額外 headers 的策略。
///
/// `standard` 對應 Zig 標準庫的 overridable headers，
/// `extra_headers` 會無條件附加，
/// `privileged_headers` 則會在跨網域 redirect 時自動剝除。
pub const HeaderPolicy = struct {
    /// Zig 標準庫內建的 overridable headers。
    ///
    /// 預設會把 `accept-encoding` 設成 `omit`，
    /// 讓這個專案維持目前不主動要求壓縮回應的行為。
    standard: std.http.Client.Request.Headers = .{
        // 這裡預設把 `accept-encoding` 設成 `.omit`，
        // 代表標準庫不要自動送出這個 header。
        // 這樣做的原因是：目前這個專案希望拿到較單純的原始文字回應。
        .accept_encoding = .omit,
    },
    /// 不論 redirect 與否都保留的 headers。
    extra_headers: []const std.http.Header = &.{},
    /// 跨網域 redirect 時會被移除的敏感 headers。
    privileged_headers: []const std.http.Header = &.{},
    /// Accept-Encoding 的啟用清單。
    ///
    /// 只有當 `standard.accept_encoding` 不是 `.omit` 時才會生效。
    /// 預設至少會接受 `identity`，
    /// 這樣就算我們沒有主動送出 `Accept-Encoding`，也能正常讀取未壓縮回應。
    accept_encoding: [@typeInfo(std.http.ContentEncoding).@"enum".fields.len]bool = default_accept_encoding,
};

/// 單次 HTTP 文字 request 的完整選項。
pub const RequestTextOptions = struct {
    /// HTTP method，例如 GET / POST。
    ///
    /// 預設是 GET，因為這個專案最常見的情境仍是純文字查詢。
    method: std.http.Method = .GET,
    /// 要送出的 request body。
    ///
    /// 當 method 不允許 body 時，若此欄位非空會回傳錯誤。
    body: ?[]const u8 = null,
    /// header 行為。
    headers: HeaderPolicy = .{},
    /// timeout 設定。
    timeouts: RequestTimeouts = .{},
    /// 是否重用連線。
    ///
    /// 預設開啟 keep-alive，讓同一個 client 可以重複利用連線。
    keep_alive: bool = true,
};

/// 送出 JSON request body 時的選項。
pub const RequestJsonOptions = struct {
    /// 底層 HTTP request 選項。
    request: RequestTextOptions = .{
        // JSON request 最常見是 POST，所以這裡直接給一個合理預設。
        .method = .POST,
    },
    /// JSON 序列化選項。
    stringify: std.json.Stringify.Options = .{},
};

/// 發出單次 HTTP 文字 request，並把回應內容收成字串。
pub fn requestText(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    options: RequestTextOptions,
) !FetchTextResponse {
    // 先建立一個可成長的位元組陣列，
    // 稍後會把整份 HTTP response body 收進這裡。
    var body = std.ArrayList(u8).empty;
    // 如果函式中途失敗，這塊 ArrayList 要自動回收。
    errdefer body.deinit(allocator);

    // 把 ArrayList 包成 writer，
    // 這樣底層 HTTP reader 就能直接把資料串流寫進來。
    var response_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body);
    // 如果後面任何一步失敗，也要把 writer 自己管理的資源清掉。
    errdefer response_writer.deinit();

    // 準備一塊固定大小的 stack buffer，
    // 專門拿來生成「適合進 log 的安全網址字串」。
    var log_url_buffer: [log_url_buffer_len]u8 = undefined;
    // 這裡不直接用原始 URL 寫 log，
    // 而是先做敏感資訊遮罩後再使用。
    const log_url = urlForLog(&log_url_buffer, url);
    // 在真正送 request 前先記一筆 request log，
    // 方便之後排查到底打了哪個 method / URL。
    logHttpRequest(options.method, log_url, options.body);

    // 真正執行 HTTP request，
    // 並把收到的 response body 串流寫進上面的 response_writer。
    const result = executeRequest(
        allocator,
        client,
        url,
        options,
        log_url,
        &response_writer.writer,
    ) catch |err| {
        // 這裡不額外包裝錯誤，直接把底層 HTTP 錯誤往外拋，
        // 讓上層自己決定怎麼處理。
        return err;
    };

    // 把 writer 暫時持有的 ArrayList 所有權拿回來。
    body = response_writer.toArrayList();
    // 根據狀態碼與 body 預覽寫一筆 response log。
    logHttpResponse(options.method, log_url, result.status, body.items);

    // 最後把 ArrayList 轉成呼叫端可持有的 owned slice 回傳。
    return .{
        // 回傳 HTTP 狀態碼。
        .status = result.status,
        // 回傳完整 body 內容。
        .body = try body.toOwnedSlice(allocator),
    };
}

/// 發出單次 GET 請求並把回應內容收成字串。
///
/// 這是為了沿用既有呼叫點而保留的相容 API。
pub fn fetchText(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    extra_headers: []const std.http.Header,
    options: struct { connect_timeout: std.Io.Timeout },
) !FetchTextResponse {
    // 這個相容 API 的作用是把舊式 `fetchText(...)` 呼叫，
    // 轉接到新的 `requestText(...)` 選項式 API。
    return requestText(allocator, client, url, .{
        // 舊 API 只接受 extra headers，所以這裡把它填進新結構的對應欄位。
        .headers = .{ .extra_headers = extra_headers },
        // 舊 API 的 connect timeout 也轉成新結構裡的 `timeouts.connect`。
        .timeouts = .{ .connect = options.connect_timeout },
    });
}

/// 將任意 Zig 值序列化成 JSON 後送出 HTTP request。
///
/// 預設會用 `POST`，並在沒有覆寫時自動補上
/// `Content-Type: application/json`。
pub fn requestJson(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    value: anytype,
    options: RequestJsonOptions,
) !FetchTextResponse {
    // 先建立一個可成長的位元組陣列，拿來裝 JSON 序列化後的 request body。
    var request_body = std.ArrayList(u8).empty;
    // 函式離開前要把這塊暫時記憶體釋放掉。
    defer request_body.deinit(allocator);

    // 建立一個會把輸出寫進 `request_body` 的 writer。
    var json_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &request_body);
    // 如果 JSON 序列化失敗，要把 writer 資源清掉。
    errdefer json_writer.deinit();
    // 把任意 Zig 值轉成 JSON 文字，直接寫進 request_body。
    try std.json.Stringify.value(value, options.stringify, &json_writer.writer);
    // 把 writer 暫時接管的 ArrayList 拿回來。
    request_body = json_writer.toArrayList();

    // 先複製一份底層 request 選項，
    // 因為後面要補 body 與 content-type。
    var request_options = options.request;
    // 把剛剛序列化好的 JSON 文字掛到 request body。
    request_options.body = request_body.items;
    // 如果呼叫端沒有自己指定 Content-Type，
    // 這裡就自動補成 application/json。
    if (request_options.headers.standard.content_type == .default) {
        request_options.headers.standard.content_type = .{ .override = "application/json" };
    }

    // 最後仍然走統一的 `requestText(...)`，避免維護兩套送 request 邏輯。
    return requestText(allocator, client, url, request_options);
}

/// 確認 HTTP 狀態碼是否為 2xx。
pub fn ensureSuccessStatus(status: std.http.Status, body: []const u8) !void {
    // 只有 2xx 會被視為成功。
    if (status.class() != .success) {
        // 準備一個小 buffer，拿來放 body 的摘要預覽。
        var preview_buffer: [body_preview_len]u8 = undefined;
        // 先把錯誤狀態碼和 body 預覽打進 log，方便除錯。
        std.log.err("unexpected http status {d}: {s}", .{
            @intFromEnum(status),
            bodyPreviewForLog(&preview_buffer, body),
        });
        // 再把統一的 HTTP 失敗錯誤往外拋。
        return error.UnexpectedHttpStatus;
    }
}

/// 將 body 整理成一小段適合寫進 log 的預覽字串。
pub fn bodyPreviewForLog(buffer: []u8, body: []const u8) []const u8 {
    // 如果呼叫端給的 buffer 長度是 0，就根本不可能產生任何預覽。
    if (buffer.len == 0) return "";

    // 如果原始 body 比 buffer 還長，代表最後需要截斷。
    const needs_ellipsis = body.len > buffer.len;
    // 如果要補 `...`，就先預留三個字元的位置。
    const preview_limit = if (needs_ellipsis and buffer.len >= 3) buffer.len - 3 else buffer.len;

    // `out_index` 代表目前已經寫進預覽 buffer 的長度。
    var out_index: usize = 0;
    // `body_index` 代表目前掃到原始 body 的哪個位置。
    var body_index: usize = 0;
    // 逐字掃過 body，把可印出的內容轉成適合寫 log 的預覽。
    while (body_index < body.len and out_index < preview_limit) : (body_index += 1) {
        // 先取出目前這一個字元。
        const char = body[body_index];
        // 把換行 / tab 換成空白，其他不可列印字元換成 `?`，
        // 避免 log 排版被破壞。
        buffer[out_index] = switch (char) {
            '\r', '\n', '\t' => ' ',
            else => if (std.ascii.isPrint(char)) char else '?',
        };
        // 每寫進一個字元，就把輸出位置往後移一格。
        out_index += 1;
    }

    // 如果尾端剛好是空白，就一路往回修掉，
    // 讓預覽字串更乾淨。
    while (out_index > 0 and buffer[out_index - 1] == ' ') {
        out_index -= 1;
    }

    // 如果內容有被截斷，而且 buffer 放得下，
    // 就在尾端補上 `...`。
    if (needs_ellipsis and buffer.len >= 3) {
        buffer[out_index..][0] = '.';
        buffer[out_index..][1] = '.';
        buffer[out_index..][2] = '.';
        // 補了三個點，所以輸出長度也要加 3。
        out_index += 3;
    }

    // 只回傳實際有寫進內容的那一段 slice。
    return buffer[0..out_index];
}

/// 在送出 request 前寫出一筆簡短的 HTTP request 日誌。
fn logHttpRequest(method: std.http.Method, log_url: []const u8, body: ?[]const u8) void {
    // 如果這次 request 有 body，就把 body 長度也一起寫進 log。
    if (body) |request_body| {
        http_log.info(
            "request {s} {s} body_bytes={d}",
            .{ @tagName(method), log_url, request_body.len },
        );
        // 已經寫完有 body 的版本，所以直接 return。
        return;
    }

    // 沒有 body 的情況只記 method 與 URL 即可。
    http_log.info("request {s} {s}", .{ @tagName(method), log_url });
}

/// 產生適合寫進 log 的網址版本，並遮罩敏感值。
fn urlForLog(buffer: []u8, url: []const u8) []const u8 {
    // 如果 URL 太長，連複製進 buffer 都放不下，
    // 就直接回傳固定提示字串，避免越界。
    if (url.len > buffer.len) return "<http-url-too-long>";

    // 先把原始 URL 複製到可修改的 buffer，
    // 後面所有遮罩動作都在這份副本上進行。
    @memcpy(buffer[0..url.len], url);
    // `output` 代表目前這份「可修改、可回傳」的 URL slice。
    const output = buffer[0..url.len];

    // 依序把常見敏感欄位的值遮掉。
    maskQueryValue(output, "username");
    maskQueryValue(output, "password");
    maskQueryValue(output, "token");
    // Afraid 這種把 token 直接放在 query 尾端的格式，也一併遮掉。
    maskQueryTailAfterPrefix(output, "/dynamic/update.php?");
    // 回傳的是遮罩後的 URL，不是原始值。
    return output;
}

/// 根據 method、狀態碼與 body 內容寫出 HTTP response 日誌。
fn logHttpResponse(
    method: std.http.Method,
    log_url: []const u8,
    status: std.http.Status,
    body: []const u8,
) void {
    // 先把整份 body 整理成一小段 log 預覽，
    // 避免把過長回應完整打進日誌。
    var preview_buffer: [body_preview_len]u8 = undefined;
    const body_preview = bodyPreviewForLog(&preview_buffer, body);

    // 2xx 視為成功。
    if (status.class() == .success) {
        http_log.info(
            "response {s} {s} status={d} bytes={d}",
            .{ @tagName(method), log_url, @intFromEnum(status), body.len },
        );
        // 只有 body 預覽不是空的時候，才另外補一筆 debug log。
        if (body_preview.len != 0) {
            http_log.debug(
                "response body {s} {s}: {s}",
                .{ @tagName(method), log_url, body_preview },
            );
        }
        // 成功情況寫完就結束。
        return;
    }

    // 非 2xx 視為錯誤，直接把狀態碼與 body 預覽一起記下來。
    http_log.err(
        "response {s} {s} status={d} bytes={d} body={s}",
        .{ @tagName(method), log_url, @intFromEnum(status), body.len, body_preview },
    );
}

/// 執行單次 HTTP request，並把回應內容寫到指定 writer。
fn executeRequest(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    options: RequestTextOptions,
    log_url: []const u8,
    response_writer: *std.Io.Writer,
) !struct { status: std.http.Status } {
    // 先把字串 URL 解析成 `std.Uri`，
    // 這樣後面才能安全取 host / port / scheme。
    const uri = std.Uri.parse(url) catch |err| {
        http_log.err("invalid request url {s}: {}", .{ log_url, err });
        return err;
    };
    // 根據 URI 推斷這次是 plain HTTP 還是 HTTPS。
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
    // 如果是 TLS，先確保 client 已經準備好 CA bundle 等必要狀態。
    try ensureTlsClientReady(client, protocol);
    // 準備一塊固定大小 buffer，拿來承接 `uri.getHost(...)` 的結果。
    var host_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    // 從 URI 中取出 host，後面 connect 會用到它。
    const host_name = try uri.getHost(&host_name_buffer);
    // 如果 URI 沒明確指定 port，就依照協定套用預設埠號。
    const port: u16 = uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
    // 這裡用的是 Zig 的 method-call 語法糖：
    // `client.connectTcpOptions(x)` 等價於 `std.http.Client.connectTcpOptions(client, x)`。
    const connection = client.connectTcpOptions(.{
        .host = host_name,
        .port = port,
        .protocol = protocol,
        .timeout = options.timeouts.connect,
    }) catch |err| {
        // connect 失敗時先記錄細節，再把錯誤往外丟。
        http_log.err(
            "request connect {s} {s} failed: {}",
            .{ @tagName(options.method), log_url, err },
        );
        return err;
    };

    var request = client.request(options.method, uri, .{
        .connection = connection,
        .keep_alive = options.keep_alive,
        .headers = options.headers.standard,
        .extra_headers = options.headers.extra_headers,
        .privileged_headers = options.headers.privileged_headers,
    }) catch |err| {
        // 如果 request 物件建立失敗，通常表示 header / 狀態準備有問題。
        http_log.err("request {s} {s} failed: {}", .{ @tagName(options.method), log_url, err });
        return err;
    };
    // 用完 request 後要記得 deinit，讓底層可以正確回收 / 重用連線。
    defer request.deinit();
    // 把呼叫端指定的 accept-encoding 開關表套進 request。
    request.accept_encoding = options.headers.accept_encoding;

    // 如果有 body，代表這次是帶 payload 的 request，例如 POST。
    if (options.body) |request_body| {
        // 先確認這個 method 在語義上允許 body。
        if (!options.method.requestHasBody()) return error.RequestBodyNotAllowed;
        // 標準庫 `sendBodyComplete` 需要可寫 slice，
        // 所以這裡先把 `[]const u8` 複製成 `[]u8`。
        const mutable_body = try allocator.dupe(u8, request_body);
        // 送完之後就不再需要這塊 mutable 複本，所以用 defer 釋放。
        defer allocator.free(mutable_body);
        // 一次把整份 body 送出去。
        request.sendBodyComplete(mutable_body) catch |err| {
            http_log.err(
                "request send {s} {s} failed: {}",
                .{ @tagName(options.method), log_url, err },
            );
            return err;
        };
    } else {
        // 沒有 body 時，就走純 header 的 bodiless request 路徑。
        request.sendBodiless() catch |err| {
            http_log.err(
                "request send {s} {s} failed: {}",
                .{ @tagName(options.method), log_url, err },
            );
            return err;
        };
    }

    // redirect buffer 是 `receiveHead(...)` 內部處理 redirect 時需要的暫存空間。
    var redirect_buffer: [8 * 1024]u8 = undefined;
    // 先收 response head，這一步會拿到狀態碼與各種 header。
    var response = request.receiveHead(&redirect_buffer) catch |err| {
        http_log.err(
            "request receive {s} {s} failed: {}",
            .{ @tagName(options.method), log_url, err },
        );
        return err;
    };
    // 取得 response body 的 reader。
    const reader = response.reader(&.{});
    // 把剩餘 body 全部串流寫進呼叫端提供的 response_writer。
    _ = reader.streamRemaining(response_writer) catch |err| {
        http_log.err(
            "response read {s} {s} failed: {}",
            .{ @tagName(options.method), log_url, err },
        );
        return err;
    };
    // 回傳這次 response 的 HTTP 狀態碼。
    return .{ .status = response.head.status };
}

/// 顯式走 `connectTcpOptions(...)` 前，先補齊 request() 預設會做的 TLS 初始化。
fn ensureTlsClientReady(
    client: *std.http.Client,
    protocol: std.http.Client.Protocol,
) !void {
    // 只有 HTTPS 才需要 TLS 初始化；純 HTTP 直接跳過。
    if (protocol != .tls) return;
    // 如果編譯時明確禁用了 TLS，這裡就不可能正確建立 HTTPS 連線。
    if (std.http.Client.disable_tls) return error.TlsInitializationFailed;

    // 先把 client 裡的 io 抓出來，後面多處會用到。
    const io = client.io;
    {
        // 先用 shared lock 看看別人是不是已經幫我們初始化過 CA bundle。
        try client.ca_bundle_lock.lockShared(io);
        defer client.ca_bundle_lock.unlockShared(io);
        // 如果 `client.now` 已經不是 null，代表 TLS 狀態已準備好，可以直接返回。
        if (client.now != null) return;
    }

    // 建立一個暫時的 certificate bundle，準備掃描系統憑證。
    var bundle: std.crypto.Certificate.Bundle = .empty;
    // 這個暫時 bundle 用完要釋放。
    defer bundle.deinit(client.allocator);
    // 取得目前時間，TLS 憑證驗證會需要它。
    const now = std.Io.Clock.real.now(io);
    // 重新掃描系統憑證。
    bundle.rescan(client.allocator, io, now) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.CertificateBundleLoadFailure,
    };

    // 前面 shared lock 檢查完後，這裡改拿獨占 lock，
    // 真正把剛剛準備好的 bundle 寫回 client。
    try client.ca_bundle_lock.lock(io);
    defer client.ca_bundle_lock.unlock(io);
    // 記錄這次初始化時使用的時間。
    client.now = now;
    // 用 swap 把新的 CA bundle 放進 client，同時把舊值換到暫時變數裡等待 deinit。
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

/// 遮罩 query string 裡某個 key 的值。
fn maskQueryValue(text: []u8, key: []const u8) void {
    var start_index: usize = 0;

    while (std.mem.indexOfPos(u8, text, start_index, key)) |key_index| {
        const equals_index = key_index + key.len;
        if (equals_index >= text.len or text[equals_index] != '=') {
            start_index = equals_index;
            continue;
        }

        if (key_index != 0 and text[key_index - 1] != '?' and text[key_index - 1] != '&') {
            start_index = equals_index;
            continue;
        }

        var value_end = equals_index + 1;
        while (value_end < text.len and text[value_end] != '&' and text[value_end] != '#') : (value_end += 1) {}

        maskSlice(text[equals_index + 1 .. value_end]);
        start_index = value_end;
    }
}

/// 遮罩像 `/dynamic/update.php?<token>` 這種 query 尾端 token。
fn maskQueryTailAfterPrefix(text: []u8, prefix: []const u8) void {
    const prefix_index = std.mem.indexOf(u8, text, prefix) orelse return;
    const value_start = prefix_index + prefix.len;
    var value_end = value_start;

    while (value_end < text.len and text[value_end] != '&' and text[value_end] != '#') : (value_end += 1) {}
    maskSlice(text[value_start..value_end]);
}

/// 把一段字串全部改成 `*`。
fn maskSlice(text: []u8) void {
    for (text) |*char| {
        char.* = '*';
    }
}

fn initDefaultAcceptEncoding() [@typeInfo(std.http.ContentEncoding).@"enum".fields.len]bool {
    var result: [@typeInfo(std.http.ContentEncoding).@"enum".fields.len]bool = @splat(false);
    result[@intFromEnum(std.http.ContentEncoding.identity)] = true;
    return result;
}

test "url for log masks afraid token and dynu password" {
    var afraid_buffer: [log_url_buffer_len]u8 = undefined;
    const afraid_url = urlForLog(&afraid_buffer, "https://freedns.afraid.org/dynamic/update.php?secret-token");
    try std.testing.expectEqualStrings("https://freedns.afraid.org/dynamic/update.php?************", afraid_url);

    var dynu_buffer: [log_url_buffer_len]u8 = undefined;
    const dynu_url = urlForLog(
        &dynu_buffer,
        "https://api.dynu.com/nic/update?username=demo&password=abcdef&myip=1.2.3.4",
    );
    try std.testing.expectEqualStrings(
        "https://api.dynu.com/nic/update?username=****&password=******&myip=1.2.3.4",
        dynu_url,
    );
}

test "body preview for log removes line breaks" {
    var buffer: [32]u8 = undefined;
    const preview = bodyPreviewForLog(&buffer, "nochg 1.2.3.4\r\n");
    try std.testing.expectEqualStrings("nochg 1.2.3.4", preview);
}

test "request json defaults to post and json content type" {
    var options = RequestJsonOptions{};
    try std.testing.expectEqual(std.http.Method.POST, options.request.method);
    try std.testing.expect(options.request.headers.standard.content_type == .default);

    if (options.request.headers.standard.content_type == .default) {
        options.request.headers.standard.content_type = .{ .override = "application/json" };
    }
    try std.testing.expectEqualStrings(
        "application/json",
        options.request.headers.standard.content_type.override,
    );
}

test "request text options keep get bodiless by default" {
    const options = RequestTextOptions{};
    try std.testing.expectEqual(std.http.Method.GET, options.method);
    try std.testing.expect(options.body == null);
    try std.testing.expect(options.headers.standard.accept_encoding == .omit);
    try std.testing.expect(options.headers.accept_encoding[@intFromEnum(std.http.ContentEncoding.identity)]);
    try std.testing.expectEqual(std.Io.Timeout.none, options.timeouts.connect);
}
