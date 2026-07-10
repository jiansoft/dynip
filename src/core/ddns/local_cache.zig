const std = @import("std");
const c = @import("c");

const LocalDedupeEntry = struct {
    key: []u8,
    expires_at: i64,
};

var local_dedupe_mutex: std.atomic.Mutex = .unlocked;
var local_dedupe_entries: std.ArrayListUnmanaged(LocalDedupeEntry) = .empty;

const local_dedupe_shrink_min_capacity: usize = 32;
const local_dedupe_shrink_slack_factor: usize = 4;

fn currentUnixSeconds() i64 {
    return @intCast(c.time(null));
}

pub fn localDedupeContains(key: []const u8) bool {
    return localDedupeContainsAt(key, currentUnixSeconds());
}

pub fn localDedupeSet(key: []const u8, ttl_seconds: u64) !void {
    try localDedupeSetAt(key, ttl_seconds, currentUnixSeconds());
}

pub fn localDedupeContainsAt(key: []const u8, now_seconds: i64) bool {
    lockLocalDedupe();
    defer unlockLocalDedupe();

    pruneExpiredLocalDedupeLocked(now_seconds);

    for (local_dedupe_entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
}

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

fn maybeShrinkLocalDedupeLocked() void {
    const len = local_dedupe_entries.items.len;
    const capacity = local_dedupe_entries.capacity;
    if (capacity < local_dedupe_shrink_min_capacity) return;
    if (len != 0 and capacity < len * local_dedupe_shrink_slack_factor) return;

    local_dedupe_entries.shrinkAndFree(std.heap.page_allocator, len);
}

pub fn resetLocalDedupeState() void {
    lockLocalDedupe();
    defer unlockLocalDedupe();

    for (local_dedupe_entries.items) |entry| {
        std.heap.page_allocator.free(entry.key);
    }
    local_dedupe_entries.clearRetainingCapacity();
}

fn lockLocalDedupe() void {
    while (!local_dedupe_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

fn unlockLocalDedupe() void {
    local_dedupe_mutex.unlock();
}
