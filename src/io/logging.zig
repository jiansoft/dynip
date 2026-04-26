//! 檔案日誌模組 (Zig 0.16 現代化版本)。
//!
//! 本模組採用 Zig 0.16 新的 `std.Io` 體系實作：
//! - 採用系統原生追加模式並配合 `seekTo` 確保寫入位置。
//! - 整合 `std.Io.Mutex` 處理併發寫入。
//! - 採用 Zig 0.16 官方推薦的 `callconv(.winapi)` 方式呼叫 Win32 API。

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("time.h");
});

pub const default_log_dir = "log";
pub const default_log_name = "dynip";
const default_max_age_days: i64 = 7;

/// 確保日誌目錄存在。
fn ensureLogDir(io: std.Io) !void {
    std.Io.Dir.cwd().createDir(io, default_log_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

const LocalDateTime = struct {
    unix_seconds: i64,
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// 檔案輪替管理。
const Rotate = struct {
    level_name: []const u8,
    current_year: i32 = 0,
    current_month: u8 = 0,
    current_day: u8 = 0,
    file: ?std.Io.File = null,
    path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,

    fn init(level_name: []const u8) Rotate {
        return .{ .level_name = level_name };
    }

    fn deinit(self: *Rotate, io: std.Io) void {
        if (self.file) |file| {
            file.close(io);
            self.file = null;
        }
    }

    fn writeLine(
        self: *Rotate,
        io: std.Io,
        now: LocalDateTime,
        level: std.log.Level,
        scope_name: ?[]const u8,
        message: []const u8,
    ) !void {
        try self.ensureReady(io, now);

        var line_buffer: [8192]u8 = undefined;
        const line = try formatLogLine(&line_buffer, now, level, scope_name, message);

        if (self.file) |file| {
            // 在 Zig 0.16 中使用 writeStreamingAll，保證寫入完整。
            try file.writeStreamingAll(io, line);
        }
    }

    fn ensureReady(self: *Rotate, io: std.Io, now: LocalDateTime) !void {
        const day_changed = self.file == null or
            self.current_year != now.year or
            self.current_month != now.month or
            self.current_day != now.day;

        if (day_changed) {
            self.current_year = now.year;
            self.current_month = now.month;
            self.current_day = now.day;
            try self.openCurrentFile(io, now);
            self.cleanupOldFiles(io, now);
        }
    }

    fn openCurrentFile(self: *Rotate, io: std.Io, now: LocalDateTime) !void {
        self.deinit(io);
        try ensureLogDir(io);

        const path = try self.buildCurrentPath(now);

        // 打開檔案並確保指標在末尾。
        var file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = false,
        });

        const size = file.length(io) catch 0;
        var seek_buffer: [64]u8 = undefined;
        var writer = file.writerStreaming(io, &seek_buffer);
        try writer.seekTo(size);
        try writer.flush();

        self.file = file;
    }

    fn buildCurrentPath(self: *Rotate, now: LocalDateTime) ![]const u8 {
        return std.fmt.bufPrint(
            &self.path_buffer,
            "{s}/{d:0>4}-{d:0>2}-{d:0>2}_{s}_{s}.log",
            .{ default_log_dir, now.year, now.month, now.day, default_log_name, self.level_name },
        );
    }

    fn cleanupOldFiles(self: *Rotate, io: std.Io, now: LocalDateTime) void {
        _ = self;
        var dir = std.Io.Dir.cwd().openDir(io, default_log_dir, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        const cutoff = now.unix_seconds - (default_max_age_days * 24 * 60 * 60);

        while (iter.next(io) catch return) |entry| {
            if (entry.kind != .file) continue;
            const stat = dir.statFile(io, entry.name, .{}) catch continue;
            if (stat.mtime.toSeconds() > cutoff) continue;

            dir.deleteFile(io, entry.name) catch {};
        }
    }
};

const Logger = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    info_rotate: Rotate = Rotate.init("info"),
    warn_rotate: Rotate = Rotate.init("warn"),
    error_rotate: Rotate = Rotate.init("error"),
    debug_rotate: Rotate = Rotate.init("debug"),

    fn deinit(self: *Logger) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.info_rotate.deinit(self.io);
        self.warn_rotate.deinit(self.io);
        self.error_rotate.deinit(self.io);
        self.debug_rotate.deinit(self.io);
    }

    fn rotateForLevel(self: *Logger, level: std.log.Level) *Rotate {
        return switch (level) {
            .info => &self.info_rotate,
            .warn => &self.warn_rotate,
            .err => &self.error_rotate,
            .debug => &self.debug_rotate,
        };
    }

    fn writeRendered(
        self: *Logger,
        level: std.log.Level,
        scope_name: ?[]const u8,
        message: []const u8,
    ) void {
        const now = localNow() catch return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const rotate = self.rotateForLevel(level);
        rotate.writeLine(self.io, now, level, scope_name, message) catch {};
    }
};

var global_logger: ?Logger = null;

pub fn init(io: std.Io) !void {
    if (global_logger != null) return;
    try ensureLogDir(io);
    global_logger = .{ .io = io };
}

pub fn deinit() void {
    if (global_logger) |*logger| {
        logger.deinit();
        global_logger = null;
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var message_buffer: [4096]u8 = undefined;
    const rendered = std.fmt.bufPrint(&message_buffer, format, args) catch "<msg toolong>";

    const scope_name = if (scope == .default) null else @tagName(scope);

    if (global_logger) |*logger| {
        logger.writeRendered(level, scope_name, rendered);
    }

    writeRenderedToConsole(level, scope_name, rendered);
}

pub fn infoFile(message: []const u8) void {
    writeDirect(.info, null, message);
}
pub fn warnFile(message: []const u8) void {
    writeDirect(.warn, null, message);
}
pub fn errorFile(message: []const u8) void {
    writeDirect(.err, null, message);
}

fn writeDirect(level: std.log.Level, scope_name: ?[]const u8, message: []const u8) void {
    if (global_logger) |*logger| logger.writeRendered(level, scope_name, message);
}

pub fn errorConsoleFmt(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch "<err>";
    const now = localNow() catch return;
    std.debug.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} error: {s}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, text });
}

fn writeRenderedToConsole(
    level: std.log.Level,
    scope_name: ?[]const u8,
    message: []const u8,
) void {
    const now = localNow() catch return;
    const timestamp_fmt = "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}";

    if (scope_name) |scope_text| {
        std.debug.print(timestamp_fmt ++ " {s}({s}) {s}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, levelText(level), scope_text, message });
    } else {
        std.debug.print(timestamp_fmt ++ " {s} {s}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, levelText(level), message });
    }
}

fn formatLogLine(
    buffer: []u8,
    now: LocalDateTime,
    level: std.log.Level,
    scope_name: ?[]const u8,
    message: []const u8,
) ![]const u8 {
    const timestamp_fmt = "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}";
    return if (scope_name) |scope_text|
        std.fmt.bufPrint(buffer, timestamp_fmt ++ " {s}({s}) {s}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, levelText(level), scope_text, message })
    else
        std.fmt.bufPrint(buffer, timestamp_fmt ++ " {s} {s}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second, levelText(level), message });
}

fn levelText(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
}

fn localNow() !LocalDateTime {
    if (builtin.os.tag == .windows) {
        const SYSTEMTIME = extern struct {
            wYear: u16,
            wMonth: u16,
            wDayOfWeek: u16,
            wDay: u16,
            wHour: u16,
            wMinute: u16,
            wSecond: u16,
            wMilliseconds: u16,
        };

        // 在 Zig 0.16 中直接使用內建的 .winapi 呼叫慣例
        const kernel32 = struct {
            extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
        };

        var st: SYSTEMTIME = undefined;
        kernel32.GetLocalTime(&st);
        const unix_time: c.time_t = c.time(null);

        return .{
            .unix_seconds = @intCast(unix_time),
            .year = st.wYear,
            .month = @intCast(st.wMonth),
            .day = @intCast(st.wDay),
            .hour = @intCast(st.wHour),
            .minute = @intCast(st.wMinute),
            .second = @intCast(st.wSecond),
        };
    } else {
        var unix_time: c.time_t = c.time(null);
        var local_tm: c.struct_tm = undefined;
        _ = c.localtime_r(&unix_time, &local_tm) orelse return error.LocalTimeUnavailable;
        return .{
            .unix_seconds = @intCast(unix_time),
            .year = local_tm.tm_year + 1900,
            .month = @intCast(local_tm.tm_mon + 1),
            .day = @intCast(local_tm.tm_mday),
            .hour = @intCast(local_tm.tm_hour),
            .minute = @intCast(local_tm.tm_min),
            .second = @intCast(local_tm.tm_sec),
        };
    }
}
