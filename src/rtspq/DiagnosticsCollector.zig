const std = @import("std");

const stdx = @import("stdx");
const Diagnostics = stdx.Diagnostics;

const DiagnosticsCollector = @This();

arena: std.mem.Allocator,
list: std.ArrayList(Item),

pub const Item = struct {
    level: Diagnostics.Level,
    message: []const u8,
};

/// arena must remain valid for lifetime of DiagnosticsCollector
pub fn init(arena: std.mem.Allocator) DiagnosticsCollector {
    const list = std.ArrayList(Item).initCapacity(arena, 8) catch @panic("oom");
    return .{
        .arena = arena,
        .list = list,
    };
}

pub fn diagnostics(self: *DiagnosticsCollector) Diagnostics {
    return .{
        .ptr = @ptrCast(self),
        .vtable = &.{
            .report = report,
        },
    };
}

fn report(ptr: *anyopaque, level: Diagnostics.Level, err: ?anyerror, message: []const u8) void {
    var self: *DiagnosticsCollector = @ptrCast(@alignCast(ptr));
    _ = err;
    self.list.append(self.arena, .{
        .level = level,
        .message = self.arena.dupe(u8, message) catch @panic("oom"),
    }) catch @panic("too many diagnostics");
}
