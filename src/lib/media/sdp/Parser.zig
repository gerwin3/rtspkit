const std = @import("std");

const Codec = @import("../codec.zig").Codec;
const sdp = @import("../sdp.zig");
const Version = sdp.Version;
const Media = sdp.Media;
const Attribute = sdp.Attribute;

pub const Parser = @This();

buffer: []const u8,
pos: usize = 0,

pub const ParseError = error{
    Unsupported,
    Malformed,
};

pub const Item = union(enum) {
    version: Version,
    media: Media,
    attribute: Attribute,
};

pub fn next(self: *Parser) ParseError!?Item {
    while (self.pos < self.buffer.len) {
        const line_start = self.pos;
        const line_end = if (std.mem.indexOfScalar(u8, self.buffer[line_start..], '\n')) |line_len|
            line_start + line_len
        else
            self.buffer.len;

        defer self.pos = @min(line_end + 1, self.buffer.len);

        if (parse_line(self.buffer[line_start..line_end]) catch |err| switch (err) {
            ParseError.Unsupported => continue,
            ParseError.Malformed => return ParseError.Malformed,
        }) |item| return item;
    } else {
        return null;
    }
}

fn parse_line(line: []const u8) ParseError!?Item {
    const line_trimmed = std.mem.trim(u8, line, " \t\r");
    if (line_trimmed.len == 0) return null;
    if (line_trimmed.len < 2 or line_trimmed[1] != '=') return ParseError.Malformed;

    const value = std.mem.trim(u8, line_trimmed[2..], " \t");
    return switch (line_trimmed[0]) {
        'v' => .{ .version = try parse_version(value) },
        'm' => .{ .media = try parse_media(value) },
        'a' => .{ .attribute = try parse_attribute(value) },
        else => ParseError.Unsupported,
    };
}

fn parse_version(value: []const u8) ParseError!Version {
    return std.meta.stringToEnum(Version, value) orelse ParseError.Unsupported;
}

fn parse_media(value: []const u8) ParseError!Media {
    var parts = std.mem.tokenizeAny(u8, value, " \t");

    const kind = std.meta.stringToEnum(Media.Type, parts.next() orelse return ParseError.Malformed) orelse return ParseError.Unsupported;
    const port = std.fmt.parseInt(u32, parts.next() orelse return ParseError.Malformed, 10) catch return ParseError.Malformed;
    const protocol = std.meta.stringToEnum(Media.TransportProtocol, parts.next() orelse return ParseError.Malformed) orelse .other;
    const payload_value = parts.next() orelse return ParseError.Malformed;
    const payload_type = if (!std.mem.eql(u8, payload_value, "*"))
        std.fmt.parseInt(u8, payload_value, 10) catch return ParseError.Malformed
    else
        null;

    return .{
        .kind = kind,
        .port = port,
        .protocol = protocol,
        .payload_type = payload_type,
    };
}

fn parse_attribute(value: []const u8) ParseError!Attribute {
    var parts = std.mem.splitScalar(u8, value, ':');

    const name = parts.first();
    const tag = std.meta.stringToEnum(std.meta.Tag(Attribute), name) orelse return ParseError.Unsupported;
    const val = std.mem.trim(u8, parts.rest(), " \t");
    if (val.len == 0) return ParseError.Malformed;

    return switch (tag) {
        .fmtp => .{ .fmtp = try parse_attr_fmtp(val) },
        .rtpmap => .{ .rtpmap = try parse_attr_rtp_map(val) },
        .control => .{ .control = try parse_attr_control(val) },
    };
}

fn parse_attr_fmtp(value: []const u8) ParseError!Attribute.Fmtp {
    var parts = std.mem.splitScalar(u8, value, ' ');

    const payload_type = std.fmt.parseInt(u8, parts.first(), 10) catch return ParseError.Malformed;
    const parameters = std.mem.trim(u8, parts.rest(), " \t");
    if (parameters.len == 0) return ParseError.Malformed;

    return .{
        .payload_type = payload_type,
        .parameters = try parse_attr_fmtp_parameters(parameters),
    };
}

fn parse_attr_fmtp_parameters(value: []const u8) ParseError!Attribute.Fmtp.FormatParameters {
    var parameters: Attribute.Fmtp.FormatParameters = .{};

    var parts = std.mem.splitScalar(u8, value, ';');
    while (parts.next()) |part_untrimmed| {
        const part = std.mem.trim(u8, part_untrimmed, " \t");
        if (part.len == 0) continue;

        try parse_attr_fmtp_parameter(&parameters, part);
    }

    return parameters;
}

fn parse_attr_fmtp_parameter(parameters: *Attribute.Fmtp.FormatParameters, parameter: []const u8) ParseError!void {
    var parts = std.mem.splitScalar(u8, parameter, '=');
    const name = std.mem.trim(u8, parts.first(), " \t");
    const val = std.mem.trim(u8, parts.rest(), " \t");

    switch (std.meta.stringToEnum(enum {
        @"sprop-parameter-sets",
        @"sprop-vps",
        @"sprop-sps",
        @"sprop-pps",
        @"packetization-mode",
        @"profile-level-id",
    }, name) orelse return) {
        .@"sprop-parameter-sets" => {
            var sprop_parts = std.mem.splitScalar(u8, val, ',');
            const parameter_set_1 = sprop_parts.next() orelse return ParseError.Malformed;
            const parameter_set_2 = sprop_parts.next() orelse return ParseError.Malformed;
            const parameter_set_3 = sprop_parts.next();

            if (parameter_set_3) |picture_parameter_set| {
                parameters.parameter_sets.vps = parameter_set_1;
                parameters.parameter_sets.sps = parameter_set_2;
                parameters.parameter_sets.pps = picture_parameter_set;
            } else {
                parameters.parameter_sets.vps = null;
                parameters.parameter_sets.sps = parameter_set_1;
                parameters.parameter_sets.pps = parameter_set_2;
            }
        },
        .@"sprop-vps" => {
            parameters.parameter_sets.vps = val;
        },
        .@"sprop-sps" => {
            parameters.parameter_sets.sps = val;
        },
        .@"sprop-pps" => {
            parameters.parameter_sets.pps = val;
        },
        .@"packetization-mode" => {
            parameters.packetization_mode = std.fmt.parseInt(u8, val, 10) catch return ParseError.Malformed;
        },
        .@"profile-level-id" => {
            parameters.profile_level_id = val;
        },
    }
}

fn parse_attr_rtp_map(value: []const u8) ParseError!Attribute.RtpMap {
    var parts = std.mem.splitScalar(u8, value, ' ');

    const payload_type = std.fmt.parseInt(u8, parts.first(), 10) catch return ParseError.Malformed;

    const mapping_value = std.mem.trim(u8, parts.rest(), " \t");
    if (mapping_value.len == 0) return ParseError.Malformed;

    var mapping_parts = std.mem.splitScalar(u8, mapping_value, '/');
    const encoding_name = mapping_parts.first();
    const codec = if (std.mem.eql(u8, encoding_name, "H264"))
        Codec.h264
    else if (std.mem.eql(u8, encoding_name, "H265"))
        Codec.h265
    else
        return ParseError.Unsupported;

    const clock_rate = std.fmt.parseInt(u32, mapping_parts.next() orelse return ParseError.Malformed, 10) catch return ParseError.Malformed;

    return .{
        .payload_type = payload_type,
        .codec = codec,
        .clock_rate = clock_rate,
    };
}

fn parse_attr_control(value: []const u8) ParseError!Attribute.Control {
    return .{ .uri = value };
}

test "parse_line parses version" {
    try std.testing.expectEqualDeep(Item{ .version = .@"0" }, (try parse_line("v=0")).?);
}

test "parse_line rejects unsupported bare attribute" {
    try std.testing.expectError(ParseError.Unsupported, parse_line("a=sendonly"));
}

test "parse_version supports version 0" {
    try std.testing.expectEqual(.@"0", try parse_version("0"));
}

test "parse_media parses a single payload type" {
    try std.testing.expectEqualDeep(Media{
        .kind = .video,
        .port = 5004,
        .protocol = .@"RTP/AVP",
        .payload_type = 96,
    }, try parse_media("video 5004 RTP/AVP 96"));
}

test "parse_media keeps the first payload type when multiple are present" {
    try std.testing.expectEqualDeep(Media{
        .kind = .video,
        .port = 5004,
        .protocol = .@"RTP/AVP",
        .payload_type = 96,
    }, try parse_media("video 5004 RTP/AVP 96 97"));
}

test "parse_attribute parses control URIs with embedded colons" {
    try std.testing.expectEqualDeep(Attribute{
        .control = .{ .uri = "rtsp://example.com/trackID=1" },
    }, try parse_attribute("control:rtsp://example.com/trackID=1"));
}

test "parse_attribute parses rtpmap" {
    try std.testing.expectEqualDeep(Attribute{
        .rtpmap = .{
            .payload_type = 96,
            .codec = .h264,
            .clock_rate = 90000,
        },
    }, try parse_attribute("rtpmap:96 H264/90000"));
}

test "parse_attribute parses fmtp parameter sets" {
    try std.testing.expectEqualDeep(Attribute{
        .fmtp = .{
            .payload_type = 96,
            .parameters = .{
                .packetization_mode = 1,
                .profile_level_id = "42A01E",
                .parameter_sets = .{
                    .sps = "Z0IACpZTBYmI",
                    .pps = "aMljiA==",
                },
            },
        },
    }, try parse_attribute("fmtp:96 profile-level-id=42A01E; packetization-mode=1; sprop-parameter-sets=Z0IACpZTBYmI,aMljiA=="));
}

test "parse_attribute rejects unsupported bare attributes" {
    try std.testing.expectError(ParseError.Unsupported, parse_attribute("sendonly"));
}

test "parse_attr_fmtp_parameters parses sprop parameter sets with two values" {
    try std.testing.expectEqualDeep(
        Attribute.Fmtp.FormatParameters{
            .parameter_sets = .{
                .sps = "Z0IACpZTBYmI",
                .pps = "aMljiA==",
            },
        },
        try parse_attr_fmtp_parameters("sprop-parameter-sets=Z0IACpZTBYmI,aMljiA=="),
    );
}

test "parse_attr_fmtp_parameters parses sprop parameter sets with three values" {
    try std.testing.expectEqualDeep(
        Attribute.Fmtp.FormatParameters{
            .parameter_sets = .{
                .vps = "dGhpcy12cHM=",
                .sps = "c3BzLXZhbA==",
                .pps = "cHBzLXZhbA==",
            },
        },
        try parse_attr_fmtp_parameters("sprop-parameter-sets=dGhpcy12cHM=,c3BzLXZhbA==,cHBzLXZhbA=="),
    );
}

test "parse_attr_fmtp_parameters ignores extra sprop parameter sets beyond three values" {
    try std.testing.expectEqualDeep(
        Attribute.Fmtp.FormatParameters{
            .parameter_sets = .{
                .vps = "vps",
                .sps = "sps",
                .pps = "pps",
            },
        },
        try parse_attr_fmtp_parameters("sprop-parameter-sets=vps,sps,pps,extra1,extra2"),
    );
}

test "parse_attr_fmtp_parameters errors when sprop parameter sets are missing the second value" {
    try std.testing.expectError(
        ParseError.Malformed,
        parse_attr_fmtp_parameters("sprop-parameter-sets=Z0IACpZTBYmI"),
    );
}

test "parse_attr_fmtp_parameters allows empty sprop parameter set tokens" {
    try std.testing.expectEqualDeep(
        Attribute.Fmtp.FormatParameters{
            .parameter_sets = .{
                .sps = "",
                .pps = "pps",
            },
        },
        try parse_attr_fmtp_parameters("sprop-parameter-sets=,pps"),
    );
    try std.testing.expectEqualDeep(
        Attribute.Fmtp.FormatParameters{
            .parameter_sets = .{
                .sps = "sps",
                .pps = "",
            },
        },
        try parse_attr_fmtp_parameters("sprop-parameter-sets=sps,"),
    );
    try std.testing.expectEqualDeep(
        Attribute.Fmtp.FormatParameters{
            .parameter_sets = .{
                .vps = "vps",
                .sps = "sps",
                .pps = "",
            },
        },
        try parse_attr_fmtp_parameters("sprop-parameter-sets=vps,sps,"),
    );
}

test "parse_attr_fmtp_parameters defaults when no sprops are present" {
    try std.testing.expectEqualDeep(
        Attribute.Fmtp.FormatParameters{
            .packetization_mode = 2,
            .profile_level_id = "42A01E",
        },
        try parse_attr_fmtp_parameters("profile-level-id=42A01E; packetization-mode=2"),
    );
}

test "parse_attr_fmtp_parameters parses sprop parameter sets with two values alongside other parameters" {
    try std.testing.expectEqualDeep(
        Attribute.Fmtp.FormatParameters{
            .packetization_mode = 2,
            .profile_level_id = "42A01E",
            .parameter_sets = .{
                .sps = "Z0IACpZTBYmI",
                .pps = "aMljiA==",
            },
        },
        try parse_attr_fmtp_parameters("profile-level-id=42A01E; sprop-parameter-sets=Z0IACpZTBYmI,aMljiA==; packetization-mode=2"),
    );
}

test "parse_attr_fmtp_parameters parses individual sprop vps, sps, and pps values" {
    try std.testing.expectEqualDeep(
        Attribute.Fmtp.FormatParameters{
            .parameter_sets = .{
                .vps = "vps123",
                .sps = "sps456",
                .pps = "pps789",
            },
        },
        try parse_attr_fmtp_parameters("sprop-vps=vps123; sprop-sps=sps456; sprop-pps=pps789"),
    );
}

test "parse_attr_fmtp_parameters lets individual sprop values override earlier parameter sets" {
    try std.testing.expectEqualDeep(
        Attribute.Fmtp.FormatParameters{
            .parameter_sets = .{
                .vps = "vps0",
                .sps = "sps1",
                .pps = "pps0",
            },
        },
        try parse_attr_fmtp_parameters("sprop-parameter-sets=vps0,sps0,pps0; sprop-sps=sps1"),
    );
}

test "parse_attr_fmtp_parameters errors on malformed sprop parameter sets" {
    try std.testing.expectError(
        ParseError.Malformed,
        parse_attr_fmtp_parameters("sprop-parameter-sets=only-one"),
    );
}
