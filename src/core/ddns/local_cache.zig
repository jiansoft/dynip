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

/// 保護 entries 的鎖。ArrayList 不是 thread-safe，不能省略此鎖。
///
/// 用 `std.Io.Mutex` 而不是 `std.atomic.Mutex`：後者只提供 `tryLock`
/// （它的定位是「lock-free single-owner resource」），要當通用鎖用就得自己寫
/// `while (!tryLock()) yield()` 的忙等迴圈——競爭時空轉燒 CPU，且 `yield` 對
/// 排程器只是建議。`std.Io.Mutex` 的 `lock` 走 futex，等待中的執行緒會真的睡著，
/// 由 unlock 喚醒。本專案的 `io/logging.zig` 已經是這個用法。
var local_dedupe_mutex: std.Io.Mutex = .init;
/// 目前活著的本機去重項目；`std.ArrayList` 本身就是 unmanaged 版本，
/// 所以每次配置都要明確傳入 allocator。
var local_dedupe_entries: std.ArrayList(LocalDedupeEntry) = .empty;

/// 本快取自有資料使用的 allocator。
///
/// 先前用的是 `std.heap.page_allocator`：它每次配置都至少取一整個 page，而這裡
/// 配置的是 25 bytes 上下的 cache key，等於每筆浪費一個 page。`smp_allocator`
/// 是 thread-safe 的通用 allocator，適合這種「長壽命行程、小配置、多執行緒」的場景。
const cache_allocator = std.heap.smp_allocator;

/// 容量未達此值時不縮小，避免少量項目反覆 realloc。
const local_dedupe_shrink_min_capacity: usize = 32;
/// 容量大於實際長度此倍數時，清除過期資料後回收多餘記憶體。
const local_dedupe_shrink_slack_factor: usize = 4;

/// 取得目前 UTC Unix timestamp（秒）。此快取只需秒級 TTL，不需更精細時間。
fn currentUnixSeconds() i64 {
    return @intCast(c.time(null));
}

/// 以目前時間查詢 key 是否仍在有效期限內。
pub fn localDedupeContains(io: std.Io, key: []const u8) bool {
    return localDedupeContainsAt(io, key, currentUnixSeconds());
}

/// 以目前時間寫入或更新一筆 key；key 的內容會被複製並由本模組管理。
pub fn localDedupeSet(io: std.Io, key: []const u8, ttl_seconds: u64) !void {
    try localDedupeSetAt(io, key, ttl_seconds, currentUnixSeconds());
}

/// 可注入時間的查詢版本，主要讓單元測試不依賴系統時鐘。
pub fn localDedupeContainsAt(io: std.Io, key: []const u8, now_seconds: i64) bool {
    local_dedupe_mutex.lockUncancelable(io);
    defer local_dedupe_mutex.unlock(io);

    pruneExpiredLocalDedupeLocked(now_seconds);

    for (local_dedupe_entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
}

/// 可注入時間的寫入版本。若 key 已存在，只延長期限，不會重複配置 key。
pub fn localDedupeSetAt(io: std.Io, key: []const u8, ttl_seconds: u64, now_seconds: i64) !void {
    local_dedupe_mutex.lockUncancelable(io);
    defer local_dedupe_mutex.unlock(io);

    pruneExpiredLocalDedupeLocked(now_seconds);

    const expires_at = now_seconds + @as(i64, @intCast(ttl_seconds));
    for (local_dedupe_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.expires_at = expires_at;
            return;
        }
    }

    try local_dedupe_entries.append(cache_allocator, .{
        .key = try cache_allocator.dupe(u8, key),
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

        cache_allocator.free(local_dedupe_entries.items[index].key);
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

    local_dedupe_entries.shrinkAndFree(cache_allocator, len);
}

/// 清空全部項目，供測試或受控重設使用；保留 ArrayList 配置的容量以利重用。
pub fn resetLocalDedupeState(io: std.Io) void {
    local_dedupe_mutex.lockUncancelable(io);
    defer local_dedupe_mutex.unlock(io);

    for (local_dedupe_entries.items) |entry| {
        cache_allocator.free(entry.key);
    }
    local_dedupe_entries.clearRetainingCapacity();
}
