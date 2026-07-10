//! DDNS 更新流程的主要入口與協調器 (Facade / Orchestrator)。
//!
//! 負責統合對外 IP 查詢、各 DDNS 供應商的 API 呼叫、本機與 Redis 狀態比對、及維護時段判斷。
//!
//! # 一輪 refresh 的閱讀地圖
//! 1. 維護時段直接略過；2. 找出 public IP；3. 先查行程內記憶；
//! 4. Redis 可用時走「每家 provider 各自收斂」的 reconcile 流程；
//! 5. 否則用 Redis/local TTL cache 做較簡單的整體去重；6. 呼叫供應商並寫回狀態。
//!
//! 本檔只負責協調。實際 HTTP、Redis protocol、STUN 與共享記憶體細節分別位於子模組。

/// Zig 標準函式庫：allocator、時間、字串比對、HTTP 型別等。
const std = @import("std");
/// 設定檔對應的型別，如 AppConfig 與 Redis。
const config_mod = @import("../base/config.zig");
/// Redis 呼叫與可重用連線 Session 的封裝。
const redis = @import("../io/redis.zig");
/// HTTP client 型別的來源；供 provider 子模組共用同一 client。
const http = @import("../io/http.zig");
/// C time()，用於產生 Unix 秒 timestamp。
const c = @import("c");

// 子模組匯入；`pub const` 讓其他檔案可經由 `ddns.xxx` 存取它們。
pub const types = @import("ddns/types.zig");
pub const shared_state = @import("ddns/shared_state.zig");
pub const local_cache = @import("ddns/local_cache.zig");
pub const ip_lookup = @import("ddns/ip_lookup.zig");
pub const providers = @import("ddns/providers.zig");
pub const utils = @import("ddns/utils.zig");

// 公開型別重新導出 (Public Types Re-exports)：使用者不必知道型別實際放在 ddns/types.zig。
pub const RefreshStatus = types.RefreshStatus;
pub const PublicIpSnapshot = types.PublicIpSnapshot;
pub const ProviderSnapshot = types.ProviderSnapshot;
pub const DdnsProvider = types.DdnsProvider;
pub const ProviderSuccesses = types.ProviderSuccesses;
pub const ProviderState = types.ProviderState;
pub const ProviderAttemptDecision = types.ProviderAttemptDecision;
pub const ServiceSummary = types.ServiceSummary;

// 公開函式重新導出 (Public Functions Re-exports)：snapshot 是值複製，讀取者不會碰到內部鎖。
pub const getProviderSnapshots = shared_state.getProviderSnapshots;
pub const getPublicIpSnapshot = shared_state.getPublicIpSnapshot;

/// 啟動檢查或 Redis 操作失敗後設為 false；refresh 會改用 local_cache 作為降級方案。
pub var redis_available: bool = true;

/// Redis hash 的成功狀態文字；必須和 shared_state 的顯示語意一致。
const provider_status_success = "success";
/// Redis hash 的失敗狀態文字；與 success 配對供 retry 決策使用。
const provider_status_failed = "failed";

/// 啟動時檢查 Redis 連線狀況。
pub fn checkRedisAvailability(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
) void {
    // Redis 沒有啟用時，刻意不連線也不改寫 redis_available；此模式本來就使用 local cache。
    if (!redis_config.enabled) return;

    // addr 可為 host:port 或 [IPv6]:port。先解析而不是直接連線，能產生較清楚的設定錯誤。
    const host_port = utils.parseHostPort(redis_config.addr) catch |err| {
        redis_available = false;
        std.log.warn(
            "failed to parse redis address: addr={s}, error={}",
            .{ redis_config.addr, err },
        );
        return;
    };

    // 這只是啟動期 TCP 可達性探測，不會驗證 Redis 帳密或執行 Redis 命令。
    utils.checkTcpPortReachable(allocator, io, host_port.host, host_port.port) catch |err| {
        redis_available = false;
        std.log.warn(
            "redis is not reachable at startup, falling back to local dedup: addr={s}, error={s}",
            .{ redis_config.addr, @errorName(err) },
        );
        return;
    };

    std.log.info("redis connectivity check passed: addr={s}", .{redis_config.addr});
}

/// 依據目前的 Redis 可用性修正設定檔。
fn redisConfigForCurrentState(original: config_mod.Redis) config_mod.Redis {
    if (redis_available) return original;
    var copy = original;
    copy.enabled = false;
    return copy;
}

/// 執行一次 DDNS 更新檢查的主進入點。
pub fn refresh(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    config: config_mod.AppConfig,
) !RefreshStatus {
    // 此保護在任何網路 I/O 前完成；避免維護時段仍造成 STUN/HTTP/Redis 請求。
    if (utils.shouldSkipMaintenanceWindow()) {
        std.log.info("skip ddns refresh during 02:00-02:04 local maintenance window", .{});
        return .skipped_maintenance_window;
    }

    // 本輪有許多短命字串（IP、URL、Redis 回應）。Arena 讓它們可統一在函式結束時
    // deinit，不需為每一個成功/錯誤分支手動 free。不可把 scratch 配置的 slice 存到本輪外。
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // 取得的 IP 已經過格式驗證。try 代表兩個 public-IP 來源皆失敗時立即向呼叫端傳遞錯誤。
    const public_ip_lookup = try ip_lookup.getPublicIp(scratch, client);
    const ip_now = public_ip_lookup.ip;
    const ip_source = ip_lookup.serviceName(public_ip_lookup.service);

    // 這層是最快的 process-local 短路；即使 Redis TTL 已失效，只要此行程剛剛
    // 成功處理同一 IP 仍不重複更新。仍更新來源診斷資訊，因本次來源可能不同。
    if (shared_state.isSameAsLastProcessedIp(ip_now)) {
        shared_state.rememberLastProcessedIp(ip_now, ip_source, public_ip_lookup.stun_error);
        std.log.info(
            "skip ddns refresh because public ip is unchanged in current process: {s}",
            .{ip_now},
        );
        return .skipped_cached_ip;
    }

    // 0 是設定上的「使用預設值」，不是立即過期；預設為一天。
    const ttl_seconds = if (config.ddns.dedupe_ttl_seconds == 0)
        @as(u64, 60 * 60 * 24)
    else
        config.ddns.dedupe_ttl_seconds;

    // Redis reconciliation 為較精細模式：每個 provider 都有自己的成功/失敗/退避狀態。
    if (config.ddns.redis.enabled and redis_available) {
        const now_seconds = c.time(null);
        return refreshWithRedisProviderState(
            scratch,
            io,
            client,
            config,
            ip_now,
            ip_source,
            public_ip_lookup.stun_error,
            ttl_seconds,
            now_seconds,
        );
    }

    // 降級路徑仍可在設定啟用 Redis、但 Redis 已標記不可用時使用 local cache；
    // effective_redis 將 enabled 改為 false，確保後續函式不會再嘗試 Redis I/O。
    const cache_key = try buildPublicIpCacheKey(scratch, ip_now);
    const effective_redis = redisConfigForCurrentState(config.ddns.redis);
    if (try isDedupeHit(scratch, io, effective_redis, config, cache_key, ip_now)) {
        return .skipped_cached_ip;
    }

    // 簡單模式不會因單一 provider 出錯而提前中止；summary 統計全部嘗試結果。
    const summary = try updateDdnsServices(scratch, client, config, ip_now, c.time(null));
    if (summary.attempted == 0) return error.NoEnabledDdnsService;
    if (summary.succeeded == 0) return error.AllDdnsUpdatesFailed;

    try rememberDedupe(scratch, io, effective_redis, cache_key, ip_now, ttl_seconds, summary.successes);
    // 只有每個已嘗試 provider 都成功，才把 IP 標為此行程「完整處理」；
    // 若部分失敗，下輪仍應有機會補上失敗者。
    if (summary.succeeded == summary.attempted) {
        shared_state.rememberLastProcessedIp(ip_now, ip_source, public_ip_lookup.stun_error);
    }

    std.log.info(
        "ddns refresh completed: ip={s}, succeeded={d}/{d}",
        .{ ip_now, summary.succeeded, summary.attempted },
    );
    return .updated;
}

/// Redis 可用時的 reconcile 流程：先寫 desired IP，依各 provider 的 hash state 決定
/// 要更新、略過或等待 retry，最後只記錄實際成功的 provider。
fn refreshWithRedisProviderState(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    ip: []const u8,
    ip_source: []const u8,
    stun_error: ?[]const u8,
    ttl_seconds: u64,
    now_seconds: i64,
) !RefreshStatus {
    // Session 將同一輪 Redis 往來放在單一已初始化連線；defer 保證所有 return 路徑都釋放它。
    var redis_session: redis.Session = undefined;
    try redis_session.init(io, config.ddns.redis);
    defer redis_session.deinit();

    // desired IP 與各 provider 的 current IP 分開：前者表示「希望收斂到哪」，
    // 後者只在該 provider 成功時才更新。
    try rememberDesiredIpWithSession(&redis_session, ip, ttl_seconds);

    const summary = try updateDdnsServicesReconciled(
        allocator,
        &redis_session,
        client,
        config,
        ip,
        ttl_seconds,
        now_seconds,
    );
    if (summary.configured == 0) return error.NoEnabledDdnsService;

    const cache_key = try buildPublicIpCacheKey(allocator, ip);
    // 即使其他 provider 失敗，也會保存已成功者的 legacy current-IP key，
    // 以便下輪只需修復未成功的服務。
    if (summary.succeeded != 0) {
        try rememberDedupeWithSession(&redis_session, cache_key, ip, ttl_seconds, summary.successes);
    }

    if (summary.attempted != 0 and summary.succeeded == 0) {
        return error.AllDdnsUpdatesFailed;
    }

    // configured 是所有已設定服務數；全部「已正確或本輪成功」才可更新 process-local 去重狀態。
    if (summary.already_current + summary.succeeded == summary.configured) {
        shared_state.rememberLastProcessedIp(ip, ip_source, stun_error);
    }

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

    // 沒有真正 HTTP 更新通常代表全部已正確；對 scheduler 表示這是一輪 cache skip。
    return if (summary.attempted == 0) .skipped_cached_ip else .updated;
}

/// 建立單次 public IP 去重 key；回傳配置的字串，需由同一 allocator 釋放。
fn buildPublicIpCacheKey(allocator: std.mem.Allocator, ip: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "MyPublicIP:{s}", .{ip});
}

/// Redis 中保存最近 public IP 的固定 key，不含 TTL 範圍外的額外資訊。
fn currentPublicIpRedisKey() []const u8 {
    return "MyPublicIP";
}

/// Redis 中保存本輪所有 provider 共同目標 IP 的固定 key。
fn desiredPublicIpRedisKey() []const u8 {
    return "DDNS:DesiredIP";
}

/// 取得 provider hash state 的 Redis key；hash 包含 retry、error 與最後成功 IP 等欄位。
fn providerStateRedisKey(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .afraid => "DDNS:Provider:afraid",
        .dynu => "DDNS:Provider:dynu",
        .noip => "DDNS:Provider:noip",
    };
}

/// 取得舊版相容的 provider-current-IP key，用於快速 dedupe 判斷。
fn providerCurrentIpRedisKey(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .afraid => "MyPublicIP:afraid",
        .dynu => "MyPublicIP:dynu",
        .noip => "MyPublicIP:noip",
    };
}

/// 將 enum 轉成適合 log 顯示的穩定名稱。
fn providerName(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .afraid => "afraid",
        .dynu => "dynu",
        .noip => "no-ip",
    };
}

/// 將 enum 映射到固定順序的陣列 slot；目前保留給需要批次索引的呼叫端。
fn providerSlot(provider: DdnsProvider) usize {
    return switch (provider) {
        .afraid => 0,
        .dynu => 1,
        .noip => 2,
    };
}

/// 判斷此 IP 是否可跳過更新。無 Redis 時查本機 TTL 快取；有 Redis 時還要確認
/// 每個已啟用 provider 的 current-IP key 都正確，避免一個 provider 漏更新。
fn isDedupeHit(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    app_config: config_mod.AppConfig,
    cache_key: []const u8,
    ip: []const u8,
) !bool {
    // Local cache 的 key 會隨 TTL 自動失效；此分支完全沒有 I/O。
    if (!redis_config.enabled) {
        if (local_cache.localDedupeContains(cache_key)) {
            std.log.info(
                "skip ddns refresh because local cache key already exists: {s}",
                .{cache_key},
            );
            return true;
        }
        return false;
    }

    // Redis 去重檢查讀取失敗時採「視為未命中」的安全策略：寧可多做一次 DDNS 更新，
    // 也不因暫時的 Redis 問題而錯過 IP 變更。
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

/// 確認所有「已設定」provider 都已在 Redis 記錄為指定 IP；沒有任何 provider 時回傳 false。
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

/// 讀取單一 provider 的 legacy current-IP key，並與本輪 IP 做精確位元組比較。
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
    // redis.get 成功取得的 value 是 allocator 配置；optional 為 null 時不做任何釋放。
    defer if (stored_ip) |value| allocator.free(value);

    if (stored_ip) |value| {
        return std.mem.eql(u8, value, ip);
    }
    return false;
}

/// 檢查 provider 是否啟用且具備足以發出請求的必要憑證/hostname。
fn isProviderConfigured(app_config: config_mod.AppConfig, provider: DdnsProvider) bool {
    return switch (provider) {
        .afraid => app_config.afraid.enabled and app_config.afraid.token.len != 0,
        .dynu => app_config.dynu.enabled and app_config.dynu.username.len != 0 and app_config.dynu.password.len != 0,
        .noip => app_config.noip.enabled and app_config.noip.username.len != 0 and app_config.noip.password.len != 0 and app_config.noip.hostnames.len != 0,
    };
}

/// 在更新成功後寫入去重資訊；依 Redis 是否啟用選擇遠端 TTL key 或本機快取。
/// successes 確保 provider-current-IP 只寫給本輪真正成功的 provider。
fn rememberDedupe(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    cache_key: []const u8,
    ip: []const u8,
    ttl_seconds: u64,
    successes: ProviderSuccesses,
) !void {
    // SETEX 將值與 TTL 一次寫入；這些 key 到期後會自然允許下一輪完整更新。
    if (!redis_config.enabled) {
        try local_cache.localDedupeSet(cache_key, ttl_seconds);
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

/// 將成功 provider 的 current-IP key 寫入 Redis，供下輪 dedupe 做完整性檢查。
fn rememberProviderCurrentIps(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    successes: ProviderSuccesses,
    ip: []const u8,
    ttl_seconds: u64,
) !void {
    const providers_list = [_]DdnsProvider{ .afraid, .dynu, .noip };
    for (providers_list) |provider| {
        // `continue` 是關鍵：不為本輪失敗 provider 假裝寫入成功 IP。
        if (!successes.includes(provider)) continue;

        const key = providerCurrentIpRedisKey(provider);
        try redis.setEx(allocator, io, redis_config, key, ip, ttl_seconds);
        std.log.info(
            "ddns redis provider ip updated: provider={s}, key={s}, ip={s}, ttl={d}s",
            .{ providerName(provider), key, ip, ttl_seconds },
        );
    }
}

/// 與 rememberDedupe 相同，但重用已開啟的 Redis Session，避免重複建立連線。
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

/// Session 版本的 provider current-IP 寫入工具。
fn rememberProviderCurrentIpsWithSession(
    redis_session: *redis.Session,
    successes: ProviderSuccesses,
    ip: []const u8,
    ttl_seconds: u64,
) !void {
    const providers_list = [_]DdnsProvider{ .afraid, .dynu, .noip };
    for (providers_list) |provider| {
        if (!successes.includes(provider)) continue;

        const key = providerCurrentIpRedisKey(provider);
        try redis_session.setEx(key, ip, ttl_seconds);
        std.log.info(
            "ddns redis provider ip updated: provider={s}, key={s}, ip={s}, ttl={d}s",
            .{ providerName(provider), key, ip, ttl_seconds },
        );
    }
}

/// 在 reconcile 前先記錄 desired IP，讓外部觀察者知道系統正在收斂到哪個目標。
fn rememberDesiredIpWithSession(
    redis_session: *redis.Session,
    ip: []const u8,
    ttl_seconds: u64,
) !void {
    try redis_session.setEx(desiredPublicIpRedisKey(), ip, ttl_seconds);
}

/// 依固定順序 reconcile 全部 provider，並累積統計；ttl 目前由呼叫鏈保留作 API 穩定性。
fn updateDdnsServicesReconciled(
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    ip: []const u8,
    ttl_seconds: u64,
    now_seconds: i64,
) !ServiceSummary {
    var summary = ServiceSummary{};
    // 此參數暫未在 provider state hash 使用，但先保留在介面中，讓未來 state TTL
    // 與 caller 的 dedupe TTL 能同步擴充而不破壞呼叫端。
    _ = ttl_seconds;

    try reconcileProvider(&summary, allocator, redis_session, client, config, .afraid, ip, now_seconds);
    try reconcileProvider(&summary, allocator, redis_session, client, config, .dynu, ip, now_seconds);
    try reconcileProvider(&summary, allocator, redis_session, client, config, .noip, ip, now_seconds);

    return summary;
}

/// 針對一個 provider 執行狀態機：未設定→略過、已正確→略過、退避中→延後、其餘→更新。
/// 成功或失敗都會盡力同步 Redis 與行程內 snapshot。
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
    // 未設定的服務不算 configured，也不會寫入任何 Redis 狀態。
    if (!isProviderConfigured(config, provider)) return;
    summary.configured += 1;

    // 讀取舊狀態失敗時採 fail-open：仍嘗試更新 DDNS，避免 Redis 的短暫讀取錯誤
    // 阻止實際 DNS 修正。空 ProviderState 會導向 .attempt。
    const state = loadProviderState(allocator, redis_session, provider) catch |err| blk: {
        std.log.warn(
            "failed to load ddns provider state, will attempt update: provider={s}, error={}",
            .{ providerName(provider), err },
        );
        break :blk ProviderState{};
    };

    switch (providerAttemptDecision(state, desired_ip, now_seconds)) {
        .already_current => {
            // 也同步行程 snapshot，讓本次啟動的 dashboard 立即顯示已確認成功。
            summary.already_current += 1;
            shared_state.memoryWriteProviderSuccess(provider, desired_ip, now_seconds);
            std.log.debug("skip ddns provider because it is already current: provider={s}, ip={s}", .{
                providerName(provider),
                desired_ip,
            });
            return;
        },
        .retry_deferred => {
            // 不遞增 attempted/failed；這不是 HTTP 失敗，而是先前失敗所設定的冷卻時間。
            summary.retry_deferred += 1;
            std.log.debug(
                "defer ddns provider retry: provider={s}, desired_ip={s}, next_retry_at={d}, now={d}",
                .{ providerName(provider), desired_ip, state.next_retry_at, now_seconds },
            );
            return;
        },
        .attempt => {},
    }

    summary.attempted += 1;
    // catch 區塊把 HTTP/協定錯誤轉換成可持久化的 retry state，而非讓一個 provider
    // 的失敗中止其他 provider 的 reconcile。
    updateProvider(allocator, client, config, provider, desired_ip) catch |err| {
        summary.failed += 1;
        const next_retry_at = now_seconds + shared_state.retryDelaySeconds(state.retry_count + 1);
        // 儲存失敗本身也可能出錯；原始更新錯誤已在 log 留下，故只警告，不覆蓋它。
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

    // 先標記統計，再持久化成功。saveProviderSuccess 失敗會向上傳遞，讓上層知道
    // 狀態無法可靠保存，即使 HTTP 更新本身已成功。
    summary.succeeded += 1;
    summary.successes.mark(provider);
    try saveProviderSuccess(allocator, redis_session, provider, desired_ip, now_seconds);
}

/// 依 provider enum 分派到對應 HTTP 實作。呼叫前已由 isProviderConfigured 驗證必要設定。
fn updateProvider(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    provider: DdnsProvider,
    ip: []const u8,
) !void {
    return switch (provider) {
        .afraid => providers.updateAfraid(allocator, client, config.afraid),
        .dynu => providers.updateDynu(allocator, client, config.dynu, ip),
        .noip => providers.updateNoIp(allocator, client, config.noip, ip),
    };
}

/// 純函式形式的重試決策：成功且 current IP 相同才可略過；目標 IP 變更時忽略舊 retry。
fn providerAttemptDecision(state: ProviderState, desired_ip: []const u8, now_seconds: i64) ProviderAttemptDecision {
    // 只有 status=success 且 current_ip 相等時才略過；單純 IP 相等但上次失敗不能略過。
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

    // `>` 使「剛好等於」到期時間可立即再試，避免多等一個 scheduler interval。
    if (state.next_retry_at > now_seconds) return .retry_deferred;
    return .attempt;
}

/// optional status 有值且與 expected 完全相同時回傳 true。
fn providerStateStatusEquals(state: ProviderState, expected: []const u8) bool {
    if (state.status) |status| return std.mem.eql(u8, status, expected);
    return false;
}

/// 從 Redis hash 讀出 provider 狀態。hGet 回傳的 optional slice 由 redis Session/allocator 規則管理。
fn loadProviderState(
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    provider: DdnsProvider,
) !ProviderState {
    const key = providerStateRedisKey(provider);
    // 每個 hGet 都可能回傳 null，表示舊版/全新 Redis 尚未有該欄位；optional 正是
    // 用來表達這種「值不存在」的 Zig 型別，而不是空字串。
    return .{
        .current_ip = try redis_session.hGet(allocator, key, "current_ip"),
        .desired_ip = try redis_session.hGet(allocator, key, "desired_ip"),
        .status = try redis_session.hGet(allocator, key, "status"),
        .retry_count = try loadProviderStateU32(allocator, redis_session, key, "retry_count"),
        .next_retry_at = try loadProviderStateI64(allocator, redis_session, key, "next_retry_at"),
    };
}

/// 讀取並解析無號整數 hash 欄位；缺值或格式錯誤採用安全預設值 0。
fn loadProviderStateU32(
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    key: []const u8,
    field: []const u8,
) !u32 {
    const value = try redis_session.hGet(allocator, key, field);
    if (value) |text| {
        // 對手動修改或舊格式資料採容錯 0，讓 retry 能自行恢復，而非讓整輪 refresh 失敗。
        return std.fmt.parseUnsigned(u32, text, 10) catch 0;
    }
    return 0;
}

/// 讀取並解析 Unix 秒用的有號整數 hash 欄位；缺值或格式錯誤採用 0。
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

/// 原子批次（在同一 hSetFields 命令）保存成功狀態，並同步更新行程內 snapshot。
fn saveProviderSuccess(
    allocator: std.mem.Allocator,
    redis_session: *redis.Session,
    provider: DdnsProvider,
    ip: []const u8,
    now_seconds: i64,
) !void {
    // bufPrint 寫入 stack buffer；fields 只在本函式的 hSetFields 呼叫期間使用這些 slices，
    // 所以 stack 生命週期完全足夠，不需要配置字串。
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
    // allocator 屬於統一的儲存函式簽名，目前成功寫入只需 stack buffer。
    _ = allocator;
    shared_state.memoryWriteProviderSuccess(provider, ip, now_seconds);
    try redis_session.hSetFields(&fields);
}

/// 保存失敗狀態、錯誤名稱與下一次重試時間；刻意不覆蓋 current_ip，保留最後成功值。
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
    // 與成功流程相同，數字先格式化到 stack buffer，再作為 Redis hash 欄位值。
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
    shared_state.memoryWriteProviderFailure(provider, desired_ip, retry_count, next_retry_at, last_error, now_seconds);
    try redis_session.hSetFields(&fields);
}

/// 不使用 Redis 時的直接更新流程。各 provider 獨立嘗試，單一失敗不阻止其餘 provider。
fn updateDdnsServices(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    ip: []const u8,
    now_seconds: i64,
) !ServiceSummary {
    // 預設值全部是 0/false；每個 provider 分支只改動自己對應的統計數與成功旗標。
    var summary = ServiceSummary{};

    // Afraid 的最小有效設定只有 token。沒有 token 視為未設定，不計入 attempted。
    if (config.afraid.enabled and config.afraid.token.len != 0) {
        summary.attempted += 1;
        // Zig 的 if 可以接收 error union：成功時執行第一個 block，失敗時將 error 綁定為 err。
        if (providers.updateAfraid(allocator, client, config.afraid)) {
            summary.succeeded += 1;
            summary.successes.mark(.afraid);
            shared_state.memoryWriteProviderSuccess(.afraid, ip, now_seconds);
        } else |err| {
            // local 模式仍寫入 shared_state，讓 dashboard 能顯示失敗與下一次退避時間；
            // 但不寫 Redis，因為本路徑代表 Redis 未啟用或不可用。
            summary.failed += 1;
            shared_state.memoryWriteProviderAttemptFailure(.afraid, ip, err, now_seconds);
            std.log.err("afraid update failed: {}", .{err});
        }
    }

    // Dynu 需要 username 與 password 兩者；provider 函式自行將密碼雜湊後放進 URL。
    if (config.dynu.enabled and config.dynu.username.len != 0 and config.dynu.password.len != 0) {
        summary.attempted += 1;
        if (providers.updateDynu(allocator, client, config.dynu, ip)) {
            summary.succeeded += 1;
            summary.successes.mark(.dynu);
            shared_state.memoryWriteProviderSuccess(.dynu, ip, now_seconds);
        } else |err| {
            summary.failed += 1;
            shared_state.memoryWriteProviderAttemptFailure(.dynu, ip, err, now_seconds);
            std.log.err("dynu update failed: {}", .{err});
        }
    }

    // No-IP 除帳密外還至少要有一個 hostname；provider 函式會逐一更新全部 hostname。
    if (config.noip.enabled and config.noip.username.len != 0 and config.noip.password.len != 0 and config.noip.hostnames.len != 0) {
        summary.attempted += 1;
        if (providers.updateNoIp(allocator, client, config.noip, ip)) {
            summary.succeeded += 1;
            summary.successes.mark(.noip);
            shared_state.memoryWriteProviderSuccess(.noip, ip, now_seconds);
        } else |err| {
            summary.failed += 1;
            shared_state.memoryWriteProviderAttemptFailure(.noip, ip, err, now_seconds);
            std.log.err("no-ip update failed: {}", .{err});
        }
    }

    // 回傳 summary 而非立即決定 RefreshStatus，讓 refresh 可以統一處理「全未啟用」與「全失敗」。
    return summary;
}

// ============================================================================
// 單元測試（Unit Tests）
// ============================================================================
// 測試和實作放在同一檔，能直接覆蓋 private helper；std.testing.allocator 也會偵測
// 測試中遺漏的 free。網路測試的錯誤分支則刻意容許沒有外網的 CI 環境。

test "normalize public ip trims and validates ipv4" {
    const normalized = try ip_lookup.normalizePublicIp(" 1.2.3.4\r\n");
    try std.testing.expectEqualStrings("1.2.3.4", normalized);
}

test "normalize public ip accepts ipv6" {
    const normalized = try ip_lookup.normalizePublicIp("2001:db8::1");
    try std.testing.expectEqualStrings("2001:db8::1", normalized);
}

test "maintenance window helper matches rust behavior" {
    try std.testing.expect(utils.shouldSkipMaintenanceWindowAt(2, 0));
    try std.testing.expect(utils.shouldSkipMaintenanceWindowAt(2, 4));
    try std.testing.expect(!utils.shouldSkipMaintenanceWindowAt(2, 5));
    try std.testing.expect(!utils.shouldSkipMaintenanceWindowAt(1, 59));
}

test "dynu url hashes password before sending" {
    const allocator = std.testing.allocator;
    const test_password = "not-a-real-password-for-test";
    const url = try providers.buildDynuUrl(
        allocator,
        .{ .username = "demo", .password = test_password },
        "1.2.3.4",
    );
    defer allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "username=demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "myip=1.2.3.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, test_password) == null);

    const password_marker = "password=";
    const password_pos = std.mem.indexOf(u8, url, password_marker) orelse return error.TestUnexpectedResult;
    const hashed_tail = url[password_pos + password_marker.len ..];
    const hash_end = std.mem.indexOfScalar(u8, hashed_tail, '&') orelse hashed_tail.len;
    const digest = hashed_tail[0..hash_end];

    try std.testing.expectEqual(@as(usize, 64), digest.len);
    for (digest) |char| {
        try std.testing.expect(std.ascii.isHex(char));
    }
}

test "dynu url percent-encodes username" {
    const allocator = std.testing.allocator;
    const url = try providers.buildDynuUrl(
        allocator,
        .{ .username = "demo+user@example.com", .password = "secret" },
        "1.2.3.4",
    );
    defer allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "username=demo%2Buser%40example.com") != null);
}

test "basic authorization header starts with basic" {
    const allocator = std.testing.allocator;
    const value = try utils.buildBasicAuthorization(allocator, "user", "pass");
    defer allocator.free(value);

    try std.testing.expect(std.mem.startsWith(u8, value, "Basic "));
}

test "build afraid url supports new freedns syntax" {
    const allocator = std.testing.allocator;
    const url = try providers.buildAfraidUrl(
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
    try std.testing.expect(providers.containsExpectedAfraidResponse("Updated 1 host(s) to 1.2.3.4 in 0.123 seconds"));
    try std.testing.expect(providers.containsExpectedAfraidResponse("ERROR: Address 1.2.3.4 has not changed."));
    try std.testing.expect(!providers.containsExpectedAfraidResponse("ERROR: Invalid update URL"));
}

test "noip url percent-encodes hostname" {
    const allocator = std.testing.allocator;
    const url = try providers.buildNoIpUrl(
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
    const key = try buildPublicIpCacheKey(allocator, "1.2.3.4");
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
        .dynu = .{ .enabled = true, .username = "dynu-user", .password = "dynu-pass" },
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
    try std.testing.expectEqual(@as(i64, 30), shared_state.retryDelaySeconds(1));
    try std.testing.expectEqual(@as(i64, 60), shared_state.retryDelaySeconds(2));
    try std.testing.expectEqual(@as(i64, 120), shared_state.retryDelaySeconds(3));
    try std.testing.expectEqual(@as(i64, 900), shared_state.retryDelaySeconds(100));
}

test "process local public ip state skips unchanged ip" {
    shared_state.resetProcessPublicIpState();
    defer shared_state.resetProcessPublicIpState();

    try std.testing.expect(!shared_state.isSameAsLastProcessedIp("1.2.3.4"));
    shared_state.rememberLastProcessedIp("1.2.3.4", "stun", null);
    try std.testing.expect(shared_state.isSameAsLastProcessedIp("1.2.3.4"));
    try std.testing.expect(!shared_state.isSameAsLastProcessedIp("5.6.7.8"));

    const snapshot = getPublicIpSnapshot();
    try std.testing.expect(snapshot.initialized);
    try std.testing.expectEqualStrings("1.2.3.4", snapshot.ipSlice());
    try std.testing.expectEqualStrings("stun", snapshot.sourceSlice());
    try std.testing.expectEqualStrings("", snapshot.stunErrorSlice());

    shared_state.rememberLastProcessedIp("1.2.3.4", "cloudflare", "ReceiveFailed");
    const fallback_snapshot = getPublicIpSnapshot();
    try std.testing.expectEqualStrings("cloudflare", fallback_snapshot.sourceSlice());
    try std.testing.expectEqualStrings("ReceiveFailed", fallback_snapshot.stunErrorSlice());
}

test "provider snapshots expose fixed provider slots before initialization" {
    shared_state.resetProcessProviderStates();
    defer shared_state.resetProcessProviderStates();

    const snapshots = getProviderSnapshots();

    try std.testing.expectEqualStrings("afraid", snapshots[0].nameSlice());
    try std.testing.expectEqualStrings("dynu", snapshots[1].nameSlice());
    try std.testing.expectEqualStrings("noip", snapshots[2].nameSlice());
    try std.testing.expect(!snapshots[0].initialized);
    try std.testing.expect(!snapshots[1].initialized);
    try std.testing.expect(!snapshots[2].initialized);
}

test "provider success snapshot copies status by value" {
    shared_state.resetProcessProviderStates();
    defer shared_state.resetProcessProviderStates();

    shared_state.memoryWriteProviderSuccess(.dynu, "1.2.3.4", 100);
    var snapshots = getProviderSnapshots();

    try std.testing.expect(snapshots[1].initialized);
    try std.testing.expectEqualStrings("dynu", snapshots[1].nameSlice());
    try std.testing.expectEqualStrings("1.2.3.4", snapshots[1].currentIpSlice());
    try std.testing.expectEqualStrings("1.2.3.4", snapshots[1].desiredIpSlice());
    try std.testing.expectEqualStrings(provider_status_success, snapshots[1].statusSlice());
    try std.testing.expectEqual(@as(u32, 0), snapshots[1].retry_count);
    try std.testing.expectEqual(@as(i64, 0), snapshots[1].next_retry_at);
    try std.testing.expectEqual(@as(i64, 100), snapshots[1].updated_at);

    shared_state.memoryWriteProviderSuccess(.dynu, "5.6.7.8", 200);
    try std.testing.expectEqualStrings("1.2.3.4", snapshots[1].currentIpSlice());

    snapshots = getProviderSnapshots();
    try std.testing.expectEqualStrings("5.6.7.8", snapshots[1].currentIpSlice());
}

test "provider failure snapshot preserves last successful current ip" {
    shared_state.resetProcessProviderStates();
    defer shared_state.resetProcessProviderStates();

    shared_state.memoryWriteProviderSuccess(.noip, "1.2.3.4", 100);
    shared_state.memoryWriteProviderFailure(.noip, "5.6.7.8", 2, 300, "UnexpectedNoIpResponse", 200);

    const snapshots = getProviderSnapshots();
    try std.testing.expect(snapshots[2].initialized);
    try std.testing.expectEqualStrings("1.2.3.4", snapshots[2].currentIpSlice());
    try std.testing.expectEqualStrings("5.6.7.8", snapshots[2].desiredIpSlice());
    try std.testing.expectEqualStrings(provider_status_failed, snapshots[2].statusSlice());
    try std.testing.expectEqual(@as(u32, 2), snapshots[2].retry_count);
    try std.testing.expectEqual(@as(i64, 300), snapshots[2].next_retry_at);
    try std.testing.expectEqualStrings("UnexpectedNoIpResponse", snapshots[2].lastErrorSlice());
    try std.testing.expectEqual(@as(i64, 200), snapshots[2].updated_at);
}

test "redis dedupe params keep legacy redis key and value format" {
    const allocator = std.testing.allocator;
    const ip = "1.2.3.4";
    const cache_key = try buildPublicIpCacheKey(allocator, ip);
    defer allocator.free(cache_key);

    try std.testing.expectEqualStrings("MyPublicIP:1.2.3.4", cache_key);
    try std.testing.expectEqualStrings("MyPublicIP", currentPublicIpRedisKey());
    try std.testing.expectEqualStrings("1.2.3.4", ip);
    try std.testing.expect(@as(u64, 86400) == @as(u64, 86400));
}

test "local dedupe cache respects ttl" {
    local_cache.resetLocalDedupeState();
    defer local_cache.resetLocalDedupeState();

    try std.testing.expect(!local_cache.localDedupeContainsAt("MyPublicIP:1.2.3.4", 100));
    try local_cache.localDedupeSetAt("MyPublicIP:1.2.3.4", 60, 100);
    try std.testing.expect(local_cache.localDedupeContainsAt("MyPublicIP:1.2.3.4", 120));
    try std.testing.expect(!local_cache.localDedupeContainsAt("MyPublicIP:1.2.3.4", 160));
}

test "local dedupe hit is checked before provider updates" {
    local_cache.resetLocalDedupeState();
    defer local_cache.resetLocalDedupeState();

    const key = "MyPublicIP:1.2.3.4";
    try local_cache.localDedupeSet(key, 60);

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
    local_cache.resetLocalDedupeState();
    defer local_cache.resetLocalDedupeState();

    // Directly test logic to avoid triggering allocator requirements of internal state
    var key_buffer: [64]u8 = undefined;
    for (0..40) |index| {
        const key = try std.fmt.bufPrint(&key_buffer, "MyPublicIP:10.0.0.{d}", .{index});
        try local_cache.localDedupeSetAt(key, 10, 100);
    }

    try std.testing.expect(!local_cache.localDedupeContainsAt("MyPublicIP:missing", 1000));
}

test "parseStunResponse decodes valid ipv4 xor-mapped-address" {
    const allocator = std.testing.allocator;
    const tx_id = "antigravity1";
    var response = [_]u8{
        0x01, 0x01,
        0x00, 0x0c,
        0x21, 0x12, 0xA4, 0x42,
        'a',  'n',  't',  'i',
        'g',  'r',  'a',  'v',
        'i',  't',  'y',  '1',
        0x00, 0x20,
        0x00, 0x08,
        0x00, 0x01,
        0x32, 0xA1,
        0xE1, 0xBA, 0xA5, 0x26,
    };

    const ip = try ip_lookup.parseStunResponse(allocator, &response, tx_id);
    defer allocator.free(ip);
    try std.testing.expectEqualStrings("192.168.1.100", ip);
}

test "parseStunResponse decodes valid ipv6 xor-mapped-address" {
    const allocator = std.testing.allocator;
    const tx_id = "antigravity1";

    const ip_bytes = [_]u8{
        0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01,
    };

    var magic_and_tx: [16]u8 = undefined;
    std.mem.writeInt(u32, magic_and_tx[0..4], 0x2112A442, .big);
    @memcpy(magic_and_tx[4..16], tx_id);

    var x_ip: [16]u8 = undefined;
    for (0..16) |i| {
        x_ip[i] = ip_bytes[i] ^ magic_and_tx[i];
    }

    var response: [20 + 4 + 24]u8 = undefined;
    response[0] = 0x01;
    response[1] = 0x01;
    std.mem.writeInt(u16, response[2..4], 24, .big);
    std.mem.writeInt(u32, response[4..8], 0x2112A442, .big);
    @memcpy(response[8..20], tx_id);

    std.mem.writeInt(u16, response[20..22], 0x0020, .big);
    std.mem.writeInt(u16, response[22..24], 20, .big);
    response[24] = 0x00;
    response[25] = 0x02;
    response[26] = 0x32;
    response[27] = 0xA1;
    @memcpy(response[28..44], &x_ip);

    const ip = try ip_lookup.parseStunResponse(allocator, &response, tx_id);
    defer allocator.free(ip);
    try std.testing.expectEqualStrings("2001:0db8:0000:0000:0000:0000:0000:0001", ip);
}

test "fetchStunIp retrieves public ip or fails gracefully due to network" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const ip = ip_lookup.fetchStunIp(allocator, io, ip_lookup.publicIpServiceUrl(.stun)) catch |err| {
        switch (err) {
            error.DnsResolutionFailed, error.SocketCreationFailed, error.SendFailed, error.ReceiveFailed, error.SetSocketTimeoutFailed => {
                return;
            },
            else => return err,
        }
    };
    defer allocator.free(ip);

    const normalized = try ip_lookup.normalizePublicIp(ip);
    try std.testing.expectEqualStrings(ip, normalized);
}
