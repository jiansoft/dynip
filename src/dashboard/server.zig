//! 單一 process 內的 Dashboard HTTP server。
//!
//! 給 Zig 新手的閱讀方向：
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

    // Dashboard 和 DDNS scheduler 同 process，但在不同 thread。
    // 這個 while loop 會一直等瀏覽器連線，直到 stop_token 要求停止。
    while (!isStopRequested(stop_token)) {
        // accept() 會等待下一條 TCP connection。
        // Zig 的 error union 寫法是：成功回傳 stream，失敗進 catch。
        var stream = server.accept(io) catch |err| switch (err) {
            // 非阻塞 socket 沒有連線時可能會回 WouldBlock；這裡直接繼續等。
            error.WouldBlock => continue,
            // listening socket 被關閉時，server 可以自然停止。
            error.SocketNotListening => return,
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
    try handleRequest(allocator, &request, app_config);
}

/// Dashboard 的極簡 router。
///
/// 目前支援：
/// - GET `/dashboard`：HTML Dashboard。
/// - GET `/dashboard/config`：設定摘要。
/// - GET `/api/status` / `/api/status.json`：JSON API。
fn handleRequest(
    allocator: std.mem.Allocator,
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

    // 首頁和 /dashboard 都導到同一個 HTML。
    if (std.mem.eql(u8, target_path, "/") or std.mem.eql(u8, target_path, "/dashboard")) {
        // render function 會配置一段完整 HTML 字串；回應後要 free。
        const body = try renderDashboardPage(allocator, app_config);
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
        const body = try renderStatusJson(allocator, app_config);
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

/// 產生 Dashboard 主頁 HTML。
///
/// 這裡沒有使用模板引擎，原因是 Jetzig 相依目前和本機 Zig nightly 不相容。
/// 實作上採用 `std.Io.Writer.Allocating` 逐段寫入 ArrayList，最後轉成
/// `[]u8` 回傳給 HTTP response。
fn renderDashboardPage(allocator: std.mem.Allocator, app_config: config_mod.AppConfig) ![]u8 {
    // 讀出三個 provider 的「展示用資料」。
    const data = service.readDisplayData(app_config);
    // resolveDesiredIp 需要 [3]ProviderSnapshot，所以從 display data 拿出 snapshot。
    var snapshots = [_]@TypeOf(data[0].snapshot){ data[0].snapshot, data[1].snapshot, data[2].snapshot };
    // Dashboard header 顯示的 public IP。沒有任何成功快照時會是空字串。
    const desired_ip = service.resolveDesiredIp(&snapshots);

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
    try writeHtml(out, desired_ip);
    try out.print("</strong><small id=\"last-updated\">Last Updated: -</small></section></header><div class=\"status-row\"><span>Provider Status Cards</span><strong>Memory Store: Active</strong><em>Auto-refresh: 5s</em></div><section id=\"providers\" class=\"provider-grid\">", .{});
    // 首次載入時先 server-side render 一版卡片；JS 載入後會再用 JSON 重畫一次。
    for (data) |provider| try writeProviderCard(out, provider);
    // 這段是頁面底部、detail panel，以及前端輪詢 JS。
    try out.writeAll(
        \\</section><aside class="memory-note"><strong>Note:</strong> State is from process memory. Restarting the service resets counters until the next update cycle writes fresh snapshots.</aside>
        \\<section id="detail-panel" class="detail-panel" hidden><header><strong id="detail-title">Provider detail</strong><button type="button" onclick="hideDetail()">Close</button></header><dl id="detail-body"></dl></section></main><script>
        \\let latestProviders = [];
        \\async function refresh(){
        \\ const r=await fetch('/api/status.json',{cache:'no-store'}); if(!r.ok)return;
        \\ const data=await r.json(); latestProviders=data.providers||[];
        \\ document.getElementById('desired-ip').textContent=data.public_ip||'-';
        \\ document.getElementById('last-updated').textContent='Last Updated: '+new Date().toLocaleString();
        \\ document.getElementById('providers').innerHTML=latestProviders.map(providerCard).join('');
        \\}
        \\function providerCard(p){
        \\ return `<article class="provider ${p.display_status}"><div class="status-strip"></div><header><span>${escapeHtml(p.name)}</span><strong>${label(p.display_status)}</strong></header><dl><div><dt>Status</dt><dd>${label(p.display_status)}</dd></div><div><dt>IP</dt><dd>${escapeHtml(p.current_ip)||'-'}</dd></div><div><dt>Retry</dt><dd>${p.retry_count}</dd></div><div><dt>Updated</dt><dd>${formatTime(p.updated_at)}</dd></div></dl><button type="button" onclick="showDetail('${escapeAttr(p.name)}')">View Details</button></article>`;
        \\}
        \\function showDetail(name){
        \\ const p=latestProviders.find(x=>x.name===name); if(!p)return;
        \\ document.getElementById('detail-title').textContent=p.name+' - detail';
        \\ document.getElementById('detail-body').innerHTML=[
        \\ ['current_ip',p.current_ip||'-'],['desired_ip',p.desired_ip||'-'],['status',p.status||p.display_status],['display_status',label(p.display_status)],['retry_count',p.retry_count],['next_retry_at',formatTime(p.next_retry_at)],['last_error',p.last_error||'-'],['updated_at',formatTime(p.updated_at)]
        \\ ].map(([k,v])=>`<div><dt>${k}</dt><dd>${escapeHtml(v)}</dd></div>`).join('');
        \\ document.getElementById('detail-panel').hidden=false;
        \\}
        \\function hideDetail(){document.getElementById('detail-panel').hidden=true;}
        \\function label(v){return String(v||'').replace('_',' ');}
        \\function formatTime(v){return v?new Date(v*1000).toLocaleString():'-';}
        \\function escapeAttr(v){return String(v||'').replace(/['\\]/g,'');}
        \\function escapeHtml(v){return String(v||'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));}
        \\latestProviders=[
    );
    // 把目前三個 provider 狀態也嵌成 JSON，讓初始 detail panel 不必等第一次 fetch。
    for (data, 0..) |provider, index| {
        if (index != 0) try out.writeAll(",");
        try writeProviderJson(out, provider);
    }
    try out.writeAll(
        \\]; document.getElementById('providers').innerHTML=latestProviders.map(providerCard).join(''); document.getElementById('last-updated').textContent='Last Updated: '+new Date().toLocaleString();
        \\setInterval(refresh,5000);
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
///
/// 注意：這頁故意不印 token/password，只印 enabled/host/port 這類低敏感資訊。
fn renderConfigPage(allocator: std.mem.Allocator, app_config: config_mod.AppConfig) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    errdefer writer.deinit();
    const out = &writer.writer;

    try writePageStart(out, "DDNS Dashboard Config");
    try out.print(
        "<main class=\"shell\"><nav class=\"topbar\"><div><strong>Dashboard Config</strong><span>effective app.json values</span></div><a href=\"/dashboard\">Status</a></nav><section class=\"config-list\"><div><span>Dashboard enabled</span><strong>{}</strong></div><div><span>Dashboard host</span><strong>",
        .{app_config.dashboard.enabled},
    );
    try writeHtml(out, app_config.dashboard.host);
    try out.print(
        "</strong></div><div><span>Dashboard port</span><strong>{d}</strong></div><div><span>Redis enabled</span><strong>{}</strong></div><div><span>Afraid enabled</span><strong>{}</strong></div><div><span>Dynu enabled</span><strong>{}</strong></div><div><span>No-IP enabled</span><strong>{}</strong></div></section></main>",
        .{ app_config.dashboard.port, app_config.ddns.redis.enabled, app_config.afraid.enabled, app_config.dyny.enabled, app_config.noip.enabled },
    );
    try writePageEnd(out);

    buffer = writer.toArrayList();
    return try buffer.toOwnedSlice(allocator);
}

/// 產生 `/api/status.json` 的 JSON response body。
///
/// 這裡手寫 JSON，而不是依賴 `std.json.Stringify`，主要是因為資料結構中
/// 有很多固定 buffer + slice helper，手寫可以精準控制欄位名稱與輸出內容。
fn renderStatusJson(allocator: std.mem.Allocator, app_config: config_mod.AppConfig) ![]u8 {
    const data = service.readDisplayData(app_config);
    var snapshots = [_]@TypeOf(data[0].snapshot){ data[0].snapshot, data[1].snapshot, data[2].snapshot };
    const desired_ip = service.resolveDesiredIp(&snapshots);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    errdefer writer.deinit();
    const out = &writer.writer;

    // JSON object 起始，先寫 public_ip。
    try out.writeAll("{\"public_ip\":\"");
    try writeJsonStringContent(out, desired_ip);
    try out.writeAll("\",\"providers\":[");
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
///
/// 這個 helper 被 server-side render 使用；前端輪詢後的卡片由 JS 的
/// `providerCard(p)` 產生，兩邊 HTML 結構保持一致。
fn writeProviderCard(out: *std.Io.Writer, provider: service.ProviderDisplayData) !void {
    // snapshot 內是固定 buffer，透過 `xxxSlice()` 取出實際有效內容。
    const snap = provider.snapshot;
    try out.print("<article class=\"provider {s}\"><div class=\"status-strip\"></div><header><span>", .{@tagName(provider.display_status)});
    try writeHtml(out, snap.nameSlice());
    try out.print("</span><strong>{s}</strong></header><dl>", .{displayStatusLabel(provider.display_status)});
    try writeMetric(out, "Status", displayStatusLabel(provider.display_status));
    try writeMetric(out, "IP", snap.currentIpSlice());
    try out.print("<div><dt>Retry</dt><dd>{d}</dd></div><div><dt>Updated</dt><dd>{d}</dd></div>", .{ snap.retry_count, snap.updated_at });
    try out.writeAll("</dl><button type=\"button\" onclick=\"showDetail('");
    try writeHtml(out, snap.nameSlice());
    try out.writeAll("')\">View Details</button></article>");
}

/// 將單一 provider 寫成 JSON object。
///
/// 所有字串都呼叫 `writeJsonStringContent()`，避免 quote/backslash/newline
/// 造成 JSON 格式壞掉。
fn writeProviderJson(out: *std.Io.Writer, provider: service.ProviderDisplayData) !void {
    const snap = provider.snapshot;
    try out.writeAll("{\"name\":\"");
    try writeJsonStringContent(out, snap.nameSlice());
    try out.writeAll("\",\"display_status\":\"");
    try writeJsonStringContent(out, @tagName(provider.display_status));
    try out.writeAll("\",\"initialized\":");
    try out.writeAll(if (snap.initialized) "true" else "false");
    try out.writeAll(",\"status\":\"");
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

/// 寫 HTML 文件開頭、CSS 與 `<body>` 起始。
///
/// CSS 放在這裡是為了讓 Dashboard 不需要額外 static file，也就不需要
/// 新增 `/public/...` 路由。後續若切回 Jetzig，可以把這段搬成 CSS 檔。
fn writePageStart(out: *std.Io.Writer, title: []const u8) !void {
    try out.writeAll("<!doctype html><html lang=\"zh-Hant\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>");
    try writeHtml(out, title);
    try out.writeAll(
        \\</title><style>
        \\:root{color-scheme:light dark;--bg:#f6f7f9;--fg:#15171a;--muted:#667085;--line:#d8dde5;--panel:#fff;--ok:#0f7b44;--bad:#b42318;--wait:#9a5b13;--info:#175cd3;--off:#6b7280}
        \\@media (prefers-color-scheme:dark){:root{--bg:#101214;--fg:#f3f5f7;--muted:#a8b0bb;--line:#303741;--panel:#171a1f}}
        \\*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        \\.shell{width:min(1180px,calc(100% - 32px));margin:0 auto;padding:22px 0 40px}.hero{display:grid;grid-template-columns:1fr minmax(320px,440px);gap:16px;align-items:stretch;margin-bottom:14px}.brand,.public-ip,.provider,.memory-note,.detail-panel,.config-list>div{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:16px}.brand{display:grid;gap:8px}.brand strong{font-size:26px}.brand span,.public-ip span,.status-row span,.config-list span,dt{color:var(--muted)}nav{display:flex;gap:14px;margin-top:6px}a{color:var(--info);text-decoration:none;font-weight:650}.public-ip{display:grid;align-content:center}.public-ip strong{font-size:28px;overflow-wrap:anywhere}.public-ip small{color:var(--muted)}
        \\.status-row{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:18px 0 12px}.status-row strong{color:var(--ok)}.status-row em{font-style:normal;color:var(--muted)}
        \\.provider-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}.provider{position:relative;overflow:hidden}.status-strip{height:4px;background:var(--off);position:absolute;inset:0 0 auto}.provider header{display:flex;justify-content:space-between;gap:12px;align-items:center;margin:10px 0 12px}.provider header span{font-size:18px;font-weight:750;text-transform:uppercase}.provider header strong{text-transform:capitalize;font-size:12px;padding:2px 8px;border:1px solid var(--line);border-radius:999px}
        \\.provider.success .status-strip{background:var(--ok)}.provider.failed .status-strip{background:var(--bad)}.provider.retry_deferred .status-strip,.provider.initializing .status-strip{background:var(--wait)}.provider.updating .status-strip{background:var(--info)}.provider.disabled{opacity:.72}.provider.success header strong{color:var(--ok)}.provider.failed header strong{color:var(--bad)}.provider.retry_deferred header strong,.provider.initializing header strong{color:var(--wait)}.provider.updating header strong{color:var(--info)}
        \\dl{margin:0;display:grid;gap:8px}dl div{display:grid;grid-template-columns:92px minmax(0,1fr);gap:10px}dd{margin:0;font-weight:650;overflow-wrap:anywhere}button{border:1px solid var(--line);background:transparent;color:var(--fg);border-radius:7px;padding:7px 10px;font:inherit;font-weight:650;cursor:pointer}.provider button{width:100%;margin-top:14px}.memory-note{margin-top:14px;color:var(--muted)}.memory-note strong{color:var(--fg)}
        \\.detail-panel{margin-top:14px}.detail-panel[hidden]{display:none}.detail-panel header{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:12px}.detail-panel header strong{font-size:18px}.detail-panel dl div{grid-template-columns:150px minmax(0,1fr);border-top:1px solid var(--line);padding-top:8px}.config-list{display:grid;gap:10px}.config-list>div{display:flex;justify-content:space-between;gap:16px}.config-list strong{overflow-wrap:anywhere;text-align:right}
        \\@media (max-width:760px){.shell{width:min(100% - 20px,1180px);padding-top:12px}.hero,.provider-grid{grid-template-columns:1fr}.brand strong{font-size:21px}.public-ip strong{font-size:22px}.status-row{align-items:flex-start;flex-direction:column}.config-list>div{align-items:flex-start}.detail-panel dl div{grid-template-columns:1fr}}
        \\</style></head><body>
    );
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

test "dashboard json exposes providers" {
    const allocator = std.testing.allocator;
    const json = try renderStatusJson(allocator, .{});
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"providers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"public_ip\"") != null);
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
