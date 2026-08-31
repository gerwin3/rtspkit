const std = @import("std");

pub const Diagnostics = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const Level = enum {
    incident,
    err,
    warn,
    info,
    dbg,
};

pub const VTable = struct {
    report: *const fn (ptr: *anyopaque, level: Level, err: ?anyerror, message: []const u8) void,
};

pub const discarding: Diagnostics = .{
    .ptr = undefined,
    .vtable = &.{
        .report = discard,
    },
};

pub fn report(self: Diagnostics, level: Level, err: ?anyerror, comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, fmt, args) catch @panic("Diagnostics.report: message too long");
    self.vtable.report(self.ptr, level, err, message);
}

fn discard(ptr: *anyopaque, level: Level, err: ?anyerror, message: []const u8) void {
    _ = ptr;
    _ = level;
    _ = err;
    _ = message;
}
