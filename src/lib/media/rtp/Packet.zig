const std = @import("std");

pub const Packet = @This();

version: Version,
marker: bool,
payload_type: u8,
sequence_number: u16,
timestamp: u32,
ssrc: u32,
csrc: [std.math.maxInt(u4)]u32,
payload: []const u8,

pub const Version = enum(u2) {
    @"2" = 2,
    _,
};

pub const ParseError = error{Malformed};

pub fn parse(data: []const u8) ParseError!Packet {
    if (data.len == 0) return ParseError.Malformed;

    var reader = std.Io.Reader.fixed(data);

    const header1 = reader.takeStruct(packed struct {
        csrc_count: u4,
        extension: bool,
        padding: bool,
        version: Version,
    }, .big) catch return ParseError.Malformed;
    const header2 = reader.takeStruct(packed struct {
        payload_type: u7,
        marker: bool,
    }, .big) catch return ParseError.Malformed;
    const sequence_number = reader.takeInt(u16, .big) catch return ParseError.Malformed;
    const timestamp = reader.takeInt(u32, .big) catch return ParseError.Malformed;
    const ssrc = reader.takeInt(u32, .big) catch return ParseError.Malformed;

    var csrc: [std.math.maxInt(u4)]u32 = undefined;
    for (0..header1.csrc_count) |i| csrc[i] = reader.takeInt(u32, .big) catch return ParseError.Malformed;

    // skip extension
    if (header1.extension) {
        // ext_profile_identifier
        _ = reader.takeInt(u16, .big) catch return ParseError.Malformed;
        const ext_len = reader.takeInt(u16, .big) catch return ParseError.Malformed;
        _ = reader.take(@sizeOf(u32) * ext_len) catch return ParseError.Malformed;
    }

    var payload = data[reader.seek..];
    if (header1.padding) {
        if (payload.len == 0) return ParseError.Malformed;

        const padding_len: usize = payload[payload.len - 1];
        if (padding_len > payload.len) return ParseError.Malformed;
        payload = payload[0 .. payload.len - padding_len];
    }

    return .{
        .version = header1.version,
        .marker = header2.marker,
        .payload_type = header2.payload_type,
        .sequence_number = sequence_number,
        .timestamp = timestamp,
        .ssrc = ssrc,
        .csrc = csrc,
        .payload = payload,
    };
}

test "empty" {
    try std.testing.expectError(ParseError.Malformed, Packet.parse(&.{}));
}

test "basic" {
    try expect_equal_packet_no_csrc(
        Packet{
            .version = .@"2",
            .marker = true,
            .payload_type = 96,
            .sequence_number = 27023,
            .timestamp = 3653407706,
            .ssrc = 476325762,
            .csrc = undefined,
            .payload = &.{ 0x98, 0x36, 0xbe, 0x88, 0x9e },
        },
        try Packet.parse(&.{
            0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82, 0x00, 0x01, 0x00,
            0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x98, 0x36, 0xbe, 0x88, 0x9e,
        }),
    );
}

test "padding" {
    try expect_equal_packet_no_csrc(
        Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 96,
            .sequence_number = 6488,
            .timestamp = 1677688188,
            .ssrc = 1268306954,
            .csrc = undefined,
            .payload = &.{
                0x67, 0x4d, 0x00, 0x29, 0x9a, 0x64, 0x03, 0xc0, 0x11, 0x3f, 0x2c, 0xd4, 0x04, 0x04,
                0x05, 0x00, 0x00, 0x03, 0x03, 0xe8, 0x00, 0x00, 0xea, 0x60, 0x04,
            },
        },
        try Packet.parse(&.{
            0xa0, 0x60, 0x19, 0x58, 0x63, 0xff, 0x7d, 0x7c, 0x4b, 0x98, 0xd4, 0x0a, 0x67, 0x4d, 0x00,
            0x29, 0x9a, 0x64, 0x03, 0xc0, 0x11, 0x3f, 0x2c, 0xd4, 0x04, 0x04, 0x05, 0x00, 0x00, 0x03,
            0x03, 0xe8, 0x00, 0x00, 0xea, 0x60, 0x04, 0x00, 0x00, 0x03,
        }),
    );
}

test "rfc 8285 one byte extension" {
    try expect_equal_packet_no_csrc(
        Packet{
            .version = .@"2",
            .marker = true,
            .payload_type = 96,
            .sequence_number = 27023,
            .timestamp = 3653407706,
            .ssrc = 476325762,
            .csrc = undefined,
            .payload = &.{ 0x98, 0x36, 0xbe, 0x88, 0x9e },
        },
        try Packet.parse(&.{
            0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82, 0xBE, 0xDE, 0x00,
            0x01, 0x50, 0xAA, 0x00, 0x00, 0x98, 0x36, 0xbe, 0x88, 0x9e,
        }),
    );
}

test "rfc 8285 one byte two extension of two bytes" {
    try expect_equal_packet_no_csrc(
        Packet{
            .version = .@"2",
            .marker = true,
            .payload_type = 96,
            .sequence_number = 27023,
            .timestamp = 3653407706,
            .ssrc = 476325762,
            .csrc = undefined,
            .payload = &.{ 0x98, 0x36, 0xbe, 0x88, 0x9e },
        },
        try Packet.parse(&.{
            0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82, 0xBE, 0xDE, 0x00,
            0x01, 0x10, 0xAA, 0x20, 0xBB, 0x98, 0x36, 0xbe, 0x88, 0x9e,
        }),
    );
}

test "rfc 8285 one byte multiple extensions with padding" {
    try expect_equal_packet_no_csrc(
        Packet{
            .version = .@"2",
            .marker = true,
            .payload_type = 96,
            .sequence_number = 27023,
            .timestamp = 3653407706,
            .ssrc = 476325762,
            .csrc = undefined,
            .payload = &.{ 0x98, 0x36, 0xbe, 0x88, 0x9e },
        },
        try Packet.parse(&.{
            0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82, 0xBE, 0xDE, 0x00,
            0x03, 0x10, 0xAA, 0x21, 0xBB, 0xBB, 0x00, 0x00, 0x33, 0xCC, 0xCC, 0xCC, 0xCC, 0x98, 0x36,
            0xbe, 0x88, 0x9e,
        }),
    );
}

test "rfc 8285 one byte multiple extension" {
    try expect_equal_packet_no_csrc(
        Packet{
            .version = .@"2",
            .marker = true,
            .payload_type = 96,
            .sequence_number = 27023,
            .timestamp = 3653407706,
            .ssrc = 476325762,
            .csrc = undefined,
            .payload = &.{ 0x98, 0x36, 0xbe, 0x88, 0x9e },
        },
        try Packet.parse(&.{
            0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82, 0xBE, 0xDE, 0x00,
            0x03, 0x10, 0xAA, 0x21, 0xBB, 0xBB, 0x33, 0xCC, 0xCC, 0xCC, 0xCC, 0x00, 0x00, 0x98, 0x36,
            0xbe, 0x88, 0x9e,
        }),
    );
}

test "rfc 8285 two byte extension" {
    try expect_equal_packet_no_csrc(
        Packet{
            .version = .@"2",
            .marker = true,
            .payload_type = 96,
            .sequence_number = 27023,
            .timestamp = 3653407706,
            .ssrc = 476325762,
            .csrc = undefined,
            .payload = &.{ 0x00, 0x98, 0x36, 0xbe, 0x88, 0x9e },
        },
        try Packet.parse(&.{
            0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82, 0x10, 0x00, 0x00,
            0x07, 0x05, 0x18, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA,
            0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x00, 0x00,
            0x98, 0x36, 0xbe, 0x88, 0x9e,
        }),
    );
}

test "rfc8285 two byte multiple extension with padding" {
    try expect_equal_packet_no_csrc(
        Packet{
            .version = .@"2",
            .marker = true,
            .payload_type = 96,
            .sequence_number = 27023,
            .timestamp = 3653407706,
            .ssrc = 476325762,
            .csrc = undefined,
            .payload = &.{ 0x98, 0x36, 0xbe, 0x88, 0x9e },
        },
        try Packet.parse(&.{
            0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82, 0x10, 0x00, 0x00,
            0x03, 0x01, 0x00, 0x02, 0x01, 0xBB, 0x00, 0x03, 0x04, 0xCC, 0xCC, 0xCC, 0xCC, 0x98, 0x36,
            0xbe, 0x88, 0x9e,
        }),
    );
}

test "rfc8285 two byte multiple extension with large extension" {
    try expect_equal_packet_no_csrc(
        Packet{
            .version = .@"2",
            .marker = true,
            .payload_type = 96,
            .sequence_number = 27023,
            .timestamp = 3653407706,
            .ssrc = 476325762,
            .csrc = undefined,
            .payload = &.{ 0x98, 0x36, 0xbe, 0x88, 0x9e },
        },
        try Packet.parse(&.{
            0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82, 0x10, 0x00, 0x00,
            0x06, 0x01, 0x00, 0x02, 0x01, 0xBB, 0x03, 0x11, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC,
            0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x98, 0x36, 0xbe, 0x88, 0x9e,
        }),
    );
}

test "error short header" {
    try std.testing.expectError(
        ParseError.Malformed,
        Packet.parse(&.{ 0x80, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27 }),
    );
}

test "error missing csrc" {
    try std.testing.expectError(
        ParseError.Malformed,
        Packet.parse(&.{ 0x81, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82 }),
    );
}

test "error missing extension" {
    try std.testing.expectError(
        ParseError.Malformed,
        Packet.parse(&.{ 0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82 }),
    );
}

test "error missing extension data" {
    try std.testing.expectError(
        ParseError.Malformed,
        Packet.parse(&.{ 0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82, 0xBE, 0xDE, 0x00, 0x03 }),
    );
}

test "error missing extension data payload" {
    try std.testing.expectError(
        ParseError.Malformed,
        Packet.parse(&.{ 0x90, 0xe0, 0x69, 0x8f, 0xd9, 0xc2, 0x93, 0xda, 0x1c, 0x64, 0x27, 0x82, 0xBE, 0xDE, 0x00, 0x01, 0x12, 0x00 }),
    );
}

inline fn expect_equal_packet_no_csrc(a: Packet, b: Packet) !void {
    var a_copy = a;
    var b_copy = b;
    a_copy.csrc = @splat(0);
    b_copy.csrc = @splat(0);
    try std.testing.expectEqualDeep(a_copy, b_copy);
}
