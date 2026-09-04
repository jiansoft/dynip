//! Dashboard 展示資料整理層。
//!
//! 這個模組只讀取同一個 process 內的 DDNS snapshot，並把核心狀態轉成
//! Dashboard/API 需要的顯示狀態。不做網路 I/O，也不直接連 Redis。

const std = @import("std");
const config_mod = @import("../base/config.zig");
const ddns = @import("../core/ddns.zig");
const c = @import("c");

/// Dashboard 顯示用狀態。
///
/// 這裡的 enum 是「UI 狀態」，不是 provider 原始狀態。
/// DDNS core 目前主要寫入 `"success"` / `"failed"` 字串；
/// Dashboard 會再結合 initialized、next_retry_at、enabled 等欄位，
/// 轉成更適合畫面呈現的狀態。
pub const DisplayStatus = enum {
    /// 服務剛啟動，該 provider 尚未完成第一輪更新。
    initializing,
    /// provider 已成功更新，current_ip 與 desired_ip 一致。
    success,
    /// provider 更新失敗，且目前已可重試或沒有 backoff。
    failed,
    /// provider 更新失敗，但還在 retry backoff 等待時間內。
    retry_deferred,
    /// provider 有目標 IP，但 current_ip 尚未收斂到 desired_ip。
    updating,
    /// app.json 中該 provider 被停用。
    disabled,
};

/// 單一 provider 的展示資料。
///
/// `snapshot` 是 DDNS core 的原始快照；`display_status` 是 Dashboard
/// 依規則轉換後的狀態；`enabled` 則直接來自 AppConfig，方便前端顯示。
pub const ProviderDisplayData = struct {
    snapshot: ddns.ProviderSnapshot,
    display_status: DisplayStatus,
    enabled: bool,
};

/// 從 process-level DDNS snapshot 與 AppConfig 組出 Dashboard 展示資料。
pub fn readDisplayData(io: std.Io, config: config_mod.AppConfig) [8]ProviderDisplayData {
    // ddns.getProviderSnapshots() 以「provider、family」排列固定八格：
    // [0..1] cloudflare、[2..3] afraid、[4..5] dynu、[6..7] noip；
    // 每一對的偶數索引是 IPv4/A，奇數索引是 IPv6/AAAA。
    const snapshots = ddns.getProviderSnapshots(io);
    // 狀態分類需要拿現在時間，才能判斷 next_retry_at 是否還在未來。
    const now = currentUnixSeconds();

    // 每個 provider 的 enabled 旗標來自 app.json。
    // 即使 snapshot 裡有資料，只要 provider 設成 disabled，UI 就顯示 disabled。
    // 必須保留這個配對順序。Dashboard server 以每兩筆資料組成一張 provider 卡片，
    // 因此不能在這裡依狀態排序，否則 A 與 AAAA 可能被錯誤配到不同 provider。
    return .{
        buildDisplayData(snapshots[0], config.cloudflare.enabled, now),
        buildDisplayData(snapshots[1], config.cloudflare.enabled, now),
        buildDisplayData(snapshots[2], config.afraid.enabled, now),
        buildDisplayData(snapshots[3], config.afraid.enabled, now),
        buildDisplayData(snapshots[4], config.dynu.enabled, now),
        buildDisplayData(snapshots[5], config.dynu.enabled, now),
        buildDisplayData(snapshots[6], config.noip.enabled, now),
        buildDisplayData(snapshots[7], config.noip.enabled, now),
    };
}

/// 從三個 provider snapshot 中選出最新可顯示的 public IP。
///
/// 優先使用最新的 desired_ip；若該 provider 沒有 desired_ip，才退回 current_ip。
/// 回傳 slice 指向呼叫端傳入的 snapshots，呼叫端需確保 snapshots 生命週期足夠。
pub fn resolveDesiredIp(snapshots: *const [8]ddns.ProviderSnapshot) []const u8 {
    // `best_index` 記錄目前找到的最佳 provider index。
    // 用 optional 是因為剛啟動時可能完全沒有任何有效快照。
    var best_index: ?usize = null;
    // Unix timestamp 越大代表越新。
    var best_updated_at: i64 = std.math.minInt(i64);

    for (snapshots, 0..) |snapshot, index| {
        // 尚未初始化的 provider 不拿來顯示 public IP。
        if (!snapshot.initialized) continue;
        // 沒有 desired/current IP 的 provider 也跳過。
        if (snapshot.desired_ip_len == 0 and snapshot.current_ip_len == 0) continue;
        // 挑 updated_at 最新的一筆。若時間相同，後面的 provider 會覆蓋前面。
        if (best_index == null or snapshot.updated_at >= best_updated_at) {
            best_index = index;
            best_updated_at = snapshot.updated_at;
        }
    }

    // 沒有任何可用 snapshot，就回空字串，UI 會顯示 `-`。
    const index = best_index orelse return "";
    const snapshot = &snapshots[index];
    // desired_ip 代表本輪目標 public IP，優先顯示它。
    if (snapshot.desired_ip_len != 0) return snapshot.desiredIpSlice();
    // 若 desired_ip 尚未寫入，退回最後成功的 current_ip。
    return snapshot.currentIpSlice();
}

/// 根據 snapshot 欄位值判斷 Dashboard 顯示狀態。
pub fn classifyDisplayStatus(
    snap: ddns.ProviderSnapshot,
    now_seconds: i64,
) DisplayStatus {
    // 第一輪更新尚未寫入任何資料，顯示 initializing。
    if (!snap.initialized) return .initializing;
    // 防禦性判斷：已 initialized 但 status 空字串，也當作初始化中。
    if (snap.status_len == 0) return .initializing;

    // 成功且 current/desired 一致，代表 DDNS provider 已收斂。
    if (std.mem.eql(u8, snap.statusSlice(), "success") and
        std.mem.eql(u8, snap.currentIpSlice(), snap.desiredIpSlice()))
    {
        return .success;
    }

    // 失敗但 next_retry_at 還在未來，代表 retry backoff 中。
    if (std.mem.eql(u8, snap.statusSlice(), "failed") and snap.next_retry_at > now_seconds) {
        return .retry_deferred;
    }

    // 失敗且已不在 backoff 等待時間內。
    if (std.mem.eql(u8, snap.statusSlice(), "failed")) return .failed;

    // 不是 failed，但 desired/current 不一致，代表仍在更新收斂中。
    if (!std.mem.eql(u8, snap.desiredIpSlice(), snap.currentIpSlice())) {
        return .updating;
    }

    // 其他已初始化狀態保守視為 success，避免 UI 卡在 unknown。
    return .success;
}

/// 把單一 snapshot + enabled flag 包成 ProviderDisplayData。
fn buildDisplayData(
    snapshot: ddns.ProviderSnapshot,
    enabled: bool,
    now_seconds: i64,
) ProviderDisplayData {
    return .{
        .snapshot = snapshot,
        .display_status = if (enabled) classifyDisplayStatus(snapshot, now_seconds) else .disabled,
        .enabled = enabled,
    };
}

/// 取得 Unix timestamp 秒數。
///
/// 專案目前已經透過 C import 使用 `time()`；這裡沿用同一套方式，
/// 避免依賴 Zig 0.17 已移除/變動中的 `std.time.timestamp()`。
fn currentUnixSeconds() i64 {
    return @intCast(c.time(null));
}

/// 測試用：快速建立 ProviderSnapshot。
///
/// 正式程式不會呼叫這個 helper；它只讓下方單元測試不用手動填固定 buffer。
fn testSnapshot(
    initialized: bool,
    current_ip: []const u8,
    desired_ip: []const u8,
    status: []const u8,
    retry_count: u32,
    next_retry_at: i64,
    updated_at: i64,
) ddns.ProviderSnapshot {
    var snapshot = ddns.ProviderSnapshot{
        .initialized = initialized,
        .retry_count = retry_count,
        .next_retry_at = next_retry_at,
        .updated_at = updated_at,
    };
    copyTestField(&snapshot.current_ip, &snapshot.current_ip_len, current_ip);
    copyTestField(&snapshot.desired_ip, &snapshot.desired_ip_len, desired_ip);
    copyTestField(&snapshot.status, &snapshot.status_len, status);
    return snapshot;
}

/// 測試用：把 slice 複製進 ProviderSnapshot 的固定 buffer。
fn copyTestField(buffer: anytype, len: *usize, value: []const u8) void {
    const copy_len = @min(buffer.len, value.len);
    if (copy_len != 0) @memcpy(buffer[0..copy_len], value[0..copy_len]);
    len.* = copy_len;
}

test "classify display status covers dashboard states" {
    try std.testing.expectEqual(
        DisplayStatus.initializing,
        classifyDisplayStatus(testSnapshot(false, "", "", "", 0, 0, 0), 100),
    );
    try std.testing.expectEqual(
        DisplayStatus.success,
        classifyDisplayStatus(testSnapshot(true, "1.2.3.4", "1.2.3.4", "success", 0, 0, 100), 100),
    );
    try std.testing.expectEqual(
        DisplayStatus.retry_deferred,
        classifyDisplayStatus(testSnapshot(true, "1.2.3.4", "5.6.7.8", "failed", 2, 200, 100), 100),
    );
    try std.testing.expectEqual(
        DisplayStatus.failed,
        classifyDisplayStatus(testSnapshot(true, "1.2.3.4", "5.6.7.8", "failed", 2, 100, 100), 100),
    );
    try std.testing.expectEqual(
        DisplayStatus.updating,
        classifyDisplayStatus(testSnapshot(true, "1.2.3.4", "5.6.7.8", "success", 0, 0, 100), 100),
    );
}

test "build display data marks disabled providers" {
    const data = buildDisplayData(
        testSnapshot(true, "1.2.3.4", "1.2.3.4", "success", 0, 0, 100),
        false,
        100,
    );

    try std.testing.expect(!data.enabled);
    try std.testing.expectEqual(DisplayStatus.disabled, data.display_status);
}

test "resolve desired ip returns latest initialized provider ip" {
    var snapshots = [_]ddns.ProviderSnapshot{
        testSnapshot(true, "1.1.1.1", "2.2.2.2", "success", 0, 0, 100),
        testSnapshot(false, "", "", "", 0, 0, 0),
        testSnapshot(true, "3.3.3.3", "4.4.4.4", "failed", 1, 200, 150),
        testSnapshot(false, "", "", "", 0, 0, 0),
        testSnapshot(false, "", "", "", 0, 0, 0),
        testSnapshot(false, "", "", "", 0, 0, 0),
        testSnapshot(false, "", "", "", 0, 0, 0),
        testSnapshot(false, "", "", "", 0, 0, 0),
    };

    try std.testing.expectEqualStrings("4.4.4.4", resolveDesiredIp(&snapshots));
}
