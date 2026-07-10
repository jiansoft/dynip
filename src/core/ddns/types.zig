//! DDNS 子模組共用的純資料型別。此檔不做網路或 I/O，方便各層交換狀態。
const std = @import("std");

/// 單次更新檢查的結果。
pub const RefreshStatus = enum {
    /// 至少一個供應商已成功更新，或已完成可接受的 reconcile。
    updated,
    /// public IP 已被本機/Redis 去重機制處理過，這輪不呼叫 DDNS API。
    skipped_cached_ip,
    /// 本地時間位於供應商維護保護時段，主動略過。
    skipped_maintenance_window,
};

/// 取得對外 IP 時，可能依序嘗試的來源站。
pub const PublicIpService = enum {
    /// 以 UDP STUN 協定詢問外網映射後位址。
    stun,
    /// 解析 Cloudflare trace 的 `ip=` 文字欄位。
    cloudflare_trace,
};

/// 單次對外 IP 查詢成功後的結果。
pub const PublicIpLookup = struct {
    /// 配置在呼叫端 allocator 的 IP 字串；使用完畢由其擁有者釋放。
    ip: []const u8,
    /// 本次成功查到 IP 的來源，供 dashboard/log 顯示。
    service: PublicIpService,
    /// STUN 失敗而由其他來源成功時，保留 STUN 的錯誤名稱作診斷；否則為 null。
    stun_error: ?[]const u8 = null,
};

/// 目前支援更新的 DDNS 供應商。
pub const DdnsProvider = enum {
    /// FreeDNS (afraid.org) 動態 DNS。
    afraid,
    /// Dynu 動態 DNS。
    dynu,
    /// No-IP 動態 DNS。
    noip,
};

/// 供應商成功狀態，用來決定哪些 provider 要寫回 Redis。
pub const ProviderSuccesses = struct {
    /// 本輪 Afraid 是否成功。
    afraid: bool = false,
    /// 本輪 Dynu 是否成功。
    dynu: bool = false,
    /// 本輪 No-IP 是否成功。
    noip: bool = false,

    /// 將指定 enum 對應的成功旗標設為 true。
    pub fn mark(self: *ProviderSuccesses, provider: DdnsProvider) void {
        switch (provider) {
            .afraid => self.afraid = true,
            .dynu => self.dynu = true,
            .noip => self.noip = true,
        }
    }

    /// 查詢指定 provider 在此集合中是否標記成功。
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
    /// 上一次已確認更新成功的 IP；尚無紀錄時為 null。
    current_ip: ?[]const u8 = null,
    /// 本輪希望供應商指向的 IP，即使更新失敗也會記錄。
    desired_ip: ?[]const u8 = null,
    /// 持久化狀態文字，通常是 `success` 或 `failed`；尚無紀錄時為 null。
    status: ?[]const u8 = null,
    /// 同一 desired IP 已連續失敗的次數，用來計算退避。
    retry_count: u32 = 0,
    /// Unix 秒；在此時刻前不重試同一個失敗目標。
    next_retry_at: i64 = 0,
};

/// provider 在這一輪是否應該打 DDNS API。
pub const ProviderAttemptDecision = enum {
    /// 應立刻呼叫 provider API。
    attempt,
    /// 持久化狀態已確認 provider 指向正確 IP。
    already_current,
    /// 上次失敗的重試退避時間尚未到期。
    retry_deferred,
};

/// 這一輪更新所有 DDNS 供應商後的統計結果。
pub const ServiceSummary = struct {
    /// 設定檔中啟用且憑證完整的 provider 數。
    configured: usize = 0,
    /// 本輪實際發出 HTTP 更新請求的數量。
    attempted: usize = 0,
    /// HTTP 更新成功的數量。
    succeeded: usize = 0,
    /// 已由狀態確認正確、無須請求的數量。
    already_current: usize = 0,
    /// 因 retry backoff 暫緩的數量。
    retry_deferred: usize = 0,
    /// 已嘗試但失敗的數量。
    failed: usize = 0,
    /// 逐 provider 的成功旗標，用於只寫回成功者的 cache。
    successes: ProviderSuccesses = .{},
};

/// 對外公開的 public IP 狀態快照。
pub const PublicIpSnapshot = struct {
    /// 是否至少已成功處理過一次 public IP。
    initialized: bool = false,
    /// buffer 中有效 IP 位元組數；不要將 undefined 的剩餘空間當字串讀取。
    len: usize = 0,
    /// 固定容量 IP 緩衝區，避免 dashboard 讀取時配置記憶體。
    buffer: [64]u8 = undefined,
    /// source 中的有效位元組數。
    source_len: usize = 0,
    /// 查詢來源名稱的固定緩衝區。
    source: [16]u8 = undefined,
    /// stun_error 中的有效位元組數，0 表示無 STUN fallback 錯誤。
    stun_error_len: usize = 0,
    /// STUN 錯誤名稱的固定緩衝區。
    stun_error: [64]u8 = undefined,

    /// 回傳僅涵蓋有效範圍的 IP slice；slice 借用 snapshot，不能比 snapshot 活得久。
    pub fn ipSlice(self: *const PublicIpSnapshot) []const u8 {
        return self.buffer[0..self.len];
    }

    /// 回傳實際寫入的來源名稱 slice。
    pub fn sourceSlice(self: *const PublicIpSnapshot) []const u8 {
        return self.source[0..self.source_len];
    }

    /// 回傳實際寫入的 STUN 錯誤名稱 slice，沒有錯誤時為空 slice。
    pub fn stunErrorSlice(self: *const PublicIpSnapshot) []const u8 {
        return self.stun_error[0..self.stun_error_len];
    }
};

/// 對外公開的 provider 狀態快照。
pub const ProviderSnapshot = struct {
    /// provider 固定名稱的儲存空間。
    name: [8]u8 = undefined,
    /// name 的有效長度。
    name_len: usize = 0,
    /// 是否曾為此 provider 寫入任何狀態。
    initialized: bool = false,

    /// 最近成功 IP 的儲存空間與有效長度。
    current_ip: [64]u8 = undefined,
    current_ip_len: usize = 0,
    /// 想更新到的 IP 的儲存空間與有效長度。
    desired_ip: [64]u8 = undefined,
    desired_ip_len: usize = 0,
    /// success/failed 狀態文字的儲存空間與有效長度。
    status: [16]u8 = undefined,
    status_len: usize = 0,

    /// 失敗重試計數與下一次允許嘗試的 Unix 秒。
    retry_count: u32 = 0,
    next_retry_at: i64 = 0,

    /// 最近錯誤名稱的儲存空間與有效長度。
    last_error: [128]u8 = undefined,
    last_error_len: usize = 0,
    /// 最後一次成功或失敗狀態寫入的 Unix 秒。
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
    /// 是否初始化過此 provider 的行程內狀態。
    initialized: bool = false,

    /// 上次成功 IP 的 buffer 與有效長度。
    current_ip: [64]u8 = undefined,
    current_ip_len: usize = 0,
    /// 目標 IP 的 buffer 與有效長度。
    desired_ip: [64]u8 = undefined,
    desired_ip_len: usize = 0,
    /// success/failed 狀態 buffer 與有效長度。
    status: [16]u8 = undefined,
    status_len: usize = 0,

    /// 連續失敗次數與下一次可重試時間。
    retry_count: u32 = 0,
    next_retry_at: i64 = 0,

    /// 最近錯誤名稱 buffer、有效長度與最後寫入時間。
    last_error: [128]u8 = undefined,
    last_error_len: usize = 0,
    updated_at: i64 = 0,
};

/// 同一個行程內最近一次成功處理過的 public IP。
pub const ProcessPublicIpState = struct {
    /// 保護本 struct 其餘欄位的 mutex；讀寫必須先 lock。
    mutex: std.atomic.Mutex = .unlocked,
    /// 是否已有最近一次成功處理的 IP。
    initialized: bool = false,
    /// buffer 的有效長度。
    len: usize = 0,
    /// 最近處理 IP 的固定儲存空間。
    buffer: [64]u8 = undefined,
    /// source 的有效長度與來源文字。
    source_len: usize = 0,
    source: [16]u8 = undefined,
    /// stun_error 的有效長度與錯誤文字。
    stun_error_len: usize = 0,
    stun_error: [64]u8 = undefined,
};
