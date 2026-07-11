//! 行程內共享狀態的唯一讀寫入口。為 dashboard 提供「複製後的 snapshot」，
//! 使呼叫端不會持有 mutex 保護中的內部記憶體。
const std = @import("std");
const types = @import("types.zig");
const DdnsProvider = types.DdnsProvider;
const ProviderSnapshot = types.ProviderSnapshot;
const PublicIpSnapshot = types.PublicIpSnapshot;
const ProcessProviderState = types.ProcessProviderState;
const ProcessPublicIpState = types.ProcessPublicIpState;

/// 寫入 snapshot 與 Redis 時使用的成功狀態文字。
const provider_status_success = "success";
const provider_status_failed = "failed";
const provider_retry_initial_delay_seconds: i64 = 30;
const provider_retry_max_delay_seconds: i64 = 15 * 60;

/// 最近處理 IP 的共享狀態；它自己的 mutex 保護所有欄位。
var process_public_ip_state: ProcessPublicIpState = .{};
/// 保護下方固定三格的 provider 陣列。
var process_provider_mutex: std.atomic.Mutex = .unlocked;
/// 每個支援的 provider 一格，索引由 providerSlot 集中轉換，勿直接猜測索引。
/// Cloudflare 加入後共有四個固定 provider slot；slot 的對應集中在 providerSlot。
var process_provider_states: [4]ProcessProviderState = .{ .{}, .{}, .{}, .{} };

/// 回傳第 N 次連續失敗後的等待秒數：30, 60, 120...，最長 15 分鐘。
pub fn retryDelaySeconds(retry_count: u32) i64 {
    if (retry_count == 0) return provider_retry_initial_delay_seconds;

    const exponent = @min(retry_count - 1, 5);
    const delay = provider_retry_initial_delay_seconds * (@as(i64, 1) << @intCast(exponent));
    return @min(delay, provider_retry_max_delay_seconds);
}

/// 將 provider enum 映射到固定陣列索引；新增供應商時需同步調整陣列大小與此處。
fn providerSlot(provider: DdnsProvider) usize {
    return switch (provider) {
        .cloudflare => 0,
        .afraid => 1,
        .dynu => 2,
        .noip => 3,
    };
}

/// 取得穩定、適合 dashboard 顯示的 provider 名稱。
fn providerKey(provider: DdnsProvider) []const u8 {
    return switch (provider) {
        .cloudflare => "cloudflare",
        .afraid => "afraid",
        .dynu => "dynu",
        .noip => "noip",
    };
}

/// 取得三個 provider 的「值複製」快照。鎖會在 return 前釋放，快照可安全交給其他執行緒。
pub fn getProviderSnapshots() [4]ProviderSnapshot {
    lockProcessProviderStates();
    defer process_provider_mutex.unlock();

    return .{
        providerSnapshotFromState(.cloudflare, process_provider_states[providerSlot(.cloudflare)]),
        providerSnapshotFromState(.afraid, process_provider_states[providerSlot(.afraid)]),
        providerSnapshotFromState(.dynu, process_provider_states[providerSlot(.dynu)]),
        providerSnapshotFromState(.noip, process_provider_states[providerSlot(.noip)]),
    };
}

/// 取得最近 public IP 的值複製快照；尚未初始化時回傳所有預設值。
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

/// 將內部 provider state 轉為對外 snapshot，並補上內部 state 沒保存的 provider 名稱。
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

/// 記錄一次 provider 成功：目前 IP 與目標 IP 都成為 ip，並清除舊的 retry/error 資訊。
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

/// 記錄一次 provider 失敗。保留 current_ip，因它仍代表「最後確認成功」的值。
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

/// 在鎖保護下讀出重試次數；回傳純數值，因此釋鎖後仍安全。
pub fn processProviderRetryCount(provider: DdnsProvider) u32 {
    lockProcessProviderStates();
    defer process_provider_mutex.unlock();

    return process_provider_states[providerSlot(provider)].retry_count;
}

/// 以目前 retry_count 計算下一次退避時間，並把 Zig error 名稱寫入 failure state。
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

/// 清空所有 provider 行程內狀態，主要供測試隔離使用。
pub fn resetProcessProviderStates() void {
    lockProcessProviderStates();
    defer process_provider_mutex.unlock();

    process_provider_states = .{ .{}, .{}, .{}, .{} };
}

/// 取得 provider 陣列的自旋鎖；等候時 yield 降低忙等的 CPU 使用。
fn lockProcessProviderStates() void {
    while (!process_provider_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

/// 將 slice 複製到固定陣列，且以 len 回報有效範圍。過長值會被安全截斷。
/// buffer 是 anytype，讓同一工具適用於不同大小的 `[N]u8` 陣列。
fn copyToFixedBuffer(buffer: anytype, len: *usize, value: []const u8) void {
    const copy_len = @min(value.len, buffer.len);
    if (copy_len != 0) @memcpy(buffer[0..copy_len], value[0..copy_len]);
    len.* = copy_len;
}

/// 判斷 IP 是否和本行程最近完整處理的 IP 相同；未初始化時永遠不命中。
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

/// 記錄最近處理 IP、成功來源與可選 STUN 錯誤。所有輸入會複製到固定 buffer，
/// 因此呼叫端可在本函式回傳後釋放自己的 slice。
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

/// 將 public IP 狀態標為未初始化並清空有效長度；不必清除 undefined buffer 內容。
pub fn resetProcessPublicIpState() void {
    lockProcessPublicIpState();
    defer process_public_ip_state.mutex.unlock();

    process_public_ip_state.initialized = false;
    process_public_ip_state.len = 0;
    process_public_ip_state.source_len = 0;
    process_public_ip_state.stun_error_len = 0;
}

/// 取得 public IP struct 自帶的自旋鎖。
fn lockProcessPublicIpState() void {
    while (!process_public_ip_state.mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}
