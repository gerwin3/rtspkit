const std = @import("std");

pub const AnnexBIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(self: *AnnexBIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;

        const search_pos_max = self.data.len -| 2;
        var search_pos = @min(self.pos + 3, search_pos_max);
        while (search_pos < search_pos_max) : (search_pos += 1) {
            const remaining = self.data[search_pos..];
            if ((remaining.len >= 4 and std.mem.eql(u8, remaining[0..4], &.{ 0x00, 0x00, 0x00, 0x01 })) or
                (remaining.len >= 3 and std.mem.eql(u8, remaining[0..3], &.{ 0x00, 0x00, 0x01 })))
            {
                defer self.pos = search_pos;
                return self.data[self.pos..search_pos];
            }
        }

        defer self.pos = self.data.len;
        return self.data[self.pos..];
    }
};

test "AnnexBIterator empty" {
    const data = "";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator simple 1" {
    for ([_][]const u8{
        "\x12",
        "\x12\x34",
        "\x12\x34\x56",
        "\x00\x00\x01",
        "\x00\x00\x00\x01",
    }) |data| {
        var it = AnnexBIterator{ .data = data };
        try std.testing.expectEqualSlices(u8, data, it.next().?);
        try std.testing.expectEqual(null, it.next());
    }
}

test "AnnexBIterator simple 2" {
    const data = "\x00\x00\x00\x01\x65\x88\x99";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data, it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator 4 byte startcode" {
    const data = "\x00\x00\x00\x01\x65\xAA\x00\x00\x00\x01\x41";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data[0..6], it.next().?);
    try std.testing.expectEqualSlices(u8, data[6..11], it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator 3 byte startcode" {
    const data = "\x00\x00\x01\x65\xAA\x00\x00\x01\x41";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data[0..5], it.next().?);
    try std.testing.expectEqualSlices(u8, data[5..9], it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator mixed startcode" {
    const data = "\x00\x00\x00\x01\x67\x88\x00\x00\x01\x68\x99";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data[0..6], it.next().?);
    try std.testing.expectEqualSlices(u8, data[6..11], it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator empty s" {
    const data = "\x00\x00\x00\x01\x00\x00\x00\x01\xAA";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data[0..4], it.next().?);
    try std.testing.expectEqualSlices(u8, data[4..9], it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator trailing startcode 1" {
    const data = "\x00\x00\x00\x01\xAA\x00\x00\x00\x01";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data[0..5], it.next().?);
    try std.testing.expectEqualSlices(u8, data[5..9], it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator trailing startcode 2" {
    const data = "\x00\x00\x01\xAA\x00\x00\x01";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data[0..4], it.next().?);
    try std.testing.expectEqualSlices(u8, data[4..7], it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator trailing startcode 3" {
    const data = "\x00\x00\x01\xAA\xBB\x00\x00\x01";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data[0..5], it.next().?);
    try std.testing.expectEqualSlices(u8, data[5..8], it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator trailing startcode 4" {
    const data = "\x00\x00\x00\x01\xAA\xBB\x00\x00\x00\x01";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data[0..6], it.next().?);
    try std.testing.expectEqualSlices(u8, data[6..10], it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator first " {
    const data = "\xFF\x00\x00\x00\x01\xAA\x00\x00\x00\x01\xBB";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data[0..6], it.next().?);
    try std.testing.expectEqualSlices(u8, data[6..11], it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "AnnexBIterator null after end" {
    const data = "\x00\x00\x00\x01\x65";
    var it = AnnexBIterator{ .data = data };
    try std.testing.expectEqualSlices(u8, data, it.next().?);
    try std.testing.expectEqual(null, it.next());
    try std.testing.expectEqual(null, it.next());
}
