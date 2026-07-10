const std = @import("std");

/// 單次更新檢查的結果。
pub const RefreshStatus = enum {
    updated,
    skipped_cached_ip,
    skipped_maintenance_window,
};

/// 取得對外 IP 時，可能依序嘗試的來源站。
pub const PublicIpService = enum {
    stun,
    cloudflare_trace,
};

/// 單次對外 IP 查詢成功後的結果。
pub const PublicIpLookup = struct {
    ip: []const u8,
    service: PublicIpService,
    stun_error: ?[]const u8 = null,
};

/// 目前支援更新的 DDNS 供應商。
pub const DdnsProvider = enum {
    afraid,
    dynu,
    noip,
};

/// 供應商成功狀態，用來決定哪些 provider 要寫回 Redis。
pub const ProviderSuccesses = struct {
    afraid: bool = false,
    dynu: bool = false,
    noip: bool = false,

    pub fn mark(self: *ProviderSuccesses, provider: DdnsProvider) void {
        switch (provider) {
            .afraid => self.afraid = true,
            .dynu => self.dynu = true,
            .noip => self.noip = true,
        }
    }

    pub fn includes(self: ProviderSuccesses, provider: DdnsProvider) bool {
        return switch (provider) {
            .afraid => self.afraid,
            .dynu => self.dynu,
            .noip => self.noip,
        };
    }
};

/// 單一 provider 的持久化更新狀態。
pub const ProviderState = struct {
    current_ip: ?[]const u8 = null,
    desired_ip: ?[]const u8 = null,
    status: ?[]const u8 = null,
    retry_count: u32 = 0,
    next_retry_at: i64 = 0,
};

/// provider 在這一輪是否應該打 DDNS API。
pub const ProviderAttemptDecision = enum {
    attempt,
    already_current,
    retry_deferred,
};

/// 這一輪更新所有 DDNS 供應商後的統計結果。
pub const ServiceSummary = struct {
    configured: usize = 0,
    attempted: usize = 0,
    succeeded: usize = 0,
    already_current: usize = 0,
    retry_deferred: usize = 0,
    failed: usize = 0,
    successes: ProviderSuccesses = .{},
};

/// 對外公開的 public IP 狀態快照。
pub const PublicIpSnapshot = struct {
    initialized: bool = false,
    len: usize = 0,
    buffer: [64]u8 = undefined,
    source_len: usize = 0,
    source: [16]u8 = undefined,
    stun_error_len: usize = 0,
    stun_error: [64]u8 = undefined,

    pub fn ipSlice(self: *const PublicIpSnapshot) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn sourceSlice(self: *const PublicIpSnapshot) []const u8 {
        return self.source[0..self.source_len];
    }

    pub fn stunErrorSlice(self: *const PublicIpSnapshot) []const u8 {
        return self.stun_error[0..self.stun_error_len];
    }
};

/// 對外公開的 provider 狀態快照。
pub const ProviderSnapshot = struct {
    name: [8]u8 = undefined,
    name_len: usize = 0,
    initialized: bool = false,

    current_ip: [64]u8 = undefined,
    current_ip_len: usize = 0,
    desired_ip: [64]u8 = undefined,
    desired_ip_len: usize = 0,
    status: [16]u8 = undefined,
    status_len: usize = 0,

    retry_count: u32 = 0,
    next_retry_at: i64 = 0,

    last_error: [128]u8 = undefined,
    last_error_len: usize = 0,
    updated_at: i64 = 0,

    pub fn nameSlice(self: *const ProviderSnapshot) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn currentIpSlice(self: *const ProviderSnapshot) []const u8 {
        return self.current_ip[0..self.current_ip_len];
    }

    pub fn desiredIpSlice(self: *const ProviderSnapshot) []const u8 {
        return self.desired_ip[0..self.desired_ip_len];
    }

    pub fn statusSlice(self: *const ProviderSnapshot) []const u8 {
        return self.status[0..self.status_len];
    }

    pub fn lastErrorSlice(self: *const ProviderSnapshot) []const u8 {
        return self.last_error[0..self.last_error_len];
    }
};

/// process-level provider 狀態。
pub const ProcessProviderState = struct {
    initialized: bool = false,

    current_ip: [64]u8 = undefined,
    current_ip_len: usize = 0,
    desired_ip: [64]u8 = undefined,
    desired_ip_len: usize = 0,
    status: [16]u8 = undefined,
    status_len: usize = 0,

    retry_count: u32 = 0,
    next_retry_at: i64 = 0,

    last_error: [128]u8 = undefined,
    last_error_len: usize = 0,
    updated_at: i64 = 0,
};

/// 同一個行程內最近一次成功處理過的 public IP。
pub const ProcessPublicIpState = struct {
    mutex: std.atomic.Mutex = .unlocked,
    initialized: bool = false,
    len: usize = 0,
    buffer: [64]u8 = undefined,
    source_len: usize = 0,
    source: [16]u8 = undefined,
    stun_error_len: usize = 0,
    stun_error: [64]u8 = undefined,
};
