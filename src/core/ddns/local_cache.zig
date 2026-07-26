//! Redis 無法使用時的行程內去重快取。所有共享資料都必須在 mutex 保護下讀寫。
const std = @import("std");
const c = @import("c");

/// 一筆快取項目。key 擁有一份 heap 複本，必須在移除或 reset 時手動釋放。
const LocalDedupeEntry = struct {
    /// 用來辨識某個已處理 public IP 的 cache key。
    key: []u8,
    /// Unix 時間秒；`now >= expires_at` 時此項目失效。
    expires_at: i64,
};

/// 保護 entries 的自旋鎖。ArrayList 不是 thread-safe，不能省略此鎖。
var local_dedupe_mutex: std.atomic.Mutex = .unlocked;
/// 目前活著的本機去重項目；`std.ArrayList` 本身就是 unmanaged 版本，
/// 所以每次配置都要明確傳入 allocator。
var local_dedupe_entries: std.ArrayList(LocalDedupeEntry) = .empty;

/// 容量未達此值時不縮小，避免少量項目反覆 realloc。
const local_dedupe_shrink_min_capacity: usize = 32;
/// 容量大於實際長度此倍數時，清除過期資料後回收多餘記憶體。
const local_dedupe_shrink_slack_factor: usize = 4;

/// 取得目前 UTC Unix timestamp（秒）。此快取只需秒級 TTL，不需更精細時間。
fn currentUnixSeconds() i64 {
    return @intCast(c.time(null));
}

/// 以目前時間查詢 key 是否仍在有效期限內。
pub fn localDedupeContains(key: []const u8) bool {
    return localDedupeContainsAt(key, currentUnixSeconds());
}

/// 以目前時間寫入或更新一筆 key；key 的內容會被複製並由本模組管理。
pub fn localDedupeSet(key: []const u8, ttl_seconds: u64) !void {
    try localDedupeSetAt(key, ttl_seconds, currentUnixSeconds());
}

/// 可注入時間的查詢版本，主要讓單元測試不依賴系統時鐘。
pub fn localDedupeContainsAt(key: []const u8, now_seconds: i64) bool {
    lockLocalDedupe();
    defer unlockLocalDedupe();

    pruneExpiredLocalDedupeLocked(now_seconds);

    for (local_dedupe_entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
}

/// 可注入時間的寫入版本。若 key 已存在，只延長期限，不會重複配置 key。
pub fn localDedupeSetAt(key: []const u8, ttl_seconds: u64, now_seconds: i64) !void {
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

/// 在已持有 mutex 的前提下移除到期項目並釋放它們擁有的 key。
/// `orderedRemove` 會保持其他元素順序，因此移除後不增加 index，改檢查移入的位置。
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

/// 在已持有 mutex 的前提下，於資料大量過期後釋放 ArrayList 過大的容量。
fn maybeShrinkLocalDedupeLocked() void {
    const len = local_dedupe_entries.items.len;
    const capacity = local_dedupe_entries.capacity;
    if (capacity < local_dedupe_shrink_min_capacity) return;
    if (len != 0 and capacity < len * local_dedupe_shrink_slack_factor) return;

    local_dedupe_entries.shrinkAndFree(std.heap.page_allocator, len);
}

/// 清空全部項目，供測試或受控重設使用；保留 ArrayList 配置的容量以利重用。
pub fn resetLocalDedupeState() void {
    lockLocalDedupe();
    defer unlockLocalDedupe();

    for (local_dedupe_entries.items) |entry| {
        std.heap.page_allocator.free(entry.key);
    }
    local_dedupe_entries.clearRetainingCapacity();
}

/// 以 tryLock + yield 實作簡單自旋鎖。等待時讓出 CPU，避免忙等完全占滿核心。
fn lockLocalDedupe() void {
    while (!local_dedupe_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

/// 配對 lockLocalDedupe；必須只在成功取得鎖後呼叫。
fn unlockLocalDedupe() void {
    local_dedupe_mutex.unlock();
}
