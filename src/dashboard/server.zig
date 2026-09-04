//! 單一 process 內的 Dashboard HTTP server。
//!
//! - 這個檔案不負責 DDNS 更新，只負責「把記憶體狀態變成 HTTP 回應」。
//! - 真正的 provider 狀態來自 `dashboard/service.zig`，再往下讀
//!   `core/ddns.zig` 的 `getProviderSnapshots()`。
//! - Zig 沒有 Rust 的 rustdoc 工具鏈，但 `//!` / `///` 是同等用途的
//!   doc comment，可被 Zig 文件工具讀取，也適合當 API 說明。
//! - 本 server 使用 Zig 標準庫 `std.http.Server`，因此不需要 Jetzig
//!   runtime 才能提供 `/dashboard`。

/// Zig 標準函式庫。這裡會用到 HTTP、網路、字串、allocator、ArrayList。
const std = @import("std");
/// 專案設定型別，例如 `AppConfig.dashboard.port`。
const config_mod = @import("../base/config.zig");
/// scheduler 的 StopToken。Dashboard 用它判斷主服務是否準備停止。
const scheduler = @import("../core/scheduler.zig");
/// Dashboard 展示資料整理層。HTTP server 不直接讀 ddns 全域狀態。
const service = @import("service.zig");
const ddns = @import("../core/ddns.zig");

/// HTML 回應共用 headers。
///
/// `cache-control: no-store` 是為了讓瀏覽器每次都看到最新 process memory 狀態。
const html_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store" },
};

/// JSON API 回應共用 headers。
const json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store" },
};

/// 純文字錯誤回應共用 headers，例如 404 或 method not allowed。
const text_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store" },
};

/// Dashboard 的 CSS/JS 原始碼放在 `static/`，透過 `@embedFile` 在編譯期烤進
/// binary，執行期不需要讀取檔案系統。
///
/// 為什麼不用執行期讀檔（例如放到專案根目錄 `public/` 再用 `std.fs` 讀取）？
/// `Dockerfile` 只把編譯好的單一 binary 複製進最終 image，並未一併複製任何
/// 靜態資源目錄；若改成執行期讀檔，容器內會直接 404。`@embedFile` 讓這兩個
/// 檔案永遠跟著 binary 一起部署。
const dashboard_css = @embedFile("static/dashboard.css");
const dashboard_js = @embedFile("static/dashboard.js");

/// ETag 用內容的 Wyhash 在編譯期算好；同一個 binary 對同一份靜態資源永遠回同
/// 一個 ETag，換 binary（=內容可能變了）才會換 ETag。
const dashboard_css_etag = blk: {
    // Wyhash 逐 48-byte round 處理；預設 1000 backward-branch quota 不夠掃完
    // 整份 CSS/JS，所以要在這個 comptime 區塊內拉高上限。
    @setEvalBranchQuota(200_000);
    break :blk std.fmt.comptimePrint("\"{x}\"", .{std.hash.Wyhash.hash(0, dashboard_css)});
};
const dashboard_js_etag = blk: {
    @setEvalBranchQuota(200_000);
    break :blk std.fmt.comptimePrint("\"{x}\"", .{std.hash.Wyhash.hash(0, dashboard_js)});
};

const dashboard_css_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/css; charset=utf-8" },
    .{ .name = "cache-control", .value = "public, max-age=3600, must-revalidate" },
    .{ .name = "etag", .value = dashboard_css_etag },
};

const dashboard_js_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/javascript; charset=utf-8" },
    .{ .name = "cache-control", .value = "public, max-age=3600, must-revalidate" },
    .{ .name = "etag", .value = dashboard_js_etag },
};

/// 啟動 Dashboard server，並把錯誤寫進 log。
///
/// 為什麼要包一層？
/// `std.Thread.spawn` 需要一個函式當 thread entry point。若直接呼叫會回傳錯誤的
/// `run(...)`，錯誤需要有人接住；這個 wrapper 就是「thread 內的錯誤邊界」。
pub fn runAndLog(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_config: config_mod.AppConfig,
    stop_token: ?scheduler.StopToken,
) void {
    run(allocator, io, app_config, stop_token) catch |err| {
        std.log.err("dashboard server stopped: {}", .{err});
    };
}

/// Dashboard server 的主迴圈。
///
/// 參數說明：
/// - `allocator`：用來配置每次 HTML/JSON response body。
/// - `io`：Zig 0.17 的 I/O 介面，負責 listen/accept/read/write。
/// - `app_config`：已載入的 app.json/.env/env 合併設定。
/// - `stop_token`：主程式收到 shutdown signal 時會被設成 true。
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_config: config_mod.AppConfig,
    stop_token: ?scheduler.StopToken,
) !void {
    // 若 app.json 設定 dashboard.enabled=false，就完全不開 port。
    if (!app_config.dashboard.enabled) return;

    // 將 "0.0.0.0" + 9003 這類設定轉成 std.Io.net.IpAddress。
    var address = try parseListenAddress(app_config.dashboard.host, app_config.dashboard.port);
    // 真正向 OS 開 TCP listening socket。
    // reuse_address=true 讓服務重啟時比較不容易被 TIME_WAIT 卡住。
    var server = try address.listen(io, .{ .reuse_address = true });
    // run() 離開時關閉 listening socket。
    defer server.deinit(io);

    std.log.info("dashboard listening on http://{s}:{d}/dashboard", .{
        app_config.dashboard.host,
        app_config.dashboard.port,
    });

    // `accept` 會一直阻塞到有連線進來，所以光靠迴圈條件檢查 stop_token 是不夠的：
    // 沒有人連進來時，這條 thread 會永遠停在 accept 裡面，看不到停止旗標。
    //
    // 標準庫在 `Server.AcceptError.SocketNotListening` 的說明中明確指出，
    // `shutdown` 可以當作 accept 的並行取消機制。因此另外跑一個小任務：
    // 等 stop_token 被設起來後對 listening socket 做 shutdown，
    // 阻塞中的 accept 就會立刻返回 SocketNotListening。
    //
    // 用 `io.concurrent` 而不是 `io.async`：`async` 允許實作直接就地同步執行傳入的
    // 函式，而這個 watcher 本身是個等待迴圈，就地執行等於永遠不會回到 accept。
    // `concurrent` 保證拿到真正的並行單位，拿不到時回 error 讓我們降級處理。
    var shutdown_watcher = io.concurrent(shutdownServerOnStop, .{ io, stop_token, &server });
    // defer 的執行順序是後進先出，所以這個 cancel 會排在上面 `server.deinit(io)` 之前，
    // watcher 一定在 server 記憶體失效前就結束，不會拿到已 undefined 的指標。
    defer if (shutdown_watcher) |*watcher| watcher.cancel(io) else |_| {};

    if (shutdown_watcher) |_| {} else |err| {
        // 沒有並行單位時退回舊行為：仍然可以服務請求，只是停止要等到 process 結束。
        std.log.debug("dashboard shutdown watcher unavailable, falling back to blocking accept: {}", .{err});
    }

    // Dashboard 和 DDNS scheduler 同 process，但在不同 thread。
    // 這個 while loop 會一直等瀏覽器連線，直到 stop_token 要求停止。
    while (!isStopRequested(stop_token)) {
        // accept() 會等待下一條 TCP connection。
        // Zig 的 error union 寫法是：成功回傳 stream，失敗進 catch。
        var stream = server.accept(io) catch |err| switch (err) {
            // 非阻塞 socket 沒有連線時可能會回 WouldBlock；這裡直接繼續等。
            error.WouldBlock => continue,
            // listening socket 被關閉或 shutdown 時（正常停止路徑）自然結束。
            error.SocketNotListening, error.Canceled => return,
            // 其他錯誤交給呼叫端，由 runAndLog 記錄。
            else => return err,
        };

        // 處理單一 TCP connection。這個 server 採「一條連線一個 request」，
        // 所以處理完就關閉，避免 keep-alive 閒置連線卡住單 thread server。
        handleConnection(allocator, io, stream, app_config) catch |err| {
            std.log.warn("dashboard request failed: {}", .{err});
        };
        // `Stream` 是 OS socket 包裝；用完要關。
        stream.close(io);
    }
}

/// 等到 stop_token 被設起來後，對 listening socket 做 shutdown，
/// 讓阻塞在 `accept` 的主迴圈立刻返回。
///
/// 這個任務只做等待與一次 shutdown，不碰任何共享狀態。
fn shutdownServerOnStop(
    io: std.Io,
    stop_token: ?scheduler.StopToken,
    server: *std.Io.net.Server,
) void {
    // 沒有 stop_token 就沒有停止來源（例如測試路徑），這個任務沒有工作可做。
    if (stop_token == null) return;

    while (!isStopRequested(stop_token)) {
        // 分段 sleep，讓停止旗標最多延遲一個間隔就被看到。
        // 被 `run` 的 defer cancel 時，sleep 會回 error.Canceled，
        // 代表 accept 迴圈已經自行結束，不需要再 shutdown。
        io.sleep(.fromMilliseconds(200), .awake) catch return;
    }

    // `Stream` 只是 `Socket` 的薄包裝，listening socket 也適用同一個 shutdown。
    const listening: std.Io.net.Stream = .{ .socket = server.socket };
    listening.shutdown(io, .both) catch |err| {
        std.log.debug("dashboard listening socket shutdown failed: {}", .{err});
    };
}

/// 讀取一條 TCP connection 上的 HTTP request，並交給 router。
///
/// 新手重點：
/// - `read_buffer` / `write_buffer` 是 stack buffer，不需要 allocator。
/// - `std.http.Server` 處理的是「單一 connection lifecycle」。
/// - 真正決定 URL 路由的是下一層 `handleRequest(...)`。
fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    app_config: config_mod.AppConfig,
) !void {
    // HTTP request header 和 response buffer 的暫存空間。
    // 8192 對這個 Dashboard 的小型 GET request 足夠。
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    // 把 TCP stream 包成 Zig 的 Reader/Writer 介面。
    var stream_reader = stream.reader(io, &read_buffer);
    var stream_writer = stream.writer(io, &write_buffer);
    // std.http.Server 本身不 listen，它只解析一條 stream 上的 HTTP。
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    // 讀 HTTP request line + headers。
    // 這裡只處理一個 request，因為回應都會送 Connection: close。
    var request = http_server.receiveHead() catch |err| switch (err) {
        // 瀏覽器提早關閉、request 不完整、底層 read 失敗，都視為這條連線結束。
        error.HttpConnectionClosing, error.HttpRequestTruncated, error.ReadFailed => return,
        else => return err,
    };
    // 依 URL path 產生 HTML/JSON/404。
    try handleRequest(allocator, io, &request, app_config);
}

/// Dashboard 的極簡 router。
///
/// 目前支援：
/// - GET `/dashboard`：HTML Dashboard。
/// - GET `/dashboard/config`：設定摘要。
/// - GET `/api/status` / `/api/status.json`：JSON API。
fn handleRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    app_config: config_mod.AppConfig,
) !void {
    // request.head.target 可能含 query string，例如 "/dashboard?x=1"。
    // Dashboard 目前不需要 query，所以先切掉 `?` 後面的部分。
    const target_path = pathOnly(request.head.target);

    // Dashboard 初版只開 GET/HEAD。其他 method 回 405。
    if (request.head.method != .GET and request.head.method != .HEAD) {
        try request.respond("method not allowed\n", .{
            .status = .method_not_allowed,
            .extra_headers = &text_headers,
            .keep_alive = false,
        });
        return;
    }

    // CSS/JS 靜態資源。放在 HTML 路由之前，讓瀏覽器能對這兩個路徑做 304 快取。
    if (std.mem.eql(u8, target_path, "/dashboard.css")) {
        try serveStatic(request, dashboard_css, dashboard_css_etag, &dashboard_css_headers);
        return;
    }
    if (std.mem.eql(u8, target_path, "/dashboard.js")) {
        try serveStatic(request, dashboard_js, dashboard_js_etag, &dashboard_js_headers);
        return;
    }

    // 首頁和 /dashboard 都導到同一個 HTML。
    if (std.mem.eql(u8, target_path, "/") or std.mem.eql(u8, target_path, "/dashboard")) {
        // render function 會配置一段完整 HTML 字串；回應後要 free。
        const body = try renderDashboardPage(allocator, io, app_config);
        defer allocator.free(body);
        try request.respond(body, .{ .extra_headers = &html_headers, .keep_alive = false });
        return;
    }

    // 設定摘要頁，不顯示密碼/token，只顯示是否啟用與 listen 設定。
    if (std.mem.eql(u8, target_path, "/dashboard/config")) {
        const body = try renderConfigPage(allocator, app_config);
        defer allocator.free(body);
        try request.respond(body, .{ .extra_headers = &html_headers, .keep_alive = false });
        return;
    }

    // JSON API。前端 JS 每 5 秒 fetch 這個端點刷新卡片。
    if (std.mem.eql(u8, target_path, "/api/status") or
        std.mem.eql(u8, target_path, "/api/status.json"))
    {
        const body = try renderStatusJson(allocator, io, app_config);
        defer allocator.free(body);
        try request.respond(body, .{ .extra_headers = &json_headers, .keep_alive = false });
        return;
    }

    // 其他路徑全部回 404。
    try request.respond("not found\n", .{
        .status = .not_found,
        .extra_headers = &text_headers,
        .keep_alive = false,
    });
}

/// 回應一個 embedded 靜態資源，支援 `If-None-Match` 條件請求。
///
/// 命中快取時回 304 並帶空 body；未命中則回完整內容。兩種情況都要帶上
/// `etag`，這樣瀏覽器下一次請求才有東西可以拿來比對。
fn serveStatic(
    request: *std.http.Server.Request,
    content: []const u8,
    etag: []const u8,
    headers: []const std.http.Header,
) !void {
    if (clientHasFreshEtag(request, etag)) {
        try request.respond("", .{ .status = .not_modified, .extra_headers = headers, .keep_alive = false });
        return;
    }
    try request.respond(content, .{ .extra_headers = headers, .keep_alive = false });
}

/// 檢查 request 的 `If-None-Match` header 是否等於目前資源的 ETag。
fn clientHasFreshEtag(request: *std.http.Server.Request, etag: []const u8) bool {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "if-none-match") and std.mem.eql(u8, header.value, etag)) {
            return true;
        }
    }
    return false;
}

/// 產生 Dashboard 主頁 HTML。
///
/// 這裡沒有使用模板引擎，原因是 Jetzig 相依目前和本機 Zig nightly 不相容。
/// 實作上採用 `std.Io.Writer.Allocating` 逐段寫入 ArrayList，最後轉成
/// `[]u8` 回傳給 HTTP response。
fn renderDashboardPage(allocator: std.mem.Allocator, io: std.Io, app_config: config_mod.AppConfig) ![]u8 {
    // 讀出三個 provider 的「展示用資料」。
    const data = service.readDisplayData(io, app_config);
    // 取得實際 Public IP 快照。
    const ip_snap = ddns.getPublicIpSnapshot(io);
    const public_ip = if (ip_snap.initialized) ip_snap.ipSlice() else "—";
    // Public IP 來源，例如 "stun" / "cloudflare"。
    //
    // Dashboard 不自己推測來源；來源必須由 DDNS core 在成功 lookup 時寫入。
    // 這樣畫面看到的值才會和 log 裡的 `public ip service succeeded` 一致。
    const public_ip_source = if (ip_snap.initialized and ip_snap.source_len != 0) ip_snap.sourceSlice() else "—";
    const public_ip_stun_status = publicIpStunStatus(&ip_snap);
    const public_ip_stun_error = if (ip_snap.initialized and ip_snap.stun_error_len != 0) ip_snap.stunErrorSlice() else "";

    // ArrayList 是可成長 byte buffer，適合組 HTML/JSON 字串。
    var buffer = std.ArrayList(u8).empty;
    // 若中途失敗，釋放目前已配置的 buffer。
    defer buffer.deinit(allocator);
    // Allocating writer 會把所有 write/print 累積進 buffer。
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    errdefer writer.deinit();
    // `out` 是通用 writer 介面，下面所有 helper 都收這個型別。
    const out = &writer.writer;

    // 寫入共用 HTML head / CSS / body 起始。
    try writePageStart(out, "DDNS Dashboard");
    // 第一段是靜態 HTML 骨架：header、Public IP、nav、狀態列。
    try out.writeAll("<main class=\"shell\"><header class=\"hero\"><div class=\"brand\"><strong>dynip Dashboard</strong><span>DDNS monitor center</span><nav><a href=\"/dashboard\">Dashboard</a><a href=\"/dashboard/config\">Config</a></nav></div><section class=\"public-ip\"><span>Public IP</span><strong id=\"desired-ip\">");
    // IP 是動態資料，所以必須 HTML escape，避免狀態文字破壞 HTML。
    try writeHtml(out, public_ip);
    try out.writeAll("</strong><small>Source: <span id=\"public-ip-source\">");
    try writeHtml(out, public_ip_source);
    try out.writeAll("</span></small><small>STUN: <span id=\"public-ip-stun-status\">");
    try writeHtml(out, public_ip_stun_status);
    try out.writeAll("</span><span id=\"public-ip-stun-error\">");
    if (public_ip_stun_error.len != 0) {
        try out.writeAll(" (");
        try writeHtml(out, public_ip_stun_error);
        try out.writeAll(")");
    }
    try out.print("</span></small><small id=\"last-updated\">Last Updated: -</small></section></header><div class=\"status-row\"><span>Provider Status Cards</span><strong>Memory Store: Active</strong><button type=\"button\" id=\"refresh-toggle\" onclick=\"toggleRefresh()\">⟳ Auto-refresh: ON</button></div><section id=\"providers\" class=\"provider-grid\">", .{});
    // 首次載入時先 server-side render 一版卡片；JS 載入後會再用 JSON 重畫一次。
    // `data` 的相鄰兩筆是同一 provider 的 IPv4、IPv6。用 while 每次加 2，
    // 明確告訴讀者「這是在走 pair」，而不是剛好跳過一筆資料。
    var provider_index: usize = 0;
    while (provider_index < data.len) : (provider_index += 2) {
        // 先寫 A/IPv4，再寫 AAAA/IPv6；writeProviderCard 會把兩個區塊包進同一張卡。
        try writeProviderCard(out, data[provider_index], data[provider_index + 1]);
    }
    // 這段是頁面底部、detail panel。實際輪詢/render 邏輯都在 `static/dashboard.js`
    // 裡（同樣走 304 快取），這裡只留「載入外部 JS + 帶入首次渲染資料」的 bootstrap。
    try out.writeAll(
        \\</section><aside class="memory-note"><strong>Note:</strong> State is from process memory. Restarting the service resets counters until the next update cycle writes fresh snapshots.</aside>
        \\<section id="detail-panel" class="detail-panel" hidden><header><strong id="detail-title">Provider detail</strong><button type="button" onclick="hideDetail()">Close</button></header><dl id="detail-body"></dl></section></main><script src="/dashboard.js"></script><script>
        \\latestProviders=[
    );
    // 把目前三個 provider 狀態也嵌成 JSON，讓初始 detail panel 不必等第一次 fetch。
    for (data, 0..) |provider, index| {
        if (index != 0) try out.writeAll(",");
        try writeProviderJson(out, provider);
    }
    try out.writeAll(
        \\]; renderProviders(); document.getElementById('last-updated').textContent='Last Updated: '+formatRfc3339(new Date());
        \\startRefresh();
        \\</script>
    );
    // 寫入 body/html 結尾。
    try writePageEnd(out);

    // `writer.toArrayList()` 把 writer 目前持有的 ArrayList 還給我們。
    buffer = writer.toArrayList();
    // 將 ArrayList 內容轉成 owned slice；呼叫端負責 allocator.free。
    return try buffer.toOwnedSlice(allocator);
}

/// 產生 `/dashboard/config` 設定摘要頁。
fn renderConfigPage(allocator: std.mem.Allocator, app_config: config_mod.AppConfig) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    errdefer writer.deinit();
    const out = &writer.writer;

    try writePageStart(out, "DDNS Dashboard Config");

    // Header consistent with Dashboard
    try out.print(
        \\<main class="shell"><header class="hero" style="grid-template-columns: 1fr;"><div class="brand"><strong>dynip Dashboard</strong><span>DDNS monitor center</span><nav><a href="/dashboard">Dashboard</a><a href="/dashboard/config">Config</a></nav></div></header>
        \\<section class="config-section">
        \\<h2>Provider Configuration</h2>
        \\<table class="config-table">
        \\<thead><tr><th>Provider</th><th>Enabled</th><th>Configured</th><th>URL</th></tr></thead>
        \\<tbody>
    , .{});

    // Render Afraid
    const afraid_configured = app_config.afraid.token.len > 0;
    try out.print(
        \\<tr><td><strong>Afraid.org</strong></td><td>{}</td><td>{s}</td><td>
    , .{ app_config.afraid.enabled, if (afraid_configured) "✅ Yes" else "❌ No" });
    try writeHtml(out, app_config.afraid.url);
    try out.print("</td></tr>\n", .{});

    // Cloudflare 不使用傳統 DDNS 更新 URL，而是固定呼叫 Cloudflare REST API。
    // Config 頁面只顯示 zone ID 與 hostname 數量；api_token 絕不送到瀏覽器。
    const cloudflare_configured = app_config.cloudflare.api_token.len > 0 and
        app_config.cloudflare.zone_id.len > 0 and app_config.cloudflare.hostnames.len > 0;
    try out.print(
        \\<tr><td><strong>Cloudflare DNS</strong></td><td>{}</td><td>{s}</td><td>zone=
    , .{ app_config.cloudflare.enabled, if (cloudflare_configured) "✅ Yes" else "❌ No" });
    if (app_config.cloudflare.zone_id.len == 0) {
        try out.writeAll("—");
    } else {
        try writeHtml(out, app_config.cloudflare.zone_id);
    }
    try out.print(", hostnames={d}, proxied={}</td></tr>\n", .{
        app_config.cloudflare.hostnames.len,
        app_config.cloudflare.proxied,
    });

    // Render Dynu
    const dynu_configured = app_config.dynu.username.len > 0 and app_config.dynu.password.len > 0;
    try out.print(
        \\<tr><td><strong>Dynu</strong></td><td>{}</td><td>{s}</td><td>
    , .{ app_config.dynu.enabled, if (dynu_configured) "✅ Yes" else "❌ No" });
    try writeHtml(out, app_config.dynu.url);
    try out.print("</td></tr>\n", .{});

    // Render No-IP
    const noip_configured = app_config.noip.username.len > 0 and app_config.noip.password.len > 0;
    try out.print(
        \\<tr><td><strong>No-IP</strong></td><td>{}</td><td>{s}</td><td>
    , .{ app_config.noip.enabled, if (noip_configured) "✅ Yes" else "❌ No" });
    try writeHtml(out, app_config.noip.url);
    try out.print("</td></tr>\n", .{});

    try out.print(
        \\</tbody>
        \\</table>
        \\
        \\<h2>System Settings</h2>
        \\<section class="config-list">
        \\<div><span>Refresh Interval</span><strong>{d}s</strong></div>
        \\<div><span>Dashboard Listen</span><strong>
    , .{app_config.ddns.refresh_interval_seconds});
    try writeHtml(out, app_config.dashboard.host);
    try out.print(":{d}</strong></div>\n", .{app_config.dashboard.port});

    try out.print(
        \\<div><span>Redis Enabled</span><strong>{}</strong></div>
        \\<div><span>Data Source</span><strong>Process Memory</strong></div>
        \\</section>
        \\</section>
        \\</main>
    , .{app_config.ddns.redis.enabled});

    try writePageEnd(out);

    buffer = writer.toArrayList();
    return try buffer.toOwnedSlice(allocator);
}

/// 產生 `/api/status.json` 的 JSON response body。
fn renderStatusJson(allocator: std.mem.Allocator, io: std.Io, app_config: config_mod.AppConfig) ![]u8 {
    const data = service.readDisplayData(io, app_config);
    const ip_snap = ddns.getPublicIpSnapshot(io);
    const public_ip = if (ip_snap.initialized) ip_snap.ipSlice() else "";
    const public_ip_source = if (ip_snap.initialized and ip_snap.source_len != 0) ip_snap.sourceSlice() else "";
    const public_ip_stun_status = publicIpStunStatus(&ip_snap);
    const public_ip_stun_error = if (ip_snap.initialized and ip_snap.stun_error_len != 0) ip_snap.stunErrorSlice() else "";

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    errdefer writer.deinit();
    const out = &writer.writer;

    // JSON object 起始，寫 desired_ip (即 public_ip), data_source
    try out.writeAll("{\"desired_ip\":\"");
    try writeJsonStringContent(out, public_ip);
    try out.writeAll("\",\"public_ip\":\"");
    try writeJsonStringContent(out, public_ip);
    try out.writeAll("\",\"public_ip_source\":\"");
    try writeJsonStringContent(out, public_ip_source);
    try out.writeAll("\",\"public_ip_stun_status\":\"");
    try writeJsonStringContent(out, public_ip_stun_status);
    try out.writeAll("\",\"public_ip_stun_error\":\"");
    try writeJsonStringContent(out, public_ip_stun_error);
    try out.writeAll("\",\"data_source\":\"process_memory\",\"providers\":[");
    // providers 是固定三筆：afraid, dynu, noip。
    for (data, 0..) |provider, index| {
        // JSON 陣列元素之間需要逗號，但第一筆前面不能有。
        if (index != 0) try out.writeAll(",");
        try writeProviderJson(out, provider);
    }
    try out.writeAll("]}");

    buffer = writer.toArrayList();
    return try buffer.toOwnedSlice(allocator);
}

/// 寫一張 provider 卡片的 HTML。
fn writeProviderCard(out: *std.Io.Writer, ipv4: service.ProviderDisplayData, ipv6: service.ProviderDisplayData) !void {
    // provider 名稱對同一對資料必定相同，所以以 ipv4 的 snapshot 作為標題來源。
    try out.writeAll("<article class=\"provider\"><header><span>");
    try writeHtml(out, ipv4.snapshot.nameSlice());
    try out.writeAll("</span></header><div class=\"family-grid\">");
    try writeFamilyStatus(out, ipv4);
    try writeFamilyStatus(out, ipv6);
    try out.writeAll("</div></article>");
}

fn writeFamilyStatus(out: *std.Io.Writer, provider: service.ProviderDisplayData) !void {
    // 這個 helper 對應前端的 familyStatus：一個呼叫只渲染 A 或 AAAA，
    // 因此 retry 與 last_error 永遠是該 family 的獨立值。
    const snap = provider.snapshot;
    // DNS record type 使用 A / AAAA；括號後補上新手較熟悉的 IP family 名稱。
    const family_label = if (snap.family == .ipv4) "A / IPv4" else "AAAA / IPv6";
    const is_failed = provider.display_status == .failed or provider.display_status == .retry_deferred;
    const time_label = if (is_failed) "Next" else "Updated";
    try out.print("<section class=\"family {s}\"><header><span>{s}</span><strong>{s}</strong></header><dl>", .{ @tagName(provider.display_status), family_label, displayStatusLabel(provider.display_status) });
    try writeMetric(out, "Current IP", snap.currentIpSlice());
    try out.print("<div><dt>Retry</dt><dd>{d}</dd></div>", .{snap.retry_count});
    try writeMetric(out, time_label, "—");
    try writeMetric(out, "Last error", snap.lastErrorSlice());
    try out.writeAll("</dl><button type=\"button\" onclick=\"showDetail('");
    try writeHtml(out, snap.nameSlice());
    try out.writeAll("','");
    try writeHtml(out, snap.family.name());
    try out.writeAll("')\">View Details</button></section>");
}

/// 將單一 provider 寫成 JSON object。
fn writeProviderJson(out: *std.Io.Writer, provider: service.ProviderDisplayData) !void {
    // 此 JSON 是 browser 自動刷新時唯一的狀態來源；欄位必須和 familyStatus 使用的
    // `name`、`family`、`current_ip`、`retry_count`、`last_error` 保持一致。
    const snap = provider.snapshot;
    try out.writeAll("{\"name\":\"");
    try writeJsonStringContent(out, snap.nameSlice());
    try out.writeAll("\",\"display_status\":\"");
    try writeJsonStringContent(out, @tagName(provider.display_status));
    try out.writeAll("\",\"initialized\":");
    try out.writeAll(if (snap.initialized) "true" else "false");
    // 將 enum 轉為 "ipv4" / "ipv6"，讓 JavaScript 不必依陣列索引猜 family。
    try out.writeAll(",\"family\":\"");
    try writeJsonStringContent(out, snap.family.name());
    try out.writeAll("\",\"status\":\"");
    try writeJsonStringContent(out, snap.statusSlice());
    try out.writeAll("\",\"enabled\":");
    try out.writeAll(if (provider.enabled) "true" else "false");
    try out.writeAll(",\"current_ip\":\"");
    try writeJsonStringContent(out, snap.currentIpSlice());
    try out.writeAll("\",\"desired_ip\":\"");
    try writeJsonStringContent(out, snap.desiredIpSlice());
    try out.print("\",\"retry_count\":{d},\"next_retry_at\":{d},\"updated_at\":{d},\"last_error\":\"", .{ snap.retry_count, snap.next_retry_at, snap.updated_at });
    try writeJsonStringContent(out, snap.lastErrorSlice());
    try out.writeAll("\"}");
}

/// 寫 HTML 文件開頭與 `<body>` 起始。
///
/// CSS 是獨立檔案 `static/dashboard.css`，透過 `<link>` 載入並可被瀏覽器
/// 用 304 快取，而不是像之前那樣整段 `<style>` 隨每次回應重送。
fn writePageStart(out: *std.Io.Writer, title: []const u8) !void {
    try out.writeAll("<!doctype html><html lang=\"zh-Hant\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>");
    try writeHtml(out, title);
    try out.writeAll("</title><link rel=\"stylesheet\" href=\"/dashboard.css\"></head><body>");
}

/// 寫 HTML 文件結尾。
fn writePageEnd(out: *std.Io.Writer) !void {
    try out.writeAll("</body></html>");
}

/// 寫一列 `<dt>/<dd>` 指標。
///
/// `value` 是動態字串，所以會做 HTML escape；空字串顯示成 `-`。
fn writeMetric(out: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    try out.writeAll("<div><dt>");
    try writeHtml(out, label);
    try out.writeAll("</dt><dd>");
    if (value.len == 0) try out.writeAll("-") else try writeHtml(out, value);
    try out.writeAll("</dd></div>");
}

/// 將任意文字安全寫進 HTML text node。
///
/// 例如 `1.2.3.4` 會原樣輸出；`<script>` 會變成 `&lt;script&gt;`。
/// 這是 Dashboard 讀取錯誤訊息時必備的基本防護。
fn writeHtml(out: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        '"' => try out.writeAll("&quot;"),
        '\'' => try out.writeAll("&#39;"),
        else => try out.writeByte(byte),
    };
}

/// 將任意文字安全寫進 JSON string 內部。
///
/// 呼叫端負責寫外層的雙引號；這個 helper 只負責 escape string content。
fn writeJsonStringContent(out: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        // JSON 不允許原始控制字元，所以 0x00..0x1f 要 escape。
        if (byte < 0x20) {
            switch (byte) {
                '\n' => try out.writeAll("\\n"),
                '\r' => try out.writeAll("\\r"),
                '\t' => try out.writeAll("\\t"),
                else => try out.print("\\u{x:0>4}", .{byte}),
            }
            continue;
        }

        // JSON string 裡的 backslash 和 double quote 也必須 escape。
        switch (byte) {
            '\\' => try out.writeAll("\\\\"),
            '"' => try out.writeAll("\\\""),
            // `<` 對 JSON 本身無害，但 renderDashboardPage 會把同一份 JSON
            // 直接嵌進 `<script>` 區塊。瀏覽器在解析 `<script>` 內容時，
            // 是先找 `</script>` 這個字串才交給 JS engine，所以只要值裡出現
            // `</script>` 就能提早關掉 script 標籤，變成 HTML injection。
            //
            // `<` 在 JSON 與 JS 裡都還原成同一個 `<` 字元，不影響前端讀到的值，
            // 但已經不再是能結束 script 標籤的字面內容。
            '<' => try out.writeAll("\\u003c"),
            else => try out.writeByte(byte),
        }
    }
}

/// 從 request target 取出 path，不含 query string。
///
/// 範例：`/dashboard?refresh=1` 會回 `/dashboard`。
fn pathOnly(target: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..query_start];
}

/// 將 app.json 中的 dashboard host/port 轉成 listen address。
///
/// 支援：
/// - `0.0.0.0`
/// - `127.0.0.1`
/// - IPv6 literal
/// - `localhost`（特別轉成 `127.0.0.1`）
fn parseListenAddress(host: []const u8, port: u32) !std.Io.net.IpAddress {
    // OS port 是 u16；config 用 u32 是為了 JSON parse/驗證方便。
    const port_u16: u16 = std.math.cast(u16, port) orelse return error.InvalidDashboardPort;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) {
        return std.Io.net.IpAddress.parseIp4("127.0.0.1", port_u16) catch unreachable;
    }
    return std.Io.net.IpAddress.parse(host, port_u16) catch error.InvalidDashboardHost;
}

/// 包裝 optional StopToken 的讀取。
///
/// 測試或其他呼叫端可以傳 null；正式 service 會傳 scheduler.StopToken。
fn isStopRequested(stop_token: ?scheduler.StopToken) bool {
    if (stop_token) |token| return token.isRequested();
    return false;
}

/// 將 enum tag 轉成 UI 顯示文字。
///
/// `retry_deferred` 對使用者顯示成 `retry deferred`，比 raw enum tag 易讀。
fn displayStatusLabel(status: service.DisplayStatus) []const u8 {
    return switch (status) {
        .initializing => "initializing",
        .success => "success",
        .failed => "failed",
        .retry_deferred => "retry deferred",
        .updating => "updating",
        .disabled => "disabled",
    };
}

/// 將 public IP 快照中的 STUN 結果轉成 dashboard 顯示字串。
///
/// - `PublicIpSnapshot` 只保存「最後一輪 public IP lookup」的結果。
/// - STUN 成功時，public IP 的來源就是 "stun"，錯誤欄位為空。
/// - STUN 失敗但 HTTP fallback 成功時，來源會是 "cloudflare" HTTP 服務，
///   而 `stun_error_len` 會保存失敗原因，畫面就能顯示 `failed`。
fn publicIpStunStatus(snapshot: *const ddns.PublicIpSnapshot) []const u8 {
    if (!snapshot.initialized) return "—";
    if (std.mem.eql(u8, snapshot.sourceSlice(), "stun")) return "success";
    if (snapshot.stun_error_len != 0) return "failed";
    return "—";
}

test "dashboard json exposes providers" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const json = try renderStatusJson(allocator, threaded.io(), .{});
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"providers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"public_ip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"public_ip_source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"public_ip_stun_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"public_ip_stun_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"family\":\"ipv4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"family\":\"ipv6\"") != null);
}

test "dashboard groups A and AAAA status in each provider card" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const html = try renderDashboardPage(allocator, threaded.io(), .{});
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "A / IPv4") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "AAAA / IPv6") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Last error") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "family-grid") != null);
}

test "dashboard json escaping cannot close the embedded script tag" {
    // renderDashboardPage 把 provider JSON 直接嵌在 `<script>` 裡，
    // 所以 JSON escaping 必須讓 `</script>` 無法以字面形式出現在輸出中。
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    defer writer.deinit();

    try writeJsonStringContent(&writer.writer, "</script><img src=x onerror=alert(1)>");
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "</script>") == null);
    // 只有 `<` 需要處理。`>` 單獨出現無法結束 script 標籤，所以保持原樣，
    // 讓輸出盡量接近原始文字。
    try std.testing.expectEqualStrings(
        "\\u003c/script>\\u003cimg src=x onerror=alert(1)>",
        buffer.items,
    );
}

test "dashboard html escapes dynamic content" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    defer writer.deinit();

    try writeHtml(&writer.writer, "<tag>&\"");
    buffer = writer.toArrayList();
    try std.testing.expectEqualStrings("&lt;tag&gt;&amp;&quot;", buffer.items);
}
