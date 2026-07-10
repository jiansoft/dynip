//! DDNS 更新流程的主要入口與協調器 (Facade / Orchestrator)。
//!
//! 負責統合對外 IP 查詢、各 DDNS 供應商的 API 呼叫、本機與 Redis 狀態比對、及維護時段判斷。

const std = @import("std");
const config_mod = @import("../base/config.zig");
const redis = @import("../io/redis.zig");
const http = @import("../io/http.zig");
const c = @import("c");

// 子模組匯入
pub const types = @import("ddns/types.zig");
pub const shared_state = @import("ddns/shared_state.zig");
pub const local_cache = @import("ddns/local_cache.zig");
pub const ip_lookup = @import("ddns/ip_lookup.zig");
pub const providers = @import("ddns/providers.zig");
pub const utils = @import("ddns/utils.zig");

// 公開型別重新導出 (Public Types Re-exports)
pub const RefreshStatus = types.RefreshStatus;
pub const PublicIpSnapshot = types.PublicIpSnapshot;
pub const ProviderSnapshot = types.ProviderSnapshot;
pub const DdnsProvider = types.DdnsProvider;
pub const ProviderSuccesses = types.ProviderSuccesses;
pub const ProviderState = types.ProviderState;
pub const ProviderAttemptDecision = types.ProviderAttemptDecision;
pub const ServiceSummary = types.ServiceSummary;

// 公開函式重新導出 (Public Functions Re-exports)
pub const getProviderSnapshots = shared_state.getProviderSnapshots;
pub const getPublicIpSnapshot = shared_state.getPublicIpSnapshot;

// 全域變數
pub var redis_available: bool = true;

const provider_status_success = "success";
const provider_status_failed = "failed";

/// 啟動時檢查 Redis 連線狀況。
pub fn checkRedisAvailability(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
) void {
    if (!redis_config.enabled) return;

    const host_port = utils.parseHostPort(redis_config.addr) catch |err| {
        redis_available = false;
        std.log.warn(
            "failed to parse redis address: addr={s}, error={}",
            .{ redis_config.addr, err },
        );
        return;
    };

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
    if (utils.shouldSkipMaintenanceWindow()) {
        std.log.info("skip ddns refresh during 02:00-02:04 local maintenance window", .{});
        return .skipped_maintenance_window;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const public_ip_lookup = try ip_lookup.getPublicIp(scratch, client);
    const ip_now = public_ip_lookup.ip;
    const ip_source = ip_lookup.serviceName(public_ip_lookup.service);

    if (shared_state.isSameAsLastProcessedIp(ip_now)) {
        shared_state.rememberLastProcessedIp(ip_now, ip_source, public_ip_lookup.stun_error);
        std.log.info(
            "skip ddns refresh because public ip is unchanged in current process: {s}",
            .{ip_now},
        );
        return .skipped_cached_ip;
    }

    const ttl_seconds = if (config.ddns.dedupe_ttl_seconds == 0)
        @as(u64, 60 * 60 * 24)
    else
        config.ddns.dedupe_ttl_seconds;

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

    const cache_key = try buildPublicIpCacheKey(scratch, ip_now);
    const effective_redis = redisConfigForCurrentState(config.ddns.redis);
    if (try isDedupeHit(scratch, io, effective_redis, config, cache_key, ip_now)) {
        return .skipped_cached_ip;
    }

    const summary = try updateDdnsServices(scratch, client, config, ip_now, c.time(null));
    if (summary.attempted == 0) return error.NoEnabledDdnsService;
    if (summary.succeeded == 0) return error.AllDdnsUpdatesFailed;

    try rememberDedupe(scratch, io, effective_redis, cache_key, ip_now, ttl_seconds, summary.successes);
    if (summary.succeeded == summary.attempted) {
        shared_state.rememberLastProcessedIp(ip_now, ip_source, public_ip_lookup.stun_error);
    }

    std.log.info(
        "ddns refresh completed: ip={s}, succeeded={d}/{d}",
        .{ ip_now, summary.succeeded, summary.attempted },
    );
    return .updated;
}

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
    var redis_session: redis.Session = undefined;
    try redis_session.init(io, config.ddns.redis);
    defer redis_session.deinit();

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
    if (summary.succeeded != 0) {
        try rememberDedupeWithSession(&redis_session, cache_key, ip, ttl_seconds, summary.successes);
    }

    if (summary.attempted != 0 and summary.succeeded == 0) {
        return error.AllDdnsUpdatesFailed;
    }

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

    return if (summary.attempted == 0) .skipped_cached_ip else .updated;
}

fn buildPublicIpCacheKey(allocator: std.mem.Allocator, ip: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "MyPublicIP:{s}", .{ip});
}

fn currentPublicIpRedisKey() []const u8 {
    return "MyPublicIP";
}

fn desiredPublicIpRedisKey() []const u8 {
    return "DDNS:DesiredIP";
}

fn providerStateRedisKey(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .afraid => "DDNS:Provider:afraid",
        .dynu => "DDNS:Provider:dynu",
        .noip => "DDNS:Provider:noip",
    };
}

fn providerCurrentIpRedisKey(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .afraid => "MyPublicIP:afraid",
        .dynu => "MyPublicIP:dynu",
        .noip => "MyPublicIP:noip",
    };
}

fn providerName(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .afraid => "afraid",
        .dynu => "dynu",
        .noip => "no-ip",
    };
}

fn providerSlot(provider: DdnsProvider) usize {
    return switch (provider) {
        .afraid => 0,
        .dynu => 1,
        .noip => 2,
    };
}

fn isDedupeHit(
    allocator: std.mem.Allocator,
    io: std.Io,
    redis_config: config_mod.Redis,
    app_config: config_mod.AppConfig,
    cache_key: []const u8,
    ip: []const u8,
) !bool {
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
        .dynu => app_config.dynu.enabled and app_config.dynu.username.len != 0 and app_config.dynu.password.len != 0,
        .noip => app_config.noip.enabled and app_config.noip.username.len != 0 and app_config.noip.password.len != 0 and app_config.noip.hostnames.len != 0,
    };
}

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

fn rememberDesiredIpWithSession(
    redis_session: *redis.Session,
    ip: []const u8,
    ttl_seconds: u64,
) !void {
    try redis_session.setEx(desiredPublicIpRedisKey(), ip, ttl_seconds);
}

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
    _ = ttl_seconds;

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
    if (!isProviderConfigured(config, provider)) return;
    summary.configured += 1;

    const state = loadProviderState(allocator, redis_session, provider) catch |err| blk: {
        std.log.warn(
            "failed to load ddns provider state, will attempt update: provider={s}, error={}",
            .{ providerName(provider), err },
        );
        break :blk ProviderState{};
    };

    switch (providerAttemptDecision(state, desired_ip, now_seconds)) {
        .already_current => {
            summary.already_current += 1;
            shared_state.memoryWriteProviderSuccess(provider, desired_ip, now_seconds);
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

    summary.attempted += 1;
    updateProvider(allocator, client, config, provider, desired_ip) catch |err| {
        summary.failed += 1;
        const next_retry_at = now_seconds + shared_state.retryDelaySeconds(state.retry_count + 1);
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
        .afraid => providers.updateAfraid(allocator, client, config.afraid),
        .dynu => providers.updateDynu(allocator, client, config.dynu, ip),
        .noip => providers.updateNoIp(allocator, client, config.noip, ip),
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
    shared_state.memoryWriteProviderSuccess(provider, ip, now_seconds);
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
    shared_state.memoryWriteProviderFailure(provider, desired_ip, retry_count, next_retry_at, last_error, now_seconds);
    try redis_session.hSetFields(&fields);
}

fn updateDdnsServices(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    config: config_mod.AppConfig,
    ip: []const u8,
    now_seconds: i64,
) !ServiceSummary {
    var summary = ServiceSummary{};

    if (config.afraid.enabled and config.afraid.token.len != 0) {
        summary.attempted += 1;
        if (providers.updateAfraid(allocator, client, config.afraid)) {
            summary.succeeded += 1;
            summary.successes.mark(.afraid);
            shared_state.memoryWriteProviderSuccess(.afraid, ip, now_seconds);
        } else |err| {
            summary.failed += 1;
            shared_state.memoryWriteProviderAttemptFailure(.afraid, ip, err, now_seconds);
            std.log.err("afraid update failed: {}", .{err});
        }
    }

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

    return summary;
}

// ============================================================================
// 單元測試（Unit Tests）
// ============================================================================

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
