//! 共用的 HTTP 文字抓取與日誌輔助工具。
//!
//! 這個模組負責兩件事：
//! - 發出簡單的 GET 請求，並把 body 收成字串。
//! - 整理 HTTP 日誌，避免把敏感資訊直接寫進 log。

/// 匯入 Zig 標準函式庫。
///
/// HTTP client、ArrayList、字串處理與 log 都由這裡提供。
const std = @import("std");

/// 建立 HTTP 專用的 log scope。
///
/// 之後用 `http_log.info(...)` 時，日誌會標記成 `(http)`。
const http_log = std.log.scoped(.http);

/// `urlForLog` 需要的暫存 buffer 長度。
///
/// 因為這個模組不想為了寫 log 額外配置記憶體，
/// 所以會先準備固定大小的 stack buffer 來複製網址。
pub const log_url_buffer_len: usize = 512;

/// `bodyPreviewForLog` 需要的暫存 buffer 長度。
///
/// response body 可能很大，不適合整份都寫進 log，
/// 所以只會取前面一小段做預覽。
pub const body_preview_len: usize = 256;

/// 單次 HTTP GET 的結果。
///
/// `status` 是 HTTP 狀態碼，`body` 是整份 response body。
pub const FetchTextResponse = struct {
    /// 伺服器回的 HTTP 狀態碼，例如 200、404、500。
    status: std.http.Status,
    /// 完整 response body。
    ///
    /// 呼叫端拿到後，要自己決定何時 `allocator.free(...)`。
    body: []u8,
};

/// 發出單次 GET 請求並把 body 收成字串。
pub fn fetchText(
    // 這個 allocator 用來配置 response body 與暫時字串。
    allocator: std.mem.Allocator,
    // 呼叫端建立好的 HTTP client。
    client: *std.http.Client,
    // 要請求的完整網址。
    url: []const u8,
    // 額外 HTTP header，例如 Authorization。
    extra_headers: []const std.http.Header,
) !FetchTextResponse {
    // 先建立一個空的 ArrayList，稍後把 response body 一段一段寫進來。
    var body = std.ArrayList(u8).empty;
    // `errdefer` 的意思是：
    // 只有在函式以 error 提前結束時，才會執行這行清理。
    errdefer body.deinit(allocator);

    // `std.Io.Writer.Allocating.fromArrayList(...)` 會把 ArrayList 包成一個 writer。
    // 這樣 HTTP client 在收到 body 時，就可以直接把資料寫進 `body`。
    var response_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body);
    // 如果中途發生錯誤，也要把 writer 自己持有的資源清掉。
    errdefer response_writer.deinit();

    // 這塊固定大小的 buffer 用來產生「適合寫進 log 的網址字串」。
    var log_url_buffer: [log_url_buffer_len]u8 = undefined;
    // `urlForLog(...)` 會把敏感值遮掉，例如 token、password。
    const log_url = urlForLog(&log_url_buffer, url);
    // 在真正送出請求前，先寫一筆 request log。
    http_log.info("request GET {s}", .{log_url});

    // `client.fetch(...)` 是 Zig 標準庫的高階 HTTP API。
    // 這裡指定：
    // - `.location.url`：要打的網址
    // - `.method`：HTTP 方法，這裡是 GET
    // - `.response_writer`：把 body 寫到哪裡
    // - `.extra_headers`：額外 header
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_writer.writer,
        .extra_headers = extra_headers,
    }) catch |err| {
        // 如果連線、TLS、DNS 或傳輸過程出錯，
        // 就先寫 error log，再把錯誤往外丟給呼叫端。
        http_log.err("request GET {s} failed: {}", .{ log_url, err });
        return err;
    };

    // `fromArrayList` 之後，response body 先暫時放在 `response_writer` 手上。
    // 要把 ownership 交回 `body`，`body.items` 才會真正指向內容。
    body = response_writer.toArrayList();
    // 寫一筆 response log，內容包含 status code 和 body 預覽。
    logHttpResponse(log_url, result.status, body.items);

    // `toOwnedSlice(...)` 會把 ArrayList 轉成「真正屬於呼叫端」的 slice。
    // 這樣函式回傳後，呼叫端只需要在用完時 free 這個 slice 即可。
    return .{
        .status = result.status,
        .body = try body.toOwnedSlice(allocator),
    };
}

/// 確認 HTTP 狀態碼是否為 2xx。
pub fn ensureSuccessStatus(status: std.http.Status, body: []const u8) !void {
    // `status.class()` 會把 200、201 這種狀態碼歸類成 `.success`。
    if (status.class() != .success) {
        // 先準備一塊 buffer，拿來做 body 預覽。
        var preview_buffer: [body_preview_len]u8 = undefined;
        // 這裡不直接把整份 body 打進 log，
        // 避免 body 太長、太亂，或含有不適合完整輸出的內容。
        std.log.err("unexpected http status {d}: {s}", .{
            @intFromEnum(status),
            bodyPreviewForLog(&preview_buffer, body),
        });
        // 用 error union 把錯誤回傳出去，讓上層自己決定怎麼處理。
        return error.UnexpectedHttpStatus;
    }
}

/// 將 body 整理成一小段適合寫進 log 的預覽字串。
pub fn bodyPreviewForLog(buffer: []u8, body: []const u8) []const u8 {
    // 如果呼叫端給的 buffer 長度是 0，就不可能放進任何字元，
    // 直接回空字串。
    if (buffer.len == 0) return "";

    // 如果 body 比 buffer 還長，代表預覽內容會被截斷，
    // 後面可以視情況補上 `...`。
    const needs_ellipsis = body.len > buffer.len;
    // 如果要補 `...`，就要先預留 3 個字元的位置。
    const preview_limit = if (needs_ellipsis and buffer.len >= 3) buffer.len - 3 else buffer.len;

    // `out_index` 指向目前寫到 buffer 的哪個位置。
    var out_index: usize = 0;
    // `body_index` 指向目前讀到 body 的哪個位置。
    var body_index: usize = 0;
    // 逐字掃過 body，把適合印出的字元寫進 buffer。
    while (body_index < body.len and out_index < preview_limit) : (body_index += 1) {
        const char = body[body_index];
        // 把換行和 tab 轉成空白，避免 log 排版亂掉。
        // 如果遇到不可印的字元，就改成 `?`。
        buffer[out_index] = switch (char) {
            '\r', '\n', '\t' => ' ',
            else => if (std.ascii.isPrint(char)) char else '?',
        };
        out_index += 1;
    }

    // 如果尾端剛好是空白，就往回修剪掉。
    while (out_index > 0 and buffer[out_index - 1] == ' ') {
        out_index -= 1;
    }

    // 如果內容被截斷，而且 buffer 放得下，
    // 就在尾端補上 `...`。
    if (needs_ellipsis and buffer.len >= 3) {
        buffer[out_index..][0] = '.';
        buffer[out_index..][1] = '.';
        buffer[out_index..][2] = '.';
        out_index += 3;
    }

    return buffer[0..out_index];
}

/// 產生適合寫進 log 的網址版本，並遮罩敏感值。
fn urlForLog(buffer: []u8, url: []const u8) []const u8 {
    // 如果網址比 buffer 還長，就不勉強複製，
    // 直接回固定提示字串。
    if (url.len > buffer.len) return "<http-url-too-long>";

    // 先把原始網址完整複製到 buffer。
    // 之後所有遮罩都在這份可修改的副本上進行。
    @memcpy(buffer[0..url.len], url);
    const output = buffer[0..url.len];

    // 依序遮掉幾種常見敏感值。
    maskQueryValue(output, "username");
    maskQueryValue(output, "password");
    maskQueryValue(output, "token");
    maskQueryTailAfterPrefix(output, "/dynamic/update.php?");
    return output;
}

/// 根據狀態碼與 body 內容寫出 HTTP response 日誌。
fn logHttpResponse(
    log_url: []const u8,
    status: std.http.Status,
    body: []const u8,
) void {
    // 用固定大小 buffer 生一份 body 預覽，避免整份 body 直接進 log。
    var preview_buffer: [body_preview_len]u8 = undefined;
    const body_preview = bodyPreviewForLog(&preview_buffer, body);

    // 2xx 當成成功。
    if (status.class() == .success) {
        http_log.info(
            "response GET {s} status={d} bytes={d}",
            .{ log_url, @intFromEnum(status), body.len },
        );
        // 如果 body 預覽不是空的，再額外寫一筆 debug。
        if (body_preview.len != 0) {
            http_log.debug("response body GET {s}: {s}", .{ log_url, body_preview });
        }
        return;
    }

    // 非 2xx 當成錯誤，直接把狀態碼和 body 預覽一起打出來。
    http_log.err(
        "response GET {s} status={d} bytes={d} body={s}",
        .{ log_url, @intFromEnum(status), body.len, body_preview },
    );
}

/// 遮罩 query string 裡某個 key 的值。
fn maskQueryValue(text: []u8, key: []const u8) void {
    // 從頭開始掃，找像 `password=...` 這樣的片段。
    var start_index: usize = 0;

    // `indexOfPos` 會從 `start_index` 開始往後找 `key`。
    while (std.mem.indexOfPos(u8, text, start_index, key)) |key_index| {
        const equals_index = key_index + key.len;
        // 如果 key 後面不是 `=`，代表不是 `key=value` 格式，跳過。
        if (equals_index >= text.len or text[equals_index] != '=') {
            start_index = equals_index;
            continue;
        }

        // 這裡確保它真的是 query string 參數，而不是碰巧出現在其他字串片段。
        if (key_index != 0 and text[key_index - 1] != '?' and text[key_index - 1] != '&') {
            start_index = equals_index;
            continue;
        }

        // 從 `=` 後面開始往後找，直到遇到下一個 `&` 或 `#`。
        var value_end = equals_index + 1;
        while (value_end < text.len and text[value_end] != '&' and text[value_end] != '#') : (value_end += 1) {}

        // 把這段值直接改成 `*`。
        maskSlice(text[equals_index + 1 .. value_end]);
        // 繼續往後掃。
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
    // `for (text) |*char|` 裡的 `*char` 代表：
    // 我們拿到的是「可修改的指標」，所以能直接改原字串內容。
    for (text) |*char| {
        char.* = '*';
    }
}

test "url for log masks afraid token and dynu password" {
    // 先測 Afraid 新語法 query token 是否有被遮掉。
    var afraid_buffer: [log_url_buffer_len]u8 = undefined;
    const afraid_url = urlForLog(&afraid_buffer, "https://freedns.afraid.org/dynamic/update.php?secret-token");
    try std.testing.expectEqualStrings("https://freedns.afraid.org/dynamic/update.php?************", afraid_url);

    // 再測 Dynu 的 query string username / password 是否有被遮掉。
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
    // 這個測試確認 CRLF 會被整理成單一空白，
    // 避免 log 中間突然斷行。
    var buffer: [32]u8 = undefined;
    const preview = bodyPreviewForLog(&buffer, "nochg 1.2.3.4\r\n");
    try std.testing.expectEqualStrings("nochg 1.2.3.4", preview);
}
