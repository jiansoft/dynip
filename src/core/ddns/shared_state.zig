//! 行程內共享狀態的唯一讀寫入口。為 dashboard 提供「複製後的 snapshot」，
//! 使呼叫端不會持有 mutex 保護中的內部記憶體。
const std = @import("std");
const types = @import("types.zig");
const DdnsProvider = types.DdnsProvider;
const ProviderSnapshot = types.ProviderSnapshot;
const PublicIpSnapshot = types.PublicIpSnapshot;
const ProcessProviderState = types.ProcessProviderState;
const ProcessPublicIpState = types.ProcessPublicIpState;
const IpFamily = types.IpFamily;

/// 寫入 snapshot 與 Redis 時使用的成功狀態文字。
const provider_status_success = "success";
const provider_status_failed = "failed";
const provider_retry_initial_delay_seconds: i64 = 30;
const provider_retry_max_delay_seconds: i64 = 15 * 60;

/// 最近處理 IP 的共享狀態；它自己的 mutex 保護所有欄位。
var process_public_ip_state: ProcessPublicIpState = .{};
/// 保護下方固定 provider × family 二維陣列。
///
/// 用 `std.Io.Mutex` 而不是 `std.atomic.Mutex`：後者只提供 `tryLock`，當通用鎖用
/// 就得自己寫 `while (!tryLock()) yield()` 的忙等迴圈，競爭時空轉燒 CPU。
/// `std.Io.Mutex.lock` 走 futex，等待中的執行緒會真的睡著。dashboard thread 與
/// scheduler thread 會同時碰這份狀態，這裡是真的有競爭的。
var process_provider_mutex: std.Io.Mutex = .init;
/// 每個支援的 provider 有兩格（[0] IPv4/A、[1] IPv6/AAAA）。
/// 外層索引由 providerSlot 集中轉換，內層索引由 familySlot 集中轉換；
/// 不要直接猜測數字，否則日後新增 provider 或 family 時很容易寫錯狀態。
var process_provider_states: [4][2]ProcessProviderState = .{ .{ .{}, .{} }, .{ .{}, .{} }, .{ .{}, .{} }, .{ .{}, .{} } };

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
pub fn getProviderSnapshots(io: std.Io) [8]ProviderSnapshot {
    process_provider_mutex.lockUncancelable(io);
    defer process_provider_mutex.unlock(io);

    // 回傳值順序同時是 Dashboard 的資料契約：每相鄰兩筆必須是同一 provider 的
    // IPv4 後接 IPv6，這樣 UI 才能穩定把 A / AAAA 放進同一張卡片。
    return .{
        providerSnapshotFromState(.cloudflare, .ipv4, process_provider_states[providerSlot(.cloudflare)][0]),
        providerSnapshotFromState(.cloudflare, .ipv6, process_provider_states[providerSlot(.cloudflare)][1]),
        providerSnapshotFromState(.afraid, .ipv4, process_provider_states[providerSlot(.afraid)][0]),
        providerSnapshotFromState(.afraid, .ipv6, process_provider_states[providerSlot(.afraid)][1]),
        providerSnapshotFromState(.dynu, .ipv4, process_provider_states[providerSlot(.dynu)][0]),
        providerSnapshotFromState(.dynu, .ipv6, process_provider_states[providerSlot(.dynu)][1]),
        providerSnapshotFromState(.noip, .ipv4, process_provider_states[providerSlot(.noip)][0]),
        providerSnapshotFromState(.noip, .ipv6, process_provider_states[providerSlot(.noip)][1]),
    };
}

/// 取得最近 public IP 的值複製快照；尚未初始化時回傳所有預設值。
pub fn getPublicIpSnapshot(io: std.Io) PublicIpSnapshot {
    process_public_ip_state.mutex.lockUncancelable(io);
    defer process_public_ip_state.mutex.unlock(io);

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
fn providerSnapshotFromState(provider: DdnsProvider, family: IpFamily, state: ProcessProviderState) ProviderSnapshot {
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
        // family 不是從 IP 字串臨時推斷，而是從二維陣列的位置帶出；
        // 因此即使該 family 尚未取得 IP，Dashboard 仍能顯示它的 initializing 狀態。
        .family = family,
    };
    copyToFixedBuffer(&snapshot.name, &snapshot.name_len, providerKey(provider));
    return snapshot;
}

/// 記錄一次 provider 成功：目前 IP 與目標 IP 都成為 ip，並清除舊的 retry/error 資訊。
pub fn memoryWriteProviderSuccess(io: std.Io, provider: DdnsProvider, ip: []const u8, now_seconds: i64) void {
    process_provider_mutex.lockUncancelable(io);
    defer process_provider_mutex.unlock(io);

    const state = &process_provider_states[providerSlot(provider)][familySlot(ip)];
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
    io: std.Io,
    provider: DdnsProvider,
    desired_ip: []const u8,
    retry_count: u32,
    next_retry_at: i64,
    last_error: []const u8,
    now_seconds: i64,
) void {
    process_provider_mutex.lockUncancelable(io);
    defer process_provider_mutex.unlock(io);

    const state = &process_provider_states[providerSlot(provider)][familySlot(desired_ip)];
    state.initialized = true;
    copyToFixedBuffer(&state.desired_ip, &state.desired_ip_len, desired_ip);
    copyToFixedBuffer(&state.status, &state.status_len, provider_status_failed);
    state.retry_count = retry_count;
    state.next_retry_at = next_retry_at;
    copyToFixedBuffer(&state.last_error, &state.last_error_len, last_error);
    state.updated_at = now_seconds;
}

/// 在鎖保護下讀出重試次數；回傳純數值，因此釋鎖後仍安全。
pub fn processProviderRetryCount(io: std.Io, provider: DdnsProvider, desired_ip: []const u8) u32 {
    process_provider_mutex.lockUncancelable(io);
    defer process_provider_mutex.unlock(io);

    return process_provider_states[providerSlot(provider)][familySlot(desired_ip)].retry_count;
}

/// 以目前 retry_count 計算下一次退避時間，並把 Zig error 名稱寫入 failure state。
pub fn memoryWriteProviderAttemptFailure(
    io: std.Io,
    provider: DdnsProvider,
    desired_ip: []const u8,
    err: anyerror,
    now_seconds: i64,
) void {
    const retry_count = processProviderRetryCount(io, provider, desired_ip) + 1;
    const next_retry_at = now_seconds + retryDelaySeconds(retry_count);
    memoryWriteProviderFailure(
        io,
        provider,
        desired_ip,
        retry_count,
        next_retry_at,
        @errorName(err),
        now_seconds,
    );
}

/// 清空所有 provider 行程內狀態，主要供測試隔離使用。
pub fn resetProcessProviderStates(io: std.Io) void {
    process_provider_mutex.lockUncancelable(io);
    defer process_provider_mutex.unlock(io);

    process_provider_states = .{ .{ .{}, .{} }, .{ .{}, .{} }, .{ .{}, .{} }, .{ .{}, .{} } };
}

fn familySlot(ip: []const u8) usize {
    // 正常資料在進來前已驗證。此 fallback 只避免壞資料讓記憶體索引越界；
    // 它不代表未知 IP 真的是 IPv4，呼叫端仍應把解析錯誤視為上游問題。
    const parsed = std.Io.net.IpAddress.parse(ip, 0) catch return 0;
    return switch (parsed) {
        .ip4 => 0,
        .ip6 => 1,
    };
}

/// 將 slice 複製到固定陣列，且以 len 回報有效範圍。過長值會被安全截斷。
/// buffer 是 anytype，讓同一工具適用於不同大小的 `[N]u8` 陣列。
fn copyToFixedBuffer(buffer: anytype, len: *usize, value: []const u8) void {
    const copy_len = @min(value.len, buffer.len);
    if (copy_len != 0) @memcpy(buffer[0..copy_len], value[0..copy_len]);
    len.* = copy_len;
}

/// 判斷 IP 是否和本行程最近完整處理的 IP 相同；未初始化時永遠不命中。
pub fn isSameAsLastProcessedIp(io: std.Io, ip: []const u8) bool {
    process_public_ip_state.mutex.lockUncancelable(io);
    defer process_public_ip_state.mutex.unlock(io);

    if (!process_public_ip_state.initialized) return false;
    return std.mem.eql(
        u8,
        process_public_ip_state.buffer[0..process_public_ip_state.len],
        ip,
    );
}

/// 記錄最近處理 IP、成功來源與可選 STUN 錯誤。所有輸入會複製到固定 buffer，
/// 因此呼叫端可在本函式回傳後釋放自己的 slice。
pub fn rememberLastProcessedIp(io: std.Io, ip: []const u8, source: []const u8, stun_error: ?[]const u8) void {
    process_public_ip_state.mutex.lockUncancelable(io);
    defer process_public_ip_state.mutex.unlock(io);

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
pub fn resetProcessPublicIpState(io: std.Io) void {
    process_public_ip_state.mutex.lockUncancelable(io);
    defer process_public_ip_state.mutex.unlock(io);

    process_public_ip_state.initialized = false;
    process_public_ip_state.len = 0;
    process_public_ip_state.source_len = 0;
    process_public_ip_state.stun_error_len = 0;
}

