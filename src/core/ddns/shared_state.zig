const std = @import("std");
const types = @import("types.zig");
const DdnsProvider = types.DdnsProvider;
const ProviderSnapshot = types.ProviderSnapshot;
const PublicIpSnapshot = types.PublicIpSnapshot;
const ProcessProviderState = types.ProcessProviderState;
const ProcessPublicIpState = types.ProcessPublicIpState;

const provider_status_success = "success";
const provider_status_failed = "failed";
const provider_retry_initial_delay_seconds: i64 = 30;
const provider_retry_max_delay_seconds: i64 = 15 * 60;

var process_public_ip_state: ProcessPublicIpState = .{};
var process_provider_mutex: std.atomic.Mutex = .unlocked;
var process_provider_states: [3]ProcessProviderState = .{ .{}, .{}, .{} };

pub fn retryDelaySeconds(retry_count: u32) i64 {
    if (retry_count == 0) return provider_retry_initial_delay_seconds;

    const exponent = @min(retry_count - 1, 5);
    const delay = provider_retry_initial_delay_seconds * (@as(i64, 1) << @intCast(exponent));
    return @min(delay, provider_retry_max_delay_seconds);
}

fn providerSlot(provider: DdnsProvider) usize {
    return switch (provider) {
        .afraid => 0,
        .dynu => 1,
        .noip => 2,
    };
}

fn providerKey(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .afraid => "afraid",
        .dynu => "dynu",
        .noip => "noip",
    };
}

pub fn getProviderSnapshots() [3]ProviderSnapshot {
    lockProcessProviderStates();
    defer process_provider_mutex.unlock();

    return .{
        providerSnapshotFromState(.afraid, process_provider_states[providerSlot(.afraid)]),
        providerSnapshotFromState(.dynu, process_provider_states[providerSlot(.dynu)]),
        providerSnapshotFromState(.noip, process_provider_states[providerSlot(.noip)]),
    };
}

pub fn getPublicIpSnapshot() PublicIpSnapshot {
    lockProcessPublicIpState();
    defer process_public_ip_state.mutex.unlock();

    if (!process_public_ip_state.initialized) return .{};

    var snapshot = PublicIpSnapshot{
        .initialized = true,
        .len = process_public_ip_state.len,
        .source_len = process_public_ip_state.source_len,
        .stun_error_len = process_public_ip_state.stun_error_len,
    };
    @memcpy(snapshot.buffer[0..process_public_ip_state.len], process_public_ip_state.buffer[0..process_public_ip_state.len]);
    if (process_public_ip_state.source_len != 0) {
        @memcpy(
            snapshot.source[0..process_public_ip_state.source_len],
            process_public_ip_state.source[0..process_public_ip_state.source_len],
        );
    }
    if (process_public_ip_state.stun_error_len != 0) {
        @memcpy(
            snapshot.stun_error[0..process_public_ip_state.stun_error_len],
            process_public_ip_state.stun_error[0..process_public_ip_state.stun_error_len],
        );
    }
    return snapshot;
}

fn providerSnapshotFromState(provider: DdnsProvider, state: ProcessProviderState) ProviderSnapshot {
    var snapshot = ProviderSnapshot{
        .initialized = state.initialized,
        .current_ip = state.current_ip,
        .current_ip_len = state.current_ip_len,
        .desired_ip = state.desired_ip,
        .desired_ip_len = state.desired_ip_len,
        .status = state.status,
        .status_len = state.status_len,
        .retry_count = state.retry_count,
        .next_retry_at = state.next_retry_at,
        .last_error = state.last_error,
        .last_error_len = state.last_error_len,
        .updated_at = state.updated_at,
    };
    copyToFixedBuffer(&snapshot.name, &snapshot.name_len, providerKey(provider));
    return snapshot;
}

pub fn memoryWriteProviderSuccess(provider: DdnsProvider, ip: []const u8, now_seconds: i64) void {
    lockProcessProviderStates();
    defer process_provider_mutex.unlock();

    const state = &process_provider_states[providerSlot(provider)];
    state.initialized = true;
    copyToFixedBuffer(&state.current_ip, &state.current_ip_len, ip);
    copyToFixedBuffer(&state.desired_ip, &state.desired_ip_len, ip);
    copyToFixedBuffer(&state.status, &state.status_len, provider_status_success);
    state.retry_count = 0;
    state.next_retry_at = 0;
    state.last_error_len = 0;
    state.updated_at = now_seconds;
}

pub fn memoryWriteProviderFailure(
    provider: DdnsProvider,
    desired_ip: []const u8,
    retry_count: u32,
    next_retry_at: i64,
    last_error: []const u8,
    now_seconds: i64,
) void {
    lockProcessProviderStates();
    defer process_provider_mutex.unlock();

    const state = &process_provider_states[providerSlot(provider)];
    state.initialized = true;
    copyToFixedBuffer(&state.desired_ip, &state.desired_ip_len, desired_ip);
    copyToFixedBuffer(&state.status, &state.status_len, provider_status_failed);
    state.retry_count = retry_count;
    state.next_retry_at = next_retry_at;
    copyToFixedBuffer(&state.last_error, &state.last_error_len, last_error);
    state.updated_at = now_seconds;
}

pub fn processProviderRetryCount(provider: DdnsProvider) u32 {
    lockProcessProviderStates();
    defer process_provider_mutex.unlock();

    return process_provider_states[providerSlot(provider)].retry_count;
}

pub fn memoryWriteProviderAttemptFailure(
    provider: DdnsProvider,
    desired_ip: []const u8,
    err: anyerror,
    now_seconds: i64,
) void {
    const retry_count = processProviderRetryCount(provider) + 1;
    const next_retry_at = now_seconds + retryDelaySeconds(retry_count);
    memoryWriteProviderFailure(
        provider,
        desired_ip,
        retry_count,
        next_retry_at,
        @errorName(err),
        now_seconds,
    );
}

pub fn resetProcessProviderStates() void {
    lockProcessProviderStates();
    defer process_provider_mutex.unlock();

    process_provider_states = .{ .{}, .{}, .{} };
}

fn lockProcessProviderStates() void {
    while (!process_provider_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

fn copyToFixedBuffer(buffer: anytype, len: *usize, value: []const u8) void {
    const copy_len = @min(value.len, buffer.len);
    if (copy_len != 0) @memcpy(buffer[0..copy_len], value[0..copy_len]);
    len.* = copy_len;
}

pub fn isSameAsLastProcessedIp(ip: []const u8) bool {
    lockProcessPublicIpState();
    defer process_public_ip_state.mutex.unlock();

    if (!process_public_ip_state.initialized) return false;
    return std.mem.eql(
        u8,
        process_public_ip_state.buffer[0..process_public_ip_state.len],
        ip,
    );
}

pub fn rememberLastProcessedIp(ip: []const u8, source: []const u8, stun_error: ?[]const u8) void {
    lockProcessPublicIpState();
    defer process_public_ip_state.mutex.unlock();

    const copy_len = @min(ip.len, process_public_ip_state.buffer.len);
    @memcpy(process_public_ip_state.buffer[0..copy_len], ip[0..copy_len]);
    process_public_ip_state.len = copy_len;
    const source_copy_len = @min(source.len, process_public_ip_state.source.len);
    if (source_copy_len != 0) {
        @memcpy(process_public_ip_state.source[0..source_copy_len], source[0..source_copy_len]);
    }
    process_public_ip_state.source_len = source_copy_len;

    if (stun_error) |err_name| {
        const stun_error_copy_len = @min(err_name.len, process_public_ip_state.stun_error.len);
        if (stun_error_copy_len != 0) {
            @memcpy(
                process_public_ip_state.stun_error[0..stun_error_copy_len],
                err_name[0..stun_error_copy_len],
            );
        }
        process_public_ip_state.stun_error_len = stun_error_copy_len;
    } else {
        process_public_ip_state.stun_error_len = 0;
    }
    process_public_ip_state.initialized = true;
}

pub fn resetProcessPublicIpState() void {
    lockProcessPublicIpState();
    defer process_public_ip_state.mutex.unlock();

    process_public_ip_state.initialized = false;
    process_public_ip_state.len = 0;
    process_public_ip_state.source_len = 0;
    process_public_ip_state.stun_error_len = 0;
}

fn lockProcessPublicIpState() void {
    while (!process_public_ip_state.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}
