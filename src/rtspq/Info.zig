const std = @import("std");

const media = @import("media");
const Codec = media.Codec;

const Dimensions = @import("Dimensions.zig");
const Rational = @import("Rational.zig");

const Info = @This();

codec: Codec,
profile: []const u8,
dimensions: Dimensions,
frame_rate: ?Rational = null,

pub inline fn frame_rate_f32(self: *const Info) ?f32 {
    return if (self.frame_rate) |frame_rate| @as(f32, @floatFromInt(frame_rate.num)) / @as(f32, @floatFromInt(frame_rate.den)) else null;
}
