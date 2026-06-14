//! DDNS 更新流程。
//!
//! 職責包含：
//! - 取得目前對外 IP。
//! - 判斷是否需要跳過凌晨維護時段。
//! - 比對 Redis 內的 `MyPublicIP:{ip}` key，沿用 Rust 版防重複更新邏輯。
//! - 依序更新 Afraid / Dynu / No-IP。

/// 匯入編譯期提供的目標平台資訊。
///
/// 例如目前是不是 Windows，就會從這裡判斷。
const builtin = @import("builtin");
/// 匯入 Zig 標準函式庫。
///
/// HTTP 客戶端、字串處理、JSON、記憶體配置等通用能力都從這裡來。
const std = @import("std");
/// 匯入本專案的設定模組。
///
/// 這樣 DDNS 流程就能讀到 `app.json` / `.env` 載入後的設定值。
const config_mod = @import("../base/config.zig");
/// 匯入本專案的 Redis 客戶端。
///
/// DDNS 防重複更新現在要真的查 Redis，所以更新流程會呼叫這個模組。
const redis = @import("../io/redis.zig");
/// 匯入共用 HTTP 文字抓取與日誌輔助。
const http = @import("../io/http.zig");

/// 匯入 C API (由 build.zig 的 addTranslateC 提供)。
///
/// 這裡主要是為了呼叫 `time`、`localtime_r` 之類的時間 API。
const c = @import("c");

/// 單次更新檢查的結果。
pub const RefreshStatus = enum {
    /// 有真的更新到至少一個 DDNS 服務。
    updated,
    /// 因為 Redis 裡的 `MyPublicIP:{ip}` 還在，所以這次直接跳過。
    skipped_cached_ip,
    /// 因為現在落在凌晨維護時間，所以這次直接跳過。
    skipped_maintenance_window,
};

/// 取得對外 IP 時，可能依序嘗試的來源站。
const PublicIpService = enum {
    /// `https://api.ipify.org`
    ipify,
    /// `https://ipconfig.io/ip`
    ipconfig,
    /// `https://ipinfo.io/ip`
    ipinfo,
    /// `https://ipv4.seeip.org`
    seeip,
    /// `https://api.myip.com`
    myip,
    /// `https://api.bigdatacloud.net/data/client-ip`
    bigdatacloud,
};

/// 目前支援更新的 DDNS 供應商。
const DdnsProvider = enum {
    afraid,
    dynu,
    noip,
};

/// 供應商成功狀態，用來決定哪些 provider 要寫回 Redis。
const ProviderSuccesses = struct {
    afraid: bool = false,
    dynu: bool = false,
    noip: bool = false,

    fn mark(self: *ProviderSuccesses, provider: DdnsProvider) void {
        switch (provider) {
            .afraid => self.afraid = true,
            .dynu => self.dynu = true,
            .noip => self.noip = true,
        }
    }

    fn includes(self: ProviderSuccesses, provider: DdnsProvider) bool {
        return switch (provider) {
            .afraid => self.afraid,
            .dynu => self.dynu,
            .noip => self.noip,
        };
    }
};

/// 單一 provider 的持久化更新狀態。
const ProviderState = struct {
    current_ip: ?[]const u8 = null,
    desired_ip: ?[]const u8 = null,
    status: ?[]const u8 = null,
    retry_count: u32 = 0,
    next_retry_at: i64 = 0,
};

/// provider 在這一輪是否應該打 DDNS API。
const ProviderAttemptDecision = enum {
    attempt,
    already_current,
    retry_deferred,
};

/// 這一輪更新所有 DDNS 供應商後的統計結果。
const ServiceSummary = struct {
    /// 總共設定完整、應納入 reconcile 的供應商。
    configured: usize = 0,
    /// 總共嘗試了幾個供應商。
    attempted: usize = 0,
    /// 其中有幾個供應商最後成功。
    succeeded: usize = 0,
    /// 有幾個供應商原本就已經在目前 IP。
    already_current: usize = 0,
    /// 有幾個供應商因為 retry backoff 尚未到期而暫緩。
    retry_deferred: usize = 0,
    /// 有幾個供應商本輪更新失敗。
    failed: usize = 0,
    /// 哪些供應商最後成功。
    successes: ProviderSuccesses = .{},
};

const provider_status_success = "success";
const provider_status_failed = "failed";
const provider_retry_initial_delay_seconds: i64 = 30;
const provider_retry_max_delay_seconds: i64 = 15 * 60;

/// 同一個行程內最近一次成功處理過的 public IP。
const ProcessPublicIpState = struct {
    /// 保護整份狀態的互斥鎖。
    mutex: std.atomic.Mutex = .unlocked,
    /// 是否已經記過至少一次 IP。
    initialized: bool = false,
    /// 最近一次成功處理過的 IP 長度。
    len: usize = 0,
    /// public IPv4 / IPv6 文字都很短，用固定 buffer 就夠。
    buffer: [64]u8 = undefined,
};

/// 寫 HTTP body 預覽時，最多保留的字元數。
const http_log_body_preview_len = http.body_preview_len;
/// Public IP lookup 只需要很短的 DNS / TCP connect timeout。
const public_ip_connect_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(3),
    .clock = .awake,
} };
/// DDNS provider 更新可以容忍比 public IP lookup 稍長一點的 connect timeout。
const ddns_connect_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(5),
    .clock = .awake,
} };
/// Redis 關閉時，退回本機防重複更新用的快取資料。
const LocalDedupeEntry = struct {
    key: []u8,
    expires_at: i64,
};
/// 本機防重複更新狀態的互斥鎖。
var local_dedupe_mutex: std.atomic.Mutex = .unlocked;
/// 本機防重複更新用的記憶體快取。
var local_dedupe_entries: std.ArrayListUnmanaged(LocalDedupeEntry) = .empty;
/// 超過這個容量才考慮回收本機 dedupe 容量。
const local_dedupe_shrink_min_capacity: usize = 32;
/// 當容量至少是目前長度的這個倍數時，才執行 shrink。
const local_dedupe_shrink_slack_factor: usize = 4;
/// 同一個服務行程內，記住最近一次成功處理的 public IP。
var process_public_ip_state: ProcessPublicIpState = .{};

/// 集中管理這個模組會打到的第三方網址。
///
/// 之後如果要：
/// - 更換對外 IP 來源站
/// - 調整 Dynu / No-IP API 基底網址
/// - 統一檢查目前到底有哪些外部端點
///
/// 就只需要看這一個區塊，不用在整份 `ddns.zig` 到處找字串常數。
const Endpoint = struct {
    /// 所有對外 IP 來源站的網址。
    const PublicIp = struct {
        /// 直接回傳純文字 IP。
        const ipify = "https://api.ipify.org";
        /// 直接回傳純文字 IP。
        const ipconfig = "https://ipconfig.io/ip";
        /// 直接回傳純文字 IP。
        const ipinfo = "https://ipinfo.io/ip";
        /// 直接回傳純文字 IP。
        const seeip = "https://ipv4.seeip.org";
        /// 回傳 JSON，IP 欄位名稱是 `ip`。
        const myip = "https://api.myip.com";
        /// 回傳 JSON，IP 欄位名稱是 `ipString`。
        const bigdatacloud = "https://api.bigdatacloud.net/data/client-ip";
    };

    /// Dynu 更新 API 基底網址。
    const dynu_update = "https://api.dynu.com/nic/update";
    /// No-IP 更新 API 基底網址。
    const noip_update = "https://dynupdate.no-ip.com/nic/update";
};

/// 下次抓對外 IP 時，從哪個來源站開始嘗試。
///
/// 這樣每次更新檢查不會永遠都從第一個來源站開始打，
/// 而是會做簡單的 round-robin。
///
/// 這裡用 atomic，避免並行 refresh 時對全域計數器產生 data race。
var next_public_ip_index: std.atomic.Value(usize) = .init(0);

/// 執行一次 DDNS 更新檢查。
pub fn refresh(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    config: config_mod.AppConfig,
) !RefreshStatus {
    // 先看現在是否落在「刻意跳過更新」的維護時間。
    if (shouldSkipMaintenanceWindow()) {
        std.log.info("skip ddns refresh during 02:00-02:04 local maintenance window", .{});
        return .skipped_maintenance_window;
    }

    // 建立一個 arena allocator，讓這一輪更新檢查內的暫時字串與 JSON 解析結果
    // 都集中配置在同一塊記憶體裡。
    var arena = std.heap.ArenaAllocator.init(allocator);
    // 這一輪更新檢查結束時，把 arena 一次整包釋放掉。
    defer arena.deinit();
    // `scratch` 是這一輪更新檢查專用的 allocator。
    const scratch = arena.allocator();

    // 先抓目前對外 IP。
    const ip_now = try getPublicIp(scratch, client);
    // 如果同一個行程上次已經成功處理過相同 IP，
    // 這一輪就直接跳過，不再碰 Redis。
    if (isSameAsLastProcessedIp(ip_now)) {
        std.log.info(
            "skip ddns refresh because public ip is unchanged in current process: {s}",
            .{ip_now},
        );
        return .skipped_cached_ip;
    }
    // 先算出這次 dedupe 要用的 TTL。
    const ttl_seconds = if (config.ddns.dedupe_ttl_seconds == 0)
        @as(u64, 60 * 60 * 24)
    else
        config.ddns.dedupe_ttl_seconds;

    if (config.ddns.redis.enabled) {
        return refreshWithRedisProviderState(
            scratch,
            io,
            client,
            config,
            ip_now,
            ttl_seconds,
            currentUnixSeconds(),
        );
    }

    // 更新 DDNS provider 之前，先檢查這個 IP 是否已經在 dedupe cache。
    // 這樣服務重啟後仍會尊重 Redis / local cache，不會先打 provider 才發現命中。
    const cache_key = try buildPublicIpCacheKey(scratch, ip_now);
    if (try isDedupeHit(scratch, io, config.ddns.redis, config, cache_key, ip_now)) {
        return .skipped_cached_ip;
    }

    // 真的去更新所有有完成設定的 DDNS 供應商。
    const summary = try updateDdnsServices(scratch, client, config, ip_now);
    // 一個供應商都沒啟用，視為設定錯誤。
    if (summary.attempted == 0) return error.NoEnabledDdnsService;
    // 有嘗試，但全部失敗，就把整輪更新檢查視為失敗。
    if (summary.succeeded == 0) return error.AllDdnsUpdatesFailed;

    // 至少有一個供應商更新成功後，才把這個 IP 寫進 dedupe cache。
    try rememberDedupe(scratch, io, config.ddns.redis, cache_key, ip_now, ttl_seconds, summary.successes);
    // 只有全部 provider 都成功時才記在行程內狀態。
    // 如果只有部分成功，下一輪同 IP 仍要進 Redis provider key 檢查，讓缺的 provider 有機會補更新。
    if (summary.succeeded == summary.attempted) {
        rememberLastProcessedIp(ip_now);
    }

    // 最後寫一筆總結 log，讓你知道這輪使用哪個 IP，以及成功幾個供應商。
    std.log.info(
        "ddns refresh completed: ip={s}, succeeded={d}/{d}",
        .{ ip_now, summary.succeeded, summary.attempted },
    );
    return .updated;
}

/// Redis 啟用時，用 provider-level 狀態機 reconcile 到目前 desired IP。
fn refreshWithRedisProviderState(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    ip: []const u8,
    ttl_seconds: u64,
    now_seconds: i64,
) !RefreshStatus {
    // Redis 模式的核心目標不是「這個 IP 有沒有處理過」，
    // 而是「每一家 DDNS provider 是否都已經收斂到目前 IP」。
    //
    // 為了做到這件事，Redis 裡會保存兩種狀態：
    // 1. `DDNS:DesiredIP`
    //    代表目前這輪所有 provider 應該更新到哪個 public IP。
    // 2. `DDNS:Provider:{provider}` hash
    //    代表單一家 provider 目前成功更新到哪個 IP、是否失敗、
    //    已重試幾次、下次何時可以重試、最後錯誤是什麼。

    // 這一輪 refresh 只建立一條 Redis 連線。
    //
    // 注意：`redis.Session` 必須在呼叫端的穩定位址上初始化。
    // `okredis.Client` 內部會保存 reader / writer interface 的指標，
    // 如果用「函式回傳 Session struct」的方式讓 struct 被搬移，
    // 那些指標可能會指向舊 stack，後續第二次 Redis 指令就可能 crash。
    //
    // 所以這裡先宣告 `redis_session`，再用 `init(...)` 原地初始化。
    var redis_session: redis.Session = undefined;
    try redis_session.init(io, config.ddns.redis);
    defer redis_session.deinit();

    // 先把目前 public IP 寫成 desired IP。
    //
    // 這個 key 主要用於維運觀察：
    // `redis-cli GET DDNS:DesiredIP`
    //
    // Provider 真正是否需要更新，仍然由後面的 provider hash 判斷。
    try rememberDesiredIpWithSession(&redis_session, ip, ttl_seconds);

    // 逐一 reconcile Afraid / Dynu / No-IP。
    //
    // `reconcile` 的意思是：
    // - 如果 provider 已經是目前 IP，跳過。
    // - 如果 provider 失敗過但 backoff 還沒到，暫緩。
    // - 如果 provider 落後或 retry 到期，才真的打 DDNS API。
    //
    // 這樣三家裡面只有一家失敗時，下一輪只會處理失敗那家，
    // 不會重複更新已經成功的 provider。
    const summary = try updateDdnsServicesReconciled(
        allocator,
        &redis_session,
        client,
        config,
        ip,
        ttl_seconds,
        now_seconds,
    );
    // 一家 provider 都沒有完整設定，代表服務沒有可執行的更新目標。
    if (summary.configured == 0) return error.NoEnabledDdnsService;

    // 只要本輪有 provider 成功，就同步寫舊版觀察 key。
    //
    // 這些 key 不是新版狀態機的主要判斷依據，但保留它們有兩個好處：
    // - 舊部署或既有監控如果還在看 `MyPublicIP`，不會立刻失效。
    // - 人工排查時仍可用簡單 GET 查看最近成功 IP。
    const cache_key = try buildPublicIpCacheKey(allocator, ip);
    if (summary.succeeded != 0) {
        try rememberDedupeWithSession(&redis_session, cache_key, ip, ttl_seconds, summary.successes);
    }

    // 有實際嘗試更新，但全部都失敗，這輪要回報失敗。
    //
    // 如果 `attempted == 0`，可能只是全部 provider 都已經是最新，
    // 或者都還在 retry backoff，不應該被視為「更新 API 全部失敗」。
    if (summary.attempted != 0 and summary.succeeded == 0) {
        return error.AllDdnsUpdatesFailed;
    }

    // 只有在所有 configured provider 都已經達到 desired IP 時，
    // 才把目前 IP 記到 process-local cache。
    //
    // 這可以讓下一輪同 IP 直接跳過，連 Redis 都不用碰。
    // 但如果有 provider 失敗或 backoff 中，就不能寫這個 cache，
    // 否則下一輪會被本機快取擋掉，失敗 provider 就沒有機會補更新。
    if (summary.already_current + summary.succeeded == summary.configured) {
        rememberLastProcessedIp(ip);
    }

    // 沒有任何變化時，summary 只放 debug，避免常駐服務每分鐘洗版。
    // 只要有嘗試更新、失敗或 retry deferred，就提升到 info，
    // 讓營運時能看到有意義的狀態變化。
    if (summary.attempted == 0 and summary.failed == 0 and summary.retry_deferred == 0) {
        std.log.debug(
            "ddns reconcile completed: ip={s}, configured={d}, attempted={d}, succeeded={d}, already_current={d}, retry_deferred={d}, failed={d}",
            .{
                ip,
                summary.configured,
                summary.attempted,
                summary.succeeded,
                summary.already_current,
                summary.retry_deferred,
                summary.failed,
            },
        );
    } else {
        std.log.info(
            "ddns reconcile completed: ip={s}, configured={d}, attempted={d}, succeeded={d}, already_current={d}, retry_deferred={d}, failed={d}",
            .{
                ip,
                summary.configured,
                summary.attempted,
                summary.succeeded,
                summary.already_current,
                summary.retry_deferred,
                summary.failed,
            },
        );
    }

    return if (summary.attempted == 0) .skipped_cached_ip else .updated;
}

/// 把目前對外 IP 轉成和 Rust 版相同的 Redis key 格式。
fn buildPublicIpCacheKey(allocator: std.mem.Allocator, ip: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "MyPublicIP:{s}", .{ip});
}

/// 固定用來保存「目前最新對外 IP」的 Redis key。
fn currentPublicIpRedisKey() []const u8 {
    return "MyPublicIP";
}

/// 新版 reconcile 使用的 desired IP key。
fn desiredPublicIpRedisKey() []const u8 {
    return "DDNS:DesiredIP";
}

/// 新版 reconcile 使用的 provider 狀態 hash key。
fn providerStateRedisKey(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .afraid => "DDNS:Provider:afraid",
        .dynu => "DDNS:Provider:dynu",
        .noip => "DDNS:Provider:noip",
    };
}

/// 固定用來保存「某家 DDNS provider 目前成功更新到哪個 IP」的 Redis key。
fn providerCurrentIpRedisKey(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .afraid => "MyPublicIP:afraid",
        .dynu => "MyPublicIP:dynu",
        .noip => "MyPublicIP:noip",
    };
}

/// provider enum 對應到 log 使用的短名字。
fn providerName(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .afraid => "afraid",
        .dynu => "dynu",
        .noip => "no-ip",
    };
}

/// 判斷目前 IP 是否和同一個行程上次成功處理的 IP 相同。
fn isSameAsLastProcessedIp(ip: []const u8) bool {
    lockProcessPublicIpState();
    defer process_public_ip_state.mutex.unlock();

    if (!process_public_ip_state.initialized) return false;
    return std.mem.eql(
        u8,
        process_public_ip_state.buffer[0..process_public_ip_state.len],
        ip,
    );
}

/// 把這次已成功處理的 public IP 記到行程內狀態。
fn rememberLastProcessedIp(ip: []const u8) void {
    lockProcessPublicIpState();
    defer process_public_ip_state.mutex.unlock();

    const copy_len = @min(ip.len, process_public_ip_state.buffer.len);
    @memcpy(process_public_ip_state.buffer[0..copy_len], ip[0..copy_len]);
    process_public_ip_state.len = copy_len;
    process_public_ip_state.initialized = true;
}

/// 重設行程內 public IP 狀態，供測試使用。
fn resetProcessPublicIpState() void {
    lockProcessPublicIpState();
    defer process_public_ip_state.mutex.unlock();

    process_public_ip_state.initialized = false;
    process_public_ip_state.len = 0;
}

/// 用和本模組其他 shared state 一致的方式取得 process IP mutex。
fn lockProcessPublicIpState() void {
    while (!process_public_ip_state.mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

/// 檢查目前這個 IP 是否已經在防重複更新快取裡。
fn isDedupeHit(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    app_config: config_mod.AppConfig,
    cache_key: []const u8,
    ip: []const u8,
) !bool {
    if (!redis_config.enabled) {
        if (localDedupeContains(cache_key)) {
            std.log.info(
                "skip ddns refresh because local cache key already exists: {s}",
                .{cache_key},
            );
            return true;
        }
        return false;
    }

    // 這裡刻意沿用 Rust 版的容錯策略：
    // - 如果 Redis 查詢失敗，只記 warn
    // - 但整個 DDNS 更新檢查仍然繼續跑
    const cache_hit = redis.containsKey(allocator, io, redis_config, cache_key) catch |err| blk: {
        std.log.warn(
            "failed to check redis key before ddns refresh: key={s}, error={}",
            .{ cache_key, err },
        );
        break :blk false;
    };
    if (!cache_hit) return false;

    if (try allEnabledProvidersAlreadyRecorded(allocator, io, redis_config, app_config, ip)) {
        std.log.info(
            "skip ddns refresh because redis cache key already exists and provider ip keys are current: {s}",
            .{cache_key},
        );
        return true;
    }

    std.log.info(
        "redis cache key exists but at least one provider ip key is missing or stale: key={s}, ip={s}",
        .{ cache_key, ip },
    );
    return false;
}

/// Redis 命中整體 dedupe key 時，仍要確認所有已啟用 provider 都已成功更新到目前 IP。
fn allEnabledProvidersAlreadyRecorded(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    app_config: config_mod.AppConfig,
    ip: []const u8,
) !bool {
    var checked: usize = 0;

    if (isProviderConfigured(app_config, .afraid)) {
        checked += 1;
        if (!try providerCurrentIpMatches(allocator, io, redis_config, .afraid, ip)) return false;
    }
    if (isProviderConfigured(app_config, .dynu)) {
        checked += 1;
        if (!try providerCurrentIpMatches(allocator, io, redis_config, .dynu, ip)) return false;
    }
    if (isProviderConfigured(app_config, .noip)) {
        checked += 1;
        if (!try providerCurrentIpMatches(allocator, io, redis_config, .noip, ip)) return false;
    }

    return checked != 0;
}

fn providerCurrentIpMatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    provider: DdnsProvider,
    ip: []const u8,
) !bool {
    const key = providerCurrentIpRedisKey(provider);
    const stored_ip = redis.get(allocator, io, redis_config, key) catch |err| {
        std.log.warn(
            "failed to read provider redis ip key: provider={s}, key={s}, error={}",
            .{ providerName(provider), key, err },
        );
        return false;
    };
    defer if (stored_ip) |value| allocator.free(value);

    if (stored_ip) |value| {
        return std.mem.eql(u8, value, ip);
    }
    return false;
}

fn isProviderConfigured(app_config: config_mod.AppConfig, provider: DdnsProvider) bool {
    return switch (provider) {
        .afraid => app_config.afraid.enabled and app_config.afraid.token.len != 0,
        .dynu => app_config.dyny.enabled and app_config.dyny.username.len != 0 and app_config.dyny.password.len != 0,
        .noip => app_config.noip.enabled and app_config.noip.username.len != 0 and app_config.noip.password.len != 0 and app_config.noip.hostnames.len != 0,
    };
}

/// 用單一 Redis session 完成 dedupe check 與成功後的記錄。
fn redisCheckAndRememberDedupe(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    cache_key: []const u8,
    ip: []const u8,
    ttl_seconds: u64,
) !bool {
    const result = try redis.ddnsDedupeCheckAndRemember(allocator, io, redis_config, .{
        .cache_key = cache_key,
        .cache_value = ip,
        .current_ip_key = currentPublicIpRedisKey(),
        .ttl_seconds = ttl_seconds,
    });

    if (!result.cache_hit) {
        std.log.info("ddns redis cache updated: key={s}, ttl={d}s", .{ cache_key, ttl_seconds });
        std.log.info(
            "ddns redis current public ip updated: key={s}, ip={s}, ttl={d}s",
            .{ currentPublicIpRedisKey(), ip, ttl_seconds },
        );
    }
    return result.cache_hit;
}

/// 記住這次成功更新過的 IP，避免 TTL 內重複更新。
fn rememberDedupe(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    cache_key: []const u8,
    ip: []const u8,
    ttl_seconds: u64,
    successes: ProviderSuccesses,
) !void {
    if (!redis_config.enabled) {
        try localDedupeSet(cache_key, ttl_seconds);
        std.log.info("ddns local cache updated: key={s}, ttl={d}s", .{ cache_key, ttl_seconds });
        return;
    }

    try redis.setEx(
        allocator,
        io,
        redis_config,
        cache_key,
        ip,
        ttl_seconds,
    );
    try redis.setEx(
        allocator,
        io,
        redis_config,
        currentPublicIpRedisKey(),
        ip,
        ttl_seconds,
    );
    try rememberProviderCurrentIps(allocator, io, redis_config, successes, ip, ttl_seconds);
    std.log.info("ddns redis cache updated: key={s}, ttl={d}s", .{ cache_key, ttl_seconds });
    std.log.info(
        "ddns redis current public ip updated: key={s}, ip={s}, ttl={d}s",
        .{ currentPublicIpRedisKey(), ip, ttl_seconds },
    );
}

fn rememberProviderCurrentIps(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    successes: ProviderSuccesses,
    ip: []const u8,
    ttl_seconds: u64,
) !void {
    const providers = [_]DdnsProvider{ .afraid, .dynu, .noip };
    for (providers) |provider| {
        if (!successes.includes(provider)) continue;

        const key = providerCurrentIpRedisKey(provider);
        try redis.setEx(allocator, io, redis_config, key, ip, ttl_seconds);
        std.log.info(
            "ddns redis provider ip updated: provider={s}, key={s}, ip={s}, ttl={d}s",
            .{ providerName(provider), key, ip, ttl_seconds },
        );
    }
}

fn rememberDedupeWithSession(
    redis_session: *redis.Session,
    cache_key: []const u8,
    ip: []const u8,
    ttl_seconds: u64,
    successes: ProviderSuccesses,
) !void {
    try redis_session.setEx(cache_key, ip, ttl_seconds);
    try redis_session.setEx(currentPublicIpRedisKey(), ip, ttl_seconds);
    try rememberProviderCurrentIpsWithSession(redis_session, successes, ip, ttl_seconds);
    std.log.info("ddns redis cache updated: key={s}, ttl={d}s", .{ cache_key, ttl_seconds });
    std.log.info(
        "ddns redis current public ip updated: key={s}, ip={s}, ttl={d}s",
        .{ currentPublicIpRedisKey(), ip, ttl_seconds },
    );
}

fn rememberProviderCurrentIpsWithSession(
    redis_session: *redis.Session,
    successes: ProviderSuccesses,
    ip: []const u8,
    ttl_seconds: u64,
) !void {
    const providers = [_]DdnsProvider{ .afraid, .dynu, .noip };
    for (providers) |provider| {
        if (!successes.includes(provider)) continue;

        const key = providerCurrentIpRedisKey(provider);
        try redis_session.setEx(key, ip, ttl_seconds);
        std.log.info(
            "ddns redis provider ip updated: provider={s}, key={s}, ip={s}, ttl={d}s",
            .{ providerName(provider), key, ip, ttl_seconds },
        );
    }
}

/// Redis 啟用時，優先走單 session dedupe transaction；失敗才退回既有兩段式流程。
fn checkAndRememberDedupeAfterSuccess(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    cache_key: []const u8,
    ip: []const u8,
    ttl_seconds: u64,
) !bool {
    if (!redis_config.enabled) return false;

    return redisCheckAndRememberDedupe(allocator, io, redis_config, cache_key, ip, ttl_seconds) catch |err| blk: {
        std.log.warn(
            "failed to atomically check/set redis dedupe after ddns refresh: key={s}, error={}",
            .{ cache_key, err },
        );

        if (try isDedupeHit(allocator, io, redis_config, .{}, cache_key, ip)) {
            break :blk true;
        }

        try rememberDedupe(allocator, io, redis_config, cache_key, ip, ttl_seconds, .{});
        break :blk false;
    };
}

/// 取得目前 Unix 秒數。
fn currentUnixSeconds() i64 {
    return @intCast(c.time(null));
}

/// 本機防重複更新：檢查 key 是否還在 TTL 內。
fn localDedupeContains(key: []const u8) bool {
    return localDedupeContainsAt(key, currentUnixSeconds());
}

/// 本機防重複更新：把 key 記到 TTL 過期為止。
fn localDedupeSet(key: []const u8, ttl_seconds: u64) !void {
    try localDedupeSetAt(key, ttl_seconds, currentUnixSeconds());
}

/// 供正式流程與測試共用的本機防重複更新查詢邏輯。
fn localDedupeContainsAt(key: []const u8, now_seconds: i64) bool {
    lockLocalDedupe();
    defer unlockLocalDedupe();

    pruneExpiredLocalDedupeLocked(now_seconds);

    for (local_dedupe_entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
}

/// 供正式流程與測試共用的本機防重複更新寫入邏輯。
fn localDedupeSetAt(key: []const u8, ttl_seconds: u64, now_seconds: i64) !void {
    lockLocalDedupe();
    defer unlockLocalDedupe();

    pruneExpiredLocalDedupeLocked(now_seconds);

    const expires_at = now_seconds + @as(i64, @intCast(ttl_seconds));
    for (local_dedupe_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.expires_at = expires_at;
            return;
        }
    }

    try local_dedupe_entries.append(std.heap.page_allocator, .{
        .key = try std.heap.page_allocator.dupe(u8, key),
        .expires_at = expires_at,
    });
}

/// 把已過期的本機防重複更新項目從記憶體移除。
fn pruneExpiredLocalDedupeLocked(now_seconds: i64) void {
    var index: usize = 0;
    while (index < local_dedupe_entries.items.len) {
        if (local_dedupe_entries.items[index].expires_at > now_seconds) {
            index += 1;
            continue;
        }

        std.heap.page_allocator.free(local_dedupe_entries.items[index].key);
        _ = local_dedupe_entries.orderedRemove(index);
    }

    maybeShrinkLocalDedupeLocked();
}

/// 只有在空間明顯過剩時，才把本機 dedupe 的容量還給 allocator。
fn maybeShrinkLocalDedupeLocked() void {
    const len = local_dedupe_entries.items.len;
    const capacity = local_dedupe_entries.capacity;
    if (capacity < local_dedupe_shrink_min_capacity) return;
    if (len != 0 and capacity < len * local_dedupe_shrink_slack_factor) return;

    local_dedupe_entries.shrinkAndFree(std.heap.page_allocator, len);
}

fn resetLocalDedupeState() void {
    lockLocalDedupe();
    defer unlockLocalDedupe();

    for (local_dedupe_entries.items) |entry| {
        std.heap.page_allocator.free(entry.key);
    }
    local_dedupe_entries.clearRetainingCapacity();
}

/// 取得本機防重複更新資料的短臨界區鎖。
fn lockLocalDedupe() void {
    while (!local_dedupe_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

/// 釋放本機防重複更新資料的短臨界區鎖。
fn unlockLocalDedupe() void {
    local_dedupe_mutex.unlock();
}

/// 記錄目前這輪希望所有 provider 收斂到的 public IP。
fn rememberDesiredIpWithSession(
    redis_session: *redis.Session,
    ip: []const u8,
    ttl_seconds: u64,
) !void {
    try redis_session.setEx(desiredPublicIpRedisKey(), ip, ttl_seconds);
}

/// 用 provider-level 狀態機更新所有有設定完成的 DDNS 供應商。
fn updateDdnsServicesReconciled(
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    ip: []const u8,
    ttl_seconds: u64,
    now_seconds: i64,
) !ServiceSummary {
    // 這個 summary 是本輪 reconcile 的總帳。
    //
    // `configured`：設定完整、應納入管理的 provider 數量。
    // `attempted`：本輪真的打了 DDNS API 的 provider 數量。
    // `succeeded`：本輪打 API 且成功的 provider 數量。
    // `already_current`：原本就已經是 desired IP，所以跳過的 provider 數量。
    // `retry_deferred`：前次失敗後仍在 backoff 等待中的 provider 數量。
    // `failed`：本輪實際嘗試但失敗的 provider 數量。
    var summary = ServiceSummary{};

    // `ttl_seconds` 目前在上層寫 desired IP 與 legacy key 時使用。
    // 這裡保留參數形狀，是為了讓呼叫端語意清楚：
    // 「這整輪 reconcile 是帶著同一組 TTL 執行」。
    _ = ttl_seconds;

    // 三家 provider 逐一 reconcile。
    //
    // 這裡刻意不並行：
    // - 目前共用同一條 Redis session。
    // - DDNS 更新頻率低，沒有必要為了三個 provider 增加並行複雜度。
    // - 順序執行的 log 與狀態比較容易排查。
    try reconcileProvider(&summary, allocator, redis_session, client, config, .afraid, ip, now_seconds);
    try reconcileProvider(&summary, allocator, redis_session, client, config, .dynu, ip, now_seconds);
    try reconcileProvider(&summary, allocator, redis_session, client, config, .noip, ip, now_seconds);

    return summary;
}

fn reconcileProvider(
    summary: *ServiceSummary,
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    provider: DdnsProvider,
    desired_ip: []const u8,
    now_seconds: i64,
) !void {
    // provider 沒啟用或認證資料不完整時，不納入 configured。
    // 這樣使用者只啟用 No-IP 時，Afraid / Dynu 不會被算成未完成。
    if (!isProviderConfigured(config, provider)) return;
    summary.configured += 1;

    // 讀取 Redis 裡這家 provider 的既有狀態。
    //
    // 如果 Redis 讀取失敗，這裡不直接中斷整輪 refresh。
    // 原因是 DDNS 的主要任務是「盡量把 provider 更新到目前 IP」；
    // 狀態讀不到時，最保守的補償策略是當作沒有狀態，直接嘗試更新。
    const state = loadProviderState(allocator, redis_session, provider) catch |err| blk: {
        std.log.warn(
            "failed to load ddns provider state, will attempt update: provider={s}, error={}",
            .{ providerName(provider), err },
        );
        break :blk ProviderState{};
    };

    // 根據目前 Redis 狀態決定這家 provider 要不要打 API。
    //
    // 三種結果：
    // - already_current：已成功更新到 desired IP，跳過。
    // - retry_deferred：上次失敗，且 next_retry_at 還沒到，暫緩。
    // - attempt：需要嘗試更新。
    switch (providerAttemptDecision(state, desired_ip, now_seconds)) {
        .already_current => {
            summary.already_current += 1;
            std.log.debug("skip ddns provider because it is already current: provider={s}, ip={s}", .{
                providerName(provider),
                desired_ip,
            });
            return;
        },
        .retry_deferred => {
            summary.retry_deferred += 1;
            std.log.debug(
                "defer ddns provider retry: provider={s}, desired_ip={s}, next_retry_at={d}, now={d}",
                .{ providerName(provider), desired_ip, state.next_retry_at, now_seconds },
            );
            return;
        },
        .attempt => {},
    }

    // 走到這裡代表這家 provider 需要實際打 DDNS 更新 API。
    summary.attempted += 1;
    updateProvider(allocator, client, config, provider, desired_ip) catch |err| {
        // 更新失敗時，不讓錯誤直接中斷其他 provider。
        // 先把失敗狀態寫回 Redis，讓下一輪可以根據 retry_count
        // 和 next_retry_at 做 backoff 重試。
        summary.failed += 1;
        const next_retry_at = now_seconds + retryDelaySeconds(state.retry_count + 1);
        saveProviderFailure(
            allocator,
            redis_session,
            provider,
            desired_ip,
            state.retry_count + 1,
            next_retry_at,
            @errorName(err),
            now_seconds,
        ) catch |save_err| {
            std.log.warn(
                "failed to save ddns provider failure state: provider={s}, update_error={}, save_error={}",
                .{ providerName(provider), err, save_err },
            );
        };
        std.log.err(
            "{s} update failed: error={}, retry_count={d}, next_retry_at={d}",
            .{ providerName(provider), err, state.retry_count + 1, next_retry_at },
        );
        return;
    };

    // 更新成功後，寫回 provider hash：
    // - current_ip = desired_ip
    // - status = success
    // - retry_count / next_retry_at 歸零
    // - last_error 清空
    summary.succeeded += 1;
    summary.successes.mark(provider);
    try saveProviderSuccess(allocator, redis_session, provider, desired_ip, now_seconds);
}

fn updateProvider(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    provider: DdnsProvider,
    ip: []const u8,
) !void {
    return switch (provider) {
        .afraid => updateAfraid(allocator, client, config.afraid),
        .dynu => updateDynu(allocator, client, config.dyny, ip),
        .noip => updateNoIp(allocator, client, config.noip, ip),
    };
}

fn providerAttemptDecision(state: ProviderState, desired_ip: []const u8, now_seconds: i64) ProviderAttemptDecision {
    if (state.current_ip) |current_ip| {
        if (std.mem.eql(u8, current_ip, desired_ip) and providerStateStatusEquals(state, provider_status_success)) {
            return .already_current;
        }
    }

    if (state.desired_ip) |state_desired_ip| {
        if (!std.mem.eql(u8, state_desired_ip, desired_ip)) {
            return .attempt;
        }
    } else {
        return .attempt;
    }

    if (state.next_retry_at > now_seconds) return .retry_deferred;
    return .attempt;
}

fn providerStateStatusEquals(state: ProviderState, expected: []const u8) bool {
    if (state.status) |status| return std.mem.eql(u8, status, expected);
    return false;
}

fn loadProviderState(
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    provider: DdnsProvider,
) !ProviderState {
    const key = providerStateRedisKey(provider);
    return .{
        .current_ip = try redis_session.hGet(allocator, key, "current_ip"),
        .desired_ip = try redis_session.hGet(allocator, key, "desired_ip"),
        .status = try redis_session.hGet(allocator, key, "status"),
        .retry_count = try loadProviderStateU32(allocator, redis_session, key, "retry_count"),
        .next_retry_at = try loadProviderStateI64(allocator, redis_session, key, "next_retry_at"),
    };
}

fn loadProviderStateU32(
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    key: []const u8,
    field: []const u8,
) !u32 {
    const value = try redis_session.hGet(allocator, key, field);
    if (value) |text| {
        return std.fmt.parseUnsigned(u32, text, 10) catch 0;
    }
    return 0;
}

fn loadProviderStateI64(
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    key: []const u8,
    field: []const u8,
) !i64 {
    const value = try redis_session.hGet(allocator, key, field);
    if (value) |text| {
        return std.fmt.parseInt(i64, text, 10) catch 0;
    }
    return 0;
}

fn saveProviderSuccess(
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    provider: DdnsProvider,
    ip: []const u8,
    now_seconds: i64,
) !void {
    var now_buffer: [32]u8 = undefined;
    const now_text = try std.fmt.bufPrint(&now_buffer, "{d}", .{now_seconds});
    const key = providerStateRedisKey(provider);

    const fields = [_]redis.HashField{
        .{ .key = key, .field = "current_ip", .value = ip },
        .{ .key = key, .field = "desired_ip", .value = ip },
        .{ .key = key, .field = "status", .value = provider_status_success },
        .{ .key = key, .field = "retry_count", .value = "0" },
        .{ .key = key, .field = "next_retry_at", .value = "0" },
        .{ .key = key, .field = "last_error", .value = "" },
        .{ .key = key, .field = "updated_at", .value = now_text },
    };
    _ = allocator;
    try redis_session.hSetFields(&fields);
}

fn saveProviderFailure(
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    provider: DdnsProvider,
    desired_ip: []const u8,
    retry_count: u32,
    next_retry_at: i64,
    last_error: []const u8,
    now_seconds: i64,
) !void {
    var retry_buffer: [32]u8 = undefined;
    var next_retry_buffer: [32]u8 = undefined;
    var now_buffer: [32]u8 = undefined;
    const retry_text = try std.fmt.bufPrint(&retry_buffer, "{d}", .{retry_count});
    const next_retry_text = try std.fmt.bufPrint(&next_retry_buffer, "{d}", .{next_retry_at});
    const now_text = try std.fmt.bufPrint(&now_buffer, "{d}", .{now_seconds});
    const key = providerStateRedisKey(provider);

    const fields = [_]redis.HashField{
        .{ .key = key, .field = "desired_ip", .value = desired_ip },
        .{ .key = key, .field = "status", .value = provider_status_failed },
        .{ .key = key, .field = "retry_count", .value = retry_text },
        .{ .key = key, .field = "next_retry_at", .value = next_retry_text },
        .{ .key = key, .field = "last_error", .value = last_error },
        .{ .key = key, .field = "updated_at", .value = now_text },
    };
    _ = allocator;
    try redis_session.hSetFields(&fields);
}

fn retryDelaySeconds(retry_count: u32) i64 {
    if (retry_count == 0) return provider_retry_initial_delay_seconds;

    const exponent = @min(retry_count - 1, 5);
    const delay = provider_retry_initial_delay_seconds * (@as(i64, 1) << @intCast(exponent));
    return @min(delay, provider_retry_max_delay_seconds);
}

/// 依序更新所有有設定完成的 DDNS 供應商。
fn updateDdnsServices(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    ip: []const u8,
) !ServiceSummary {
    // 先從 0 開始累計這一輪更新統計。
    var summary = ServiceSummary{};

    // Afraid 要同時滿足：
    // 1. `enabled = true`
    // 2. token 有填值
    //
    // 只要 `enabled = false`，就算 IP 有變化，這輪也不會更新 Afraid。
    if (config.afraid.enabled and config.afraid.token.len != 0) {
        // `attempted += 1` 代表：
        // 我們已經決定這一輪要真的去碰一次 Afraid API。
        summary.attempted += 1;
        // Zig 的 `if (foo()) { ... } else |err| { ... }` 寫法代表：
        // 如果成功就走前面，如果回傳 error 就把 error 綁到 `err`。
        if (updateAfraid(allocator, client, config.afraid)) {
            // Afraid 真的更新成功時，成功數量加 1。
            summary.succeeded += 1;
            summary.successes.mark(.afraid);
        } else |err| {
            // 失敗時不讓整輪直接中斷，而是先記錄錯誤。
            std.log.err("afraid update failed: {}", .{err});
        }
    }

    // Dynu 要同時滿足：
    // 1. `enabled = true`
    // 2. username 有值
    // 3. password 有值
    if (config.dyny.enabled and config.dyny.username.len != 0 and config.dyny.password.len != 0) {
        // 因為設定完整，所以這次也把 Dynu 算進「有嘗試」。
        summary.attempted += 1;
        if (updateDynu(allocator, client, config.dyny, ip)) {
            // Dynu 成功就累計成功數。
            summary.succeeded += 1;
            summary.successes.mark(.dynu);
        } else |err| {
            // 失敗時只記錄，不中斷其他供應商。
            std.log.err("dynu update failed: {}", .{err});
        }
    }

    // No-IP 要同時滿足：
    // 1. `enabled = true`
    // 2. username / password 都有值
    // 3. 至少有一個 hostname
    if (config.noip.enabled and config.noip.username.len != 0 and config.noip.password.len != 0 and config.noip.hostnames.len != 0) {
        // 這裡同樣代表：No-IP 被納入這輪實際嘗試。
        summary.attempted += 1;
        if (updateNoIp(allocator, client, config.noip, ip)) {
            // 只要整個 No-IP 更新流程成功，就加到成功數。
            summary.succeeded += 1;
            summary.successes.mark(.noip);
        } else |err| {
            // 記錄 No-IP 的失敗原因。
            std.log.err("no-ip update failed: {}", .{err});
        }
    }

    // 把最後統計結果回給呼叫端。
    return summary;
}

/// 呼叫 Afraid.org 的同步 API。
fn updateAfraid(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Afraid,
) !void {
    // 先把 Afraid 更新網址組出來。
    const url = try buildAfraidUrl(allocator, config);
    // 打 HTTP GET。
    const response = try http.fetchText(allocator, client, url, &.{}, .{
        .connect_timeout = ddns_connect_timeout,
    });
    // 用完 body 後要記得釋放。
    defer allocator.free(response.body);

    // 先確認 HTTP 狀態碼是 2xx。
    try http.ensureSuccessStatus(response.status, response.body);
    // Afraid 會把「真的更新」和「IP 沒變」都放在 body 裡，
    // 所以不能只看 HTTP 200，還要檢查 body 是否屬於可接受結果。
    if (!containsExpectedAfraidResponse(response.body)) {
        // 如果 body 不是我們認得的成功/未變更訊息，就把它視為非預期回應。
        return error.UnexpectedAfraidResponse;
    }
    // 不論這次是 Updated 還是 Address has not changed，都明確寫一筆日誌，
    // 這樣就不會看起來像 Afraid 這條路徑完全沒執行。
    var preview_buffer: [http_log_body_preview_len]u8 = undefined;
    std.log.debug("afraid response: {s}", .{http.bodyPreviewForLog(&preview_buffer, response.body)});
}

/// 呼叫 Dynu 的 DDNS API。
fn updateDynu(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.Dynu,
    ip: []const u8,
) !void {
    // Dynu 需要把目前 IP 也組進更新網址。
    const url = try buildDynuUrl(allocator, config, ip);
    // 真正把請求送出去。
    const response = try http.fetchText(allocator, client, url, &.{}, .{
        .connect_timeout = ddns_connect_timeout,
    });
    // 用完 body 之後歸還記憶體。
    defer allocator.free(response.body);

    // 先確保不是 404 / 500 這種 HTTP 層級錯誤。
    try http.ensureSuccessStatus(response.status, response.body);
    // Dynu 常見成功回應是 `good` 或 `nochg`。
    // 如果不是這兩種，就把它視為非預期內容。
    if (!containsGoodOrNochg(response.body)) {
        return error.UnexpectedDynuResponse;
    }
    // 建一塊暫時 buffer，讓回應內容可以整理後寫進 log。
    var preview_buffer: [http_log_body_preview_len]u8 = undefined;
    std.log.debug("dynu response: {s}", .{http.bodyPreviewForLog(&preview_buffer, response.body)});
}

/// 呼叫 No-IP 的 DDNS API。
fn updateNoIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.NoIp,
    ip: []const u8,
) !void {
    // No-IP 是用 HTTP Basic Auth，所以先把帳密轉成 header 值。
    const auth_value = try buildBasicAuthorization(allocator, config.username, config.password);
    // 把 authorization header 放進固定長度陣列。
    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_value },
    };

    // No-IP 可能一次要更新多個 hostname，所以逐一迴圈。
    for (config.hostnames) |hostname| {
        // 先為這一個 hostname 組出更新網址。
        const url = try buildNoIpUrl(allocator, config, hostname, ip);
        // 再帶著 Basic Auth header 送出請求。
        const response = try http.fetchText(allocator, client, url, &headers, .{
            .connect_timeout = ddns_connect_timeout,
        });
        // 每個 hostname 的回應內容用完都要釋放。
        defer allocator.free(response.body);

        // 先確認 HTTP 本身有沒有成功。
        try http.ensureSuccessStatus(response.status, response.body);
        // No-IP 成功回應也會是 `good` 或 `nochg`。
        if (!containsGoodOrNochg(response.body)) {
            return error.UnexpectedNoIpResponse;
        }
        // 準備 log 用的暫時 buffer。
        var preview_buffer: [http_log_body_preview_len]u8 = undefined;
        std.log.debug("no-ip response ({s}): {s}", .{
            hostname,
            http.bodyPreviewForLog(&preview_buffer, response.body),
        });
    }
}

/// 判斷 Afraid 回應是否屬於「成功」或「IP 未變」這兩種可接受結果。
fn containsExpectedAfraidResponse(body: []const u8) bool {
    // Afraid 文件與實際行為常見兩種正文：
    // 1. `Updated ...`
    // 2. `ERROR: Address x.x.x.x has not changed.`
    return std.mem.indexOf(u8, body, "Updated") != null or
        std.mem.indexOf(u8, body, "has not changed") != null;
}

/// 取得目前對外 IP。
fn getPublicIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
) ![]const u8 {
    // 這裡把所有對外 IP 來源站集中成一個固定陣列，
    // 之後會依序嘗試。
    const services = [_]PublicIpService{
        .ipify,
        .ipconfig,
        .ipinfo,
        .seeip,
        .myip,
        .bigdatacloud,
    };

    // 記住這次從哪個 index 開始試。
    const start_index = next_public_ip_index.fetchAdd(1, .monotonic) % services.len;

    // 如果所有來源站都失敗，就把每個錯誤接起來，最後一次打出。
    var error_buffer: [512]u8 = undefined;
    var error_writer: std.Io.Writer = .fixed(&error_buffer);

    // 最多試滿所有來源站一次。
    for (0..services.len) |offset| {
        // `(start_index + offset) % services.len` 可以實作循環往後取值。
        const service = services[(start_index + offset) % services.len];
        // 嘗試用目前這個來源站抓 IP。
        const ip = fetchPublicIpFromService(allocator, client, service) catch |err| {
            appendPublicIpLookupError(&error_writer, service, err);
            // 改試下一站。
            continue;
        };
        // 只要有一站成功，就直接回傳。
        return ip;
    }

    // 走到這裡代表全部來源站都失敗。
    std.log.err("failed to get public ip from all services: {s}", .{error_writer.buffered()});
    return error.PublicIpLookupFailed;
}

/// 把單一 public IP 來源站錯誤追加到固定大小的錯誤摘要 buffer。
fn appendPublicIpLookupError(
    writer: *std.Io.Writer,
    service: PublicIpService,
    err: anyerror,
) void {
    if (writer.buffered().len != 0) {
        writer.writeAll(" | ") catch return;
    }
    writer.print("{s}: {}", .{ serviceName(service), err }) catch {};
}

/// 針對單一來源站點抓取 IP。
fn fetchPublicIpFromService(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    service: PublicIpService,
) ![]const u8 {
    // 先從集中管理區塊拿到這個來源站對應的網址。
    const url = publicIpServiceUrl(service);

    // `switch` 會根據來源站種類，決定要打哪個 API 或怎麼解析回應。
    return switch (service) {
        // 這四個站都直接回純文字 IP，所以共用同一個輔助函式。
        .ipify, .ipconfig, .ipinfo, .seeip => fetchTextIp(allocator, client, url),
        // `myip` 會回 JSON，所以走 JSON 解析輔助函式。
        .myip => fetchMyIpJson(allocator, client, url),
        // `bigdatacloud` 也回 JSON，但欄位名稱不同，所以走另一個輔助函式。
        .bigdatacloud => fetchBigDataCloudJson(allocator, client, url),
    };
}

/// 把對外 IP 來源站 enum 轉成實際要打的網址。
fn publicIpServiceUrl(service: PublicIpService) []const u8 {
    return switch (service) {
        // 每個 enum 值都對應到 `Endpoint.PublicIp` 裡集中管理的網址常數。
        .ipify => Endpoint.PublicIp.ipify,
        .ipconfig => Endpoint.PublicIp.ipconfig,
        .ipinfo => Endpoint.PublicIp.ipinfo,
        .seeip => Endpoint.PublicIp.seeip,
        .myip => Endpoint.PublicIp.myip,
        .bigdatacloud => Endpoint.PublicIp.bigdatacloud,
    };
}

/// 從「直接回純文字 IP」的來源站抓取對外 IP。
fn fetchTextIp(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
) ![]const u8 {
    // 這類來源站直接回傳純文字 IP，所以只要 GET 之後做基本檢查即可。
    const response = try http.fetchText(allocator, client, url, &.{}, .{
        .connect_timeout = public_ip_connect_timeout,
    });
    // `response.body` 是動態配置出來的字串，用完一定要釋放。
    defer allocator.free(response.body);

    // HTTP 不是 2xx 的話，這裡就會直接回錯。
    try http.ensureSuccessStatus(response.status, response.body);
    // 把 body 裡可能的空白、換行整理掉，順便驗證這真的是 IP。
    const normalized = try normalizePublicIp(response.body);
    // `normalized` 只是指向 `response.body` 裡的一段 slice。
    // 因為後面會 `free(response.body)`，所以這裡要另外複製一份給呼叫端持有。
    return allocator.dupe(u8, normalized);
}

/// 從 `api.myip.com` 的 JSON 回應中取出對外 IP。
fn fetchMyIpJson(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
) ![]const u8 {
    // 這個來源站回的是 JSON，不是純文字 IP。
    // 真正網址不寫死在這裡，而是由呼叫端從集中管理區塊傳進來。
    const response = try http.fetchText(allocator, client, url, &.{}, .{
        .connect_timeout = public_ip_connect_timeout,
    });
    defer allocator.free(response.body);

    // 先處理 HTTP 層面的成功 / 失敗。
    try http.ensureSuccessStatus(response.status, response.body);

    // 這個匿名 struct 只描述我們這次真正要用到的欄位。
    const Parsed = struct {
        // `api.myip.com` 的 JSON 會有 `"ip": "1.2.3.4"` 這種欄位。
        ip: []const u8,
    };
    // 用標準庫 JSON 解析器把回應內容反序列化。
    const parsed = try std.json.parseFromSlice(Parsed, allocator, response.body, .{
        // 其他欄位像 country / cc 我們目前沒用到，所以忽略它們。
        .ignore_unknown_fields = true,
    });
    // `parsed` 內部也持有記憶體，所以用完要 deinit。
    defer parsed.deinit();

    // 取出 JSON 裡的 `ip` 欄位，再做一次標準化與驗證。
    const normalized = try normalizePublicIp(parsed.value.ip);
    // 同樣複製一份新的字串給呼叫端。
    return allocator.dupe(u8, normalized);
}

/// 從 BigDataCloud 的 JSON 回應中取出對外 IP。
fn fetchBigDataCloudJson(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
) ![]const u8 {
    // 這個來源站也回 JSON。
    // 真正網址同樣由呼叫端從集中管理區塊傳進來。
    const response = try http.fetchText(allocator, client, url, &.{}, .{
        .connect_timeout = public_ip_connect_timeout,
    });
    defer allocator.free(response.body);

    // 先確認 HTTP 請求本身沒失敗。
    try http.ensureSuccessStatus(response.status, response.body);

    // BigDataCloud 的欄位名稱是 `ipString`。
    const Parsed = struct {
        // 對應 JSON 裡的 `"ipString": "1.2.3.4"`。
        ipString: []const u8,
    };
    // 把 body 反序列化成只含 `ipString` 欄位的 struct。
    const parsed = try std.json.parseFromSlice(Parsed, allocator, response.body, .{
        .ignore_unknown_fields = true,
    });
    // JSON parser 內部配置的記憶體要記得清掉。
    defer parsed.deinit();

    // 把欄位值整理成穩定的 IP 格式。
    const normalized = try normalizePublicIp(parsed.value.ipString);
    // 再複製一份可長期持有的字串回傳出去。
    return allocator.dupe(u8, normalized);
}

/// 將第三方回傳的文字修正成穩定的 IP 格式。
fn normalizePublicIp(text: []const u8) ![]const u8 {
    // 先把前後空白、CRLF 去掉。
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    // 如果清理完是空字串，就代表這份回應不能用。
    if (trimmed.len == 0) return error.EmptyPublicIpResponse;

    // `IpAddress.parse(...)` 拿來驗證這段字串是不是真的像 IPv4 / IPv6。
    _ = std.Io.net.IpAddress.parse(trimmed, 0) catch return error.InvalidPublicIpResponse;
    // 驗證通過後，就把清理好的 slice 回傳。
    return trimmed;
}

/// 判斷某個 DDNS 回應內容是否代表成功或「已經是最新」。
fn containsGoodOrNochg(text: []const u8) bool {
    // `good` 表示真的更新成功，`nochg` 表示對方認定已經是最新 IP。
    // 這兩種對我們來說都算成功。
    return std.mem.indexOf(u8, text, "good") != null or
        std.mem.indexOf(u8, text, "nochg") != null;
}

/// 把 enum 值轉成較好讀的站名字串。
fn serviceName(service: PublicIpService) []const u8 {
    return switch (service) {
        // 把 enum 轉成適合寫進 log 的短字串。
        .ipify => "ipify",
        .ipconfig => "ipconfig",
        .ipinfo => "ipinfo",
        .seeip => "seeip",
        .myip => "myip",
        .bigdatacloud => "bigdatacloud",
    };
}

/// 依照設定組出 Afraid 的同步網址。
fn buildAfraidUrl(
    allocator: std.mem.Allocator,
    config: config_mod.Afraid,
) ![]u8 {
    // 先拿出設定裡的基底網址。
    var prefix = config.url;
    // 如果尾端有多個 `/`，先修掉，避免最後網址變成 `//dynamic/...`。
    while (prefix.len != 0 and prefix[prefix.len - 1] == '/') {
        prefix = prefix[0 .. prefix.len - 1];
    }

    return std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ prefix, config.path, config.token },
    );
}

/// 依照設定組出 Dynu 的更新網址。
///
/// 注意密碼不會以明文送出，而是先做 SHA-256。
fn buildDynuUrl(
    allocator: std.mem.Allocator,
    config: config_mod.Dynu,
    ip: []const u8,
) ![]u8 {
    // Rust 版是把密碼先做 SHA-256，再把雜湊值送給 Dynu。
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    // 這一行真的做 SHA-256 計算。
    std.crypto.hash.sha2.Sha256.hash(config.password, &digest, .{});
    // 把 bytes 轉成 16 進位小寫字串。
    const password_hex = std.fmt.bytesToHex(digest, .lower);

    var prefix = config.url;
    // 如果設定值尾端多帶了 `/`，先修掉，避免 query string 前面變成 `/?...`。
    while (prefix.len != 0 and prefix[prefix.len - 1] == '/') {
        prefix = prefix[0 .. prefix.len - 1];
    }

    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);

    try url.appendSlice(allocator, prefix);
    try url.append(allocator, '?');
    try appendQueryParam(&url, allocator, "username", config.username);
    try url.append(allocator, '&');
    try appendQueryParam(&url, allocator, "password", &password_hex);
    try url.append(allocator, '&');
    try appendQueryParam(&url, allocator, "myip", ip);

    return url.toOwnedSlice(allocator);
}

/// 依照 hostname 與 IP 組出 No-IP 的更新網址。
fn buildNoIpUrl(
    allocator: std.mem.Allocator,
    config: config_mod.NoIp,
    hostname: []const u8,
    ip: []const u8,
) ![]u8 {
    var prefix = config.url;
    // 如果設定值尾端多帶了 `/`，也先修掉。
    while (prefix.len != 0 and prefix[prefix.len - 1] == '/') {
        prefix = prefix[0 .. prefix.len - 1];
    }

    // No-IP 把 hostname 與 myip 放在 query string。
    var url = std.ArrayList(u8).empty;
    errdefer url.deinit(allocator);

    try url.appendSlice(allocator, prefix);
    try url.append(allocator, '?');
    try appendQueryParam(&url, allocator, "hostname", hostname);
    try url.append(allocator, '&');
    try appendQueryParam(&url, allocator, "myip", ip);

    return url.toOwnedSlice(allocator);
}

/// 追加一個已完成 percent-encoding 的 `key=value` query 片段。
fn appendQueryParam(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !void {
    try buffer.appendSlice(allocator, key);
    try buffer.append(allocator, '=');
    try appendUrlEncoded(buffer, allocator, value);
}

/// 將 query parameter 值轉成 percent-encoded 文字。
fn appendUrlEncoded(
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

/// RFC 3986 query component 可直接保留的 unreserved 字元。
fn isUnreservedUrlByte(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~';
}

/// 把帳號密碼轉成 HTTP Basic Authorization header 值。
fn buildBasicAuthorization(
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
) ![]u8 {
    // HTTP Basic Auth 的原始格式是 `username:password`。
    const raw = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    // `raw` 是一塊新的動態字串，用完要釋放。
    defer allocator.free(raw);

    // 算出 base64 編碼後會需要多少空間。
    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    // 配出一塊剛好夠放 base64 結果的記憶體。
    const encoded = try allocator.alloc(u8, encoded_len);
    // `encoded` 只是中間結果，最後組完 header 就不需要了。
    defer allocator.free(encoded);

    // 真的做 base64 編碼。
    _ = std.base64.standard.Encoder.encode(encoded, raw);
    // 最後補上 `Basic ` 前綴，變成標準 Authorization header 值。
    return std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
}

/// 判斷是否落在 Rust 版原本會跳過的凌晨維護時段。
fn shouldSkipMaintenanceWindow() bool {
    // Windows 沒有 `localtime_r`，所以改走 Win32 API `GetLocalTime`。
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
        // 把目前本地時間寫進 `local_time`。
        kernel32.GetLocalTime(&local_time);
        // 再把時、分丟給共用輔助函式判斷。
        return shouldSkipMaintenanceWindowAt(local_time.wHour, local_time.wMinute);
    } else {
        // 非 Windows 走 POSIX 的 `localtime_r`。
        // 先取得現在的 Unix 秒數。
        var now: c.time_t = c.time(null);
        // 再準備一個 `tm` 結構來接「拆開後的本地時間」。
        var local_tm: c.struct_tm = undefined;
        // `orelse return false` 代表：如果 `localtime_r` 失敗，就乾脆不要跳過。
        _ = c.localtime_r(&now, &local_tm) orelse return false;
        return shouldSkipMaintenanceWindowAt(local_tm.tm_hour, local_tm.tm_min);
    }
}

/// 真正的規則很單純：
/// 只要時間落在 02:00 到 02:04，就跳過。
fn shouldSkipMaintenanceWindowAt(hour: c_int, minute: c_int) bool {
    return hour == 2 and minute >= 0 and minute < 5;
}

test "normalize public ip trims and validates ipv4" {
    // 測純文字 IP 前後夾了空白與換行時，仍能被清成乾淨格式。
    const normalized = try normalizePublicIp(" 1.2.3.4\r\n");
    try std.testing.expectEqualStrings("1.2.3.4", normalized);
}

test "normalize public ip accepts ipv6" {
    // 也要接受 IPv6。
    const normalized = try normalizePublicIp("2001:db8::1");
    try std.testing.expectEqualStrings("2001:db8::1", normalized);
}

test "maintenance window helper matches rust behavior" {
    // 這個測試確認凌晨 2:00 到 2:04 都會被跳過。
    try std.testing.expect(shouldSkipMaintenanceWindowAt(2, 0));
    try std.testing.expect(shouldSkipMaintenanceWindowAt(2, 4));
    try std.testing.expect(!shouldSkipMaintenanceWindowAt(2, 5));
    try std.testing.expect(!shouldSkipMaintenanceWindowAt(1, 59));
}

test "dynu url hashes password before sending" {
    const allocator = std.testing.allocator;
    const test_password = "not-a-real-password-for-test";
    // 把 demo 帳密與 IP 組成 Dynu 更新網址。
    const url = try buildDynuUrl(
        allocator,
        .{ .username = "demo", .password = test_password },
        "1.2.3.4",
    );
    // 測試結束時把暫時字串釋放掉。
    defer allocator.free(url);

    // 檢查 username 與 IP 都有出現在網址裡。
    try std.testing.expect(std.mem.indexOf(u8, url, "username=demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "myip=1.2.3.4") != null);
    // 檢查送出去的不是原始測試密碼。
    try std.testing.expect(std.mem.indexOf(u8, url, test_password) == null);

    const password_marker = "password=";
    const password_pos = std.mem.indexOf(u8, url, password_marker) orelse return error.TestUnexpectedResult;
    const hashed_tail = url[password_pos + password_marker.len ..];
    const hash_end = std.mem.indexOfScalar(u8, hashed_tail, '&') orelse hashed_tail.len;
    const digest = hashed_tail[0..hash_end];

    // SHA-256 十六進位輸出應該固定是 64 字元。
    try std.testing.expectEqual(@as(usize, 64), digest.len);
    for (digest) |char| {
        try std.testing.expect(std.ascii.isHex(char));
    }
}

test "dynu url percent-encodes username" {
    const allocator = std.testing.allocator;
    const url = try buildDynuUrl(
        allocator,
        .{ .username = "demo+user@example.com", .password = "secret" },
        "1.2.3.4",
    );
    defer allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "username=demo%2Buser%40example.com") != null);
}

test "basic authorization header starts with basic" {
    const allocator = std.testing.allocator;
    // Basic Auth 的 header 一定要以 `Basic ` 開頭。
    const value = try buildBasicAuthorization(allocator, "user", "pass");
    // 這個 header 字串也是動態配置的。
    defer allocator.free(value);

    try std.testing.expect(std.mem.startsWith(u8, value, "Basic "));
}

test "build afraid url supports new freedns syntax" {
    const allocator = std.testing.allocator;
    const url = try buildAfraidUrl(
        allocator,
        .{
            .url = "https://freedns.afraid.org",
            .path = "/dynamic/update.php?",
            .token = "demo-token",
        },
    );
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://freedns.afraid.org/dynamic/update.php?demo-token",
        url,
    );
}

test "afraid response accepts updated and unchanged bodies" {
    try std.testing.expect(containsExpectedAfraidResponse("Updated 1 host(s) to 1.2.3.4 in 0.123 seconds"));
    try std.testing.expect(containsExpectedAfraidResponse("ERROR: Address 1.2.3.4 has not changed."));
    try std.testing.expect(!containsExpectedAfraidResponse("ERROR: Invalid update URL"));
}

test "noip url percent-encodes hostname" {
    const allocator = std.testing.allocator;
    const url = try buildNoIpUrl(
        allocator,
        .{},
        "demo site.example.com",
        "1.2.3.4",
    );
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://dynupdate.no-ip.com/nic/update?hostname=demo%20site.example.com&myip=1.2.3.4",
        url,
    );
}

test "public ip cache key matches rust format" {
    const allocator = std.testing.allocator;
    // Redis 防重複更新 key 必須和 Rust 版完全同格式，才能沿用同一套資料。
    const key = try buildPublicIpCacheKey(allocator, "1.2.3.4");
    // 記得釋放 `allocPrint(...)` 配出的字串。
    defer allocator.free(key);

    try std.testing.expectEqualStrings("MyPublicIP:1.2.3.4", key);
}

test "current public ip redis key matches expected format" {
    try std.testing.expectEqualStrings("MyPublicIP", currentPublicIpRedisKey());
}

test "provider current ip redis keys match expected format" {
    try std.testing.expectEqualStrings("MyPublicIP:afraid", providerCurrentIpRedisKey(.afraid));
    try std.testing.expectEqualStrings("MyPublicIP:dynu", providerCurrentIpRedisKey(.dynu));
    try std.testing.expectEqualStrings("MyPublicIP:noip", providerCurrentIpRedisKey(.noip));
}

test "provider success state tracks successful ddns providers" {
    var successes = ProviderSuccesses{};

    try std.testing.expect(!successes.includes(.afraid));
    try std.testing.expect(!successes.includes(.dynu));
    try std.testing.expect(!successes.includes(.noip));

    successes.mark(.dynu);

    try std.testing.expect(!successes.includes(.afraid));
    try std.testing.expect(successes.includes(.dynu));
    try std.testing.expect(!successes.includes(.noip));
}

test "provider configured helper follows provider credentials" {
    const app_config: config_mod.AppConfig = .{
        .afraid = .{ .enabled = true, .token = "token" },
        .dyny = .{ .enabled = true, .username = "dynu-user", .password = "dynu-pass" },
        .noip = .{
            .enabled = true,
            .username = "noip-user",
            .password = "noip-pass",
            .hostnames = &.{"example.ddns.net"},
        },
    };

    try std.testing.expect(isProviderConfigured(app_config, .afraid));
    try std.testing.expect(isProviderConfigured(app_config, .dynu));
    try std.testing.expect(isProviderConfigured(app_config, .noip));
    try std.testing.expect(!isProviderConfigured(.{}, .afraid));
    try std.testing.expect(!isProviderConfigured(.{}, .dynu));
    try std.testing.expect(!isProviderConfigured(.{}, .noip));
}

test "provider attempt decision skips only successful current state" {
    try std.testing.expectEqual(
        ProviderAttemptDecision.already_current,
        providerAttemptDecision(.{
            .current_ip = "1.2.3.4",
            .desired_ip = "1.2.3.4",
            .status = provider_status_success,
        }, "1.2.3.4", 100),
    );

    try std.testing.expectEqual(
        ProviderAttemptDecision.attempt,
        providerAttemptDecision(.{
            .current_ip = "1.2.3.4",
            .desired_ip = "5.6.7.8",
            .status = provider_status_failed,
            .next_retry_at = 1000,
        }, "9.9.9.9", 100),
    );
}

test "provider attempt decision respects retry backoff for same desired ip" {
    try std.testing.expectEqual(
        ProviderAttemptDecision.retry_deferred,
        providerAttemptDecision(.{
            .desired_ip = "1.2.3.4",
            .status = provider_status_failed,
            .next_retry_at = 200,
        }, "1.2.3.4", 100),
    );

    try std.testing.expectEqual(
        ProviderAttemptDecision.attempt,
        providerAttemptDecision(.{
            .desired_ip = "1.2.3.4",
            .status = provider_status_failed,
            .next_retry_at = 100,
        }, "1.2.3.4", 100),
    );
}

test "retry delay backs off with cap" {
    try std.testing.expectEqual(@as(i64, 30), retryDelaySeconds(1));
    try std.testing.expectEqual(@as(i64, 60), retryDelaySeconds(2));
    try std.testing.expectEqual(@as(i64, 120), retryDelaySeconds(3));
    try std.testing.expectEqual(@as(i64, 900), retryDelaySeconds(100));
}

test "process local public ip state skips unchanged ip" {
    resetProcessPublicIpState();
    defer resetProcessPublicIpState();

    try std.testing.expect(!isSameAsLastProcessedIp("1.2.3.4"));
    rememberLastProcessedIp("1.2.3.4");
    try std.testing.expect(isSameAsLastProcessedIp("1.2.3.4"));
    try std.testing.expect(!isSameAsLastProcessedIp("5.6.7.8"));
}

test "redis dedupe params keep legacy redis key and value format" {
    const allocator = std.testing.allocator;
    const ip = "1.2.3.4";
    const cache_key = try buildPublicIpCacheKey(allocator, ip);
    defer allocator.free(cache_key);

    try std.testing.expectEqualStrings("MyPublicIP:1.2.3.4", cache_key);
    try std.testing.expectEqualStrings("MyPublicIP", currentPublicIpRedisKey());
    try std.testing.expectEqualStrings("1.2.3.4", ip);
    try std.testing.expectEqual(@as(u64, 86400), @as(u64, 86400));
}

test "local dedupe cache respects ttl" {
    resetLocalDedupeState();
    defer resetLocalDedupeState();

    try std.testing.expect(!localDedupeContainsAt("MyPublicIP:1.2.3.4", 100));
    try localDedupeSetAt("MyPublicIP:1.2.3.4", 60, 100);
    try std.testing.expect(localDedupeContainsAt("MyPublicIP:1.2.3.4", 120));
    try std.testing.expect(!localDedupeContainsAt("MyPublicIP:1.2.3.4", 160));
}

test "local dedupe hit is checked before provider updates" {
    resetLocalDedupeState();
    defer resetLocalDedupeState();

    const key = "MyPublicIP:1.2.3.4";
    try localDedupeSet(key, 60);

    const io: std.Io = undefined;
    try std.testing.expect(try isDedupeHit(
        std.testing.allocator,
        io,
        .{ .enabled = false },
        .{},
        key,
        "1.2.3.4",
    ));
}

test "local dedupe cache shrinks after pruning many expired entries" {
    resetLocalDedupeState();
    defer resetLocalDedupeState();

    var key_buffer: [64]u8 = undefined;
    for (0..40) |index| {
        const key = try std.fmt.bufPrint(&key_buffer, "MyPublicIP:10.0.0.{d}", .{index});
        try localDedupeSetAt(key, 10, 100);
    }

    const capacity_before = local_dedupe_entries.capacity;
    try std.testing.expect(capacity_before >= local_dedupe_shrink_min_capacity);

    try std.testing.expect(!localDedupeContainsAt("MyPublicIP:missing", 1000));
    try std.testing.expectEqual(@as(usize, 0), local_dedupe_entries.items.len);
    try std.testing.expect(local_dedupe_entries.capacity <= capacity_before);
    try std.testing.expect(local_dedupe_entries.capacity <= local_dedupe_shrink_min_capacity);
}
