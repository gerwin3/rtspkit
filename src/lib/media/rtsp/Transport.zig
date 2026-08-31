const std = @import("std");

pub const Transport = @This();

lower: ?Lower = null,
mode: Mode = .unicast,
interleaved: ?Interleaved = null,

pub const Lower = enum {
    tcp,
    udp,
};

pub const Mode = enum {
    unicast,
    multicast,
};

pub const Interleaved = struct {
    channel_rtp: u8 = 0,
    channel_rtcp: u8 = 1,

    const prefix = "interleaved=";

    pub fn parse(slice: []const u8) ParseError!Interleaved {
        const slice_trimmed = std.mem.trim(u8, slice, " \t");
        if (slice_trimmed.len == 0) return ParseError.Malformed;

        var parts = std.mem.splitScalar(u8, slice_trimmed, '-');

        const channel_rtp_slice = std.mem.trim(u8, parts.first(), " \t");
        const channel_rtp = std.fmt.parseInt(u8, channel_rtp_slice, 10) catch return ParseError.Malformed;

        const channel_rtcp_slice = std.mem.trim(u8, parts.rest(), " \t");
        const channel_rtcp = if (channel_rtcp_slice.len > 0)
            std.fmt.parseInt(u8, channel_rtcp_slice, 10) catch return ParseError.Malformed
        else
            channel_rtp +| 1;

        return .{ .channel_rtp = channel_rtp, .channel_rtcp = channel_rtcp };
    }
};

pub const ParseError = error{
    Malformed,
    Unsupported,
};

pub fn parse(slice: []const u8) ParseError!Transport {
    const slice_trimmed = std.mem.trim(u8, slice, " \t\r\n");
    if (slice_trimmed.len == 0) return ParseError.Malformed;

    var parts = std.mem.splitScalar(u8, slice_trimmed, ';');

    const protocol = std.mem.trim(u8, parts.first(), " \t");
    const lower = if (std.mem.eql(u8, protocol, "RTP/AVP"))
        null
    else if (std.mem.eql(u8, protocol, "RTP/AVP/UDP"))
        Lower.udp
    else if (std.mem.eql(u8, protocol, "RTP/AVP/TCP"))
        Lower.tcp
    else
        return ParseError.Unsupported;

    var mode: ?Mode = null;
    var interleaved: ?Interleaved = null;

    while (parts.next()) |part_untrimmed| {
        const part = std.mem.trim(u8, part_untrimmed, " \t");
        if (part.len == 0) continue;

        if (std.mem.eql(u8, part, "unicast")) {
            mode = .unicast;
        } else if (std.mem.eql(u8, part, "multicast")) {
            mode = .multicast;
        } else if (std.mem.startsWith(u8, part, Interleaved.prefix)) {
            interleaved = try Interleaved.parse(part[Interleaved.prefix.len..]);
        }
    }

    return .{
        .lower = lower,
        .mode = mode orelse .unicast,
        .interleaved = interleaved,
    };
}

pub fn write(self: Transport, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.lower) |lower| {
        switch (lower) {
            .udp => try writer.writeAll("RTP/AVP/UDP"),
            .tcp => try writer.writeAll("RTP/AVP/TCP"),
        }
    } else {
        try writer.writeAll("RTP/AVP");
    }

    switch (self.mode) {
        .unicast => try writer.writeAll(";unicast"),
        .multicast => try writer.writeAll(";multicast"),
    }

    if (self.interleaved) |interleaved| {
        try writer.print(
            ";interleaved={d}-{d}",
            .{
                interleaved.channel_rtp,
                interleaved.channel_rtcp,
            },
        );
    }
}

pub fn is_compatible(self: Transport, other: Transport) bool {
    // reject if other transport has different transport
    if ((self.lower orelse .udp) != (other.lower orelse .udp)) return false;

    // reject if other transport has different mode
    if (self.mode != other.mode) return false;

    // reject if other transport has incompatible interleaved
    if (self.interleaved) |interleaved| {
        if (other.interleaved) |other_interleaved| {
            return (interleaved.channel_rtp == other_interleaved.channel_rtp) and
                (interleaved.channel_rtcp == other_interleaved.channel_rtcp);
        } else return false;
    }

    // accept if not rejected on any of the above rules
    return true;
}

fn expect_written_transport(expected_header: []const u8, transport: Transport) !void {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try transport.write(&writer);
    try std.testing.expectEqualStrings(expected_header, writer.buffered());
}

test "parse parses tcp interleaved transport" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = .tcp,
            .mode = .unicast,
            .interleaved = .{
                .channel_rtp = 0,
                .channel_rtcp = 1,
            },
        },
        try Transport.parse("RTP/AVP/TCP;unicast;interleaved=0-1"),
    );
}

test "parse defaults transport mode to unicast when omitted" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = .tcp,
            .mode = .unicast,
            .interleaved = .{
                .channel_rtp = 0,
                .channel_rtcp = 1,
            },
        },
        try Transport.parse("RTP/AVP/TCP;interleaved=0-1"),
    );
}

test "parse ignores unrelated parameters" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = .tcp,
            .mode = .unicast,
            .interleaved = .{
                .channel_rtp = 0,
                .channel_rtcp = 1,
            },
        },
        try Transport.parse(
            "RTP/AVP/TCP;unicast;destination=127.0.0.1;source=127.0.0.1;interleaved=0-1;ssrc=0600e01e",
        ),
    );
}

test "parse expands single interleaved channel" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = .tcp,
            .mode = .unicast,
            .interleaved = .{
                .channel_rtp = 8,
                .channel_rtcp = 9,
            },
        },
        try Transport.parse("RTP/AVP/TCP;unicast;interleaved=8"),
    );
}

test "parse parses bare udp unicast transport" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = null,
            .mode = .unicast,
            .interleaved = null,
        },
        try Transport.parse("RTP/AVP;unicast"),
    );
}

test "parse parses explicit udp unicast transport" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = .udp,
            .mode = .unicast,
            .interleaved = null,
        },
        try Transport.parse("RTP/AVP/UDP;unicast"),
    );
}

test "parse parses bare udp multicast transport" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = null,
            .mode = .multicast,
            .interleaved = null,
        },
        try Transport.parse("RTP/AVP;multicast"),
    );
}

test "parse parses tcp unicast interleaved channels zero one transport" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = .tcp,
            .mode = .unicast,
            .interleaved = .{
                .channel_rtp = 0,
                .channel_rtcp = 1,
            },
        },
        try Transport.parse("RTP/AVP/TCP;unicast;interleaved=0-1"),
    );
}

test "parse parses tcp unicast interleaved channels two three transport" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = .tcp,
            .mode = .unicast,
            .interleaved = .{
                .channel_rtp = 2,
                .channel_rtcp = 3,
            },
        },
        try Transport.parse("RTP/AVP/TCP;unicast;interleaved=2-3"),
    );
}

test "parse parses tcp interleaved before unicast transport" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = .tcp,
            .mode = .unicast,
            .interleaved = .{
                .channel_rtp = 0,
                .channel_rtcp = 1,
            },
        },
        try Transport.parse("RTP/AVP/TCP;interleaved=0-1;unicast"),
    );
}

test "parse parses tcp multicast interleaved channels four five transport" {
    try std.testing.expectEqualDeep(
        Transport{
            .lower = .tcp,
            .mode = .multicast,
            .interleaved = .{
                .channel_rtp = 4,
                .channel_rtcp = 5,
            },
        },
        try Transport.parse("RTP/AVP/TCP;multicast;interleaved=4-5"),
    );
}

test "write writes bare transport without lower suffix" {
    try expect_written_transport("RTP/AVP;unicast", .{ .lower = null, .mode = .unicast });
}

test "write writes interleaved tcp transport" {
    try expect_written_transport("RTP/AVP/TCP;unicast;interleaved=0-1", .{
        .lower = .tcp,
        .mode = .unicast,
        .interleaved = .{
            .channel_rtp = 0,
            .channel_rtcp = 1,
        },
    });
}

test "write writes explicit udp unicast transport" {
    try expect_written_transport("RTP/AVP/UDP;unicast", .{
        .lower = .udp,
        .mode = .unicast,
        .interleaved = null,
    });
}

test "write writes tcp unicast interleaved channels zero one transport" {
    try expect_written_transport("RTP/AVP/TCP;unicast;interleaved=0-1", .{
        .lower = .tcp,
        .mode = .unicast,
        .interleaved = .{
            .channel_rtp = 0,
            .channel_rtcp = 1,
        },
    });
}

test "write writes tcp unicast interleaved channels two three transport" {
    try expect_written_transport("RTP/AVP/TCP;unicast;interleaved=2-3", .{
        .lower = .tcp,
        .mode = .unicast,
        .interleaved = .{
            .channel_rtp = 2,
            .channel_rtcp = 3,
        },
    });
}

test "write writes tcp multicast interleaved channels four five transport" {
    try expect_written_transport("RTP/AVP/TCP;multicast;interleaved=4-5", .{
        .lower = .tcp,
        .mode = .multicast,
        .interleaved = .{
            .channel_rtp = 4,
            .channel_rtcp = 5,
        },
    });
}

test "write writes tcp unicast single interleaved channel transport" {
    try expect_written_transport("RTP/AVP/TCP;unicast;interleaved=2-3", .{
        .lower = .tcp,
        .mode = .unicast,
        .interleaved = .{
            .channel_rtp = 2,
            .channel_rtcp = 3,
        },
    });
}

test "is_compatible treats bare RTP AVP as UDP" {
    const expected = Transport{
        .lower = .udp,
        .mode = .unicast,
    };
    const actual = Transport{
        .lower = null,
        .mode = .unicast,
    };

    try std.testing.expect(expected.is_compatible(actual));
}

test "is_compatible requires matching interleaved channels" {
    const expected = Transport{
        .lower = .tcp,
        .mode = .unicast,
        .interleaved = .{
            .channel_rtp = 0,
            .channel_rtcp = 1,
        },
    };
    const actual = Transport{
        .lower = .tcp,
        .mode = .unicast,
        .interleaved = .{
            .channel_rtp = 2,
            .channel_rtcp = 3,
        },
    };

    try std.testing.expect(!expected.is_compatible(actual));
}
