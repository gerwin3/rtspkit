const std = @import("std");

pub const BitReader = @This();

reader: *std.Io.Reader,
cur: u8 = 0,
pos: u3 = 0,

pub inline fn readBit(self: *BitReader) std.Io.Reader.Error!u1 {
    @setRuntimeSafety(false);
    if (self.pos == 0) self.cur = try self.reader.takeByte();
    defer self.pos +%= 1;
    return @intCast((self.cur >> (7 - self.pos)) & 1);
}

pub inline fn readBits(self: *BitReader, comptime T: type) std.Io.Reader.Error!T {
    @setRuntimeSafety(false);
    var value: T = 0;
    inline for (0..@bitSizeOf(T)) |_| value = ((value << 1) | (try self.readBit()));
    return value;
}

pub inline fn readByte(self: *BitReader) std.Io.Reader.Error!u8 {
    return self.readBits(u8);
}

pub inline fn readBytes(self: *BitReader, count: comptime_int) std.Io.Reader.Error![count]u8 {
    var bytes: [count]u8 = undefined;
    for (&bytes) |*byte| byte.* = try self.readByte();
    return bytes;
}

pub inline fn readExpGolomb(self: *BitReader) std.Io.Reader.Error!u32 {
    var leading_zero_bits: u6 = 0;
    while (try self.readBit() == 0) leading_zero_bits +|= 1;
    var suffix: u32 = 0;
    for (0..leading_zero_bits) |_| suffix = (suffix << 1) | @as(u32, try self.readBit());
    if (leading_zero_bits == 0) return 0;
    return ((@as(u32, 1) << @intCast(leading_zero_bits)) - 1) + suffix;
}

pub inline fn readExpGolombSigned(self: *BitReader) std.Io.Reader.Error!i32 {
    const val = try self.readExpGolomb();
    const magnitude: i32 = @intCast((val + 1) >> 1);
    return if (val & 0x0001 == 1) magnitude else -magnitude;
}

pub inline fn skipBit(self: *BitReader) std.Io.Reader.Error!void {
    _ = try self.readBit();
}

pub inline fn skipBits(self: *BitReader, count: usize) std.Io.Reader.Error!void {
    for (0..count) |_| try self.skipBit();
}

pub inline fn skipByte(self: *BitReader) std.Io.Reader.Error!void {
    return self.skipBits(8);
}

pub inline fn skipBytes(self: *BitReader, count: usize) std.Io.Reader.Error!void {
    for (0..count) |_| try self.skipByte();
}

pub inline fn skipExpGolomb(self: *BitReader) std.Io.Reader.Error!void {
    var leading_zero_bits: u6 = 0;
    while (try self.readBit() == 0) leading_zero_bits +|= 1;
    for (0..leading_zero_bits) |_| try self.skipBit();
}

pub inline fn skipExpGolombs(self: *BitReader, count: usize) std.Io.Reader.Error!void {
    for (0..count) |_| try self.skipExpGolomb();
}

test "readBit reads bits MSB-first" {
    var data = std.Io.Reader.fixed(&.{0b1011_0010});
    var reader = BitReader{ .reader = &data };
    try std.testing.expectEqual(1, try reader.readBit());
    try std.testing.expectEqual(0, try reader.readBit());
    try std.testing.expectEqual(1, try reader.readBit());
    try std.testing.expectEqual(1, try reader.readBit());
    try std.testing.expectEqual(0, try reader.readBit());
    try std.testing.expectEqual(0, try reader.readBit());
    try std.testing.expectEqual(1, try reader.readBit());
    try std.testing.expectEqual(0, try reader.readBit());
}

test "readBits reads multiple bits from one byte" {
    var data = std.Io.Reader.fixed(&.{0b1011_0010});
    var reader = BitReader{ .reader = &data };
    try std.testing.expectEqual(0b101, try reader.readBits(u3));
    try std.testing.expectEqual(0b10010, try reader.readBits(u5));
}

test "readBits crosses byte boundary" {
    var data = std.Io.Reader.fixed(&.{ 0b1011_0010, 0b0110_1111 });
    var reader = BitReader{ .reader = &data };
    try std.testing.expectEqual(0b1011, try reader.readBits(u4));
    try std.testing.expectEqual(0b0010_0110, try reader.readBits(u8));
    try std.testing.expectEqual(0b1111, try reader.readBits(u4));
}

test "readBit returns EndOfStream after input exhausted" {
    var data = std.Io.Reader.fixed(&.{0b0000_0000});
    var reader = BitReader{ .reader = &data };
    for (0..8) |_| _ = try reader.readBit();
    try std.testing.expectError(error.EndOfStream, reader.readBit());
}

test "readExpGolomb decodes consecutive values across byte boundaries" {
    var data = std.Io.Reader.fixed(&.{ 0b1010_0110, 0b0100_0010, 0b1000_0000 });
    var reader = BitReader{ .reader = &data };
    try std.testing.expectEqual(0, try reader.readExpGolomb());
    try std.testing.expectEqual(1, try reader.readExpGolomb());
    try std.testing.expectEqual(2, try reader.readExpGolomb());
    try std.testing.expectEqual(3, try reader.readExpGolomb());
    try std.testing.expectEqual(4, try reader.readExpGolomb());
}

test "readExpGolomb decodes the largest valid u32 value" {
    var data = std.Io.Reader.fixed(&.{ 0x00, 0x00, 0x00, 0x01, 0xff, 0xff, 0xff, 0xfe });
    var reader = BitReader{ .reader = &data };
    try std.testing.expectEqual(0xffff_fffe, try reader.readExpGolomb());
}

test "readExpGolomb returns EndOfStream for truncated prefix" {
    var data = std.Io.Reader.fixed(&.{0x00});
    var reader = BitReader{ .reader = &data };
    try std.testing.expectError(error.EndOfStream, reader.readExpGolomb());
}
