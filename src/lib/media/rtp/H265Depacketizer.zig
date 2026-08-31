const std = @import("std");

const Codec = @import("../codec.zig").Codec;
const rtp = @import("../rtp.zig");
const Packet = rtp.Packet;
const Nalu = @import("../Nalu.zig");

pub const H265Depacketizer = @This();

/// Defragmentation buffer. This should be enough to fit a full NALU for reconstruction.
defragmentation_buffer: []u8,

state: union(enum) {
    /// Current packet is aggregation packet payload.
    /// User must call depacketize with same packet until it is drained.
    pending_aggregation_packet: struct {
        /// Current position in aggregate packet payload.
        pos: usize,
    },
    /// Defragmentation in progress. Defragmentation buffer contains partial payload.
    /// User must feed next packet to depacketize.
    pending_fragmentation_unit: struct {
        /// End of defragmented packet payload in defragmentation_buffer.
        end: usize,
    },
    /// Defragmented packet was just flushed.
    /// User must retry current packet.
    retry,
    /// Depacketizer is ready for next packet.
    ready,
} = .ready,

pub const DepacketizeError = error{
    /// Malformed RTP packet.
    Malformed,
    /// Received fragment that unexpectedly did not have first bit set.
    Unexpected,
    /// Received payload that is larger than buffer.
    Overflow,
    /// Unsupported packet type.
    Unsupported,
} || Nalu.ParseError;

/// Depacketize an RTP packet into zero, one or more NALUs.
/// If this function returns an error, it is in an inconsistent state and must be reset.
/// If this function returns a NALU, it may have more NALUs pending. Call depacketize in a loop, feeding the same
/// RTP packet as argument, until it returns null or state == .ready. The returned NALU is only valid until the
/// next call to depacketize.
/// If this function returns null, a fragmented NALU is pending and the caller must feed the next packet.
/// Example usage:
///     while (depacketizer.depacketize(packet)) |nalu| {
///         // ... do things with nalu
///         if (depacketizer.state == .ready) break;
///     }
pub fn depacketize(self: *H265Depacketizer, packet: *const Packet) DepacketizeError!?Nalu {
    if (packet.payload.len < 2) return DepacketizeError.Malformed;
    // This limit is somewhat arbitrary but in production RTP packets are often
    // maximized at below the MTU. So we usually expect packets of 1200 bytes or
    // less. A 4096-byte packet is virtually always an error.
    if (packet.payload.len > 4096) return DepacketizeError.Overflow;

    const nal_unit_type = (packet.payload[0] >> 1) & 0x3f;
    switch (nal_unit_type) {
        // NAL: Single NAL Unit
        0...47 => {
            switch (self.state) {
                .pending_aggregation_packet => unreachable, // Caller did not drain the depacketizer
                .pending_fragmentation_unit => return try self.flush(),
                .retry, .ready => {},
            }

            self.state = .ready;

            return try Nalu.parse_h265(packet.payload);
        },
        // AP: Aggregation Packet
        48 => {
            switch (self.state) {
                .pending_aggregation_packet => {},
                .pending_fragmentation_unit => return try self.flush(),
                .retry, .ready => {
                    self.state = .{ .pending_aggregation_packet = .{ .pos = 2 } };
                },
            }

            const pos = &self.state.pending_aggregation_packet.pos;

            const remaining = packet.payload[pos.*..];
            if (remaining.len < 2) return DepacketizeError.Malformed;

            const len = std.mem.readInt(u16, remaining[0..2], .big);
            if (len == 0) return DepacketizeError.Malformed;
            if ((2 + len) > remaining.len) return DepacketizeError.Malformed;
            if (len < 2) return DepacketizeError.Malformed;

            const pos_new = pos.* + 2 + len;
            if (pos_new < packet.payload.len) {
                pos.* = pos_new;
            } else {
                self.state = .ready;
            }

            // FIXME: Technically we should handle 48..63 NALUs here and ignore
            // them. This is not something that actually happens in production
            // as far as I know and the case is hard to handle here since if we
            // return null we signal to the caller that they can stop flushing
            // (which is incorrect). If we recurse there is a chance we
            // eventually overflow the stack. If we do a loop here that is quite
            // hacky.

            return try Nalu.parse_h265(remaining[2 .. 2 + len]);
        },
        // FU: Fragmentation Unit
        49 => {
            if (packet.payload.len < 3) return DepacketizeError.Malformed;

            switch (self.state) {
                .pending_aggregation_packet => unreachable, // Caller did not drain the depacketizer
                .pending_fragmentation_unit => |*fragment_state| {
                    const fu_header = packet.payload[2];
                    const first = (fu_header & 0x80) > 0;
                    if (first) return try self.flush();

                    const fragment = packet.payload[3..];
                    const end = fragment_state.end +| fragment.len;
                    if (end > self.defragmentation_buffer.len) return DepacketizeError.Overflow;

                    @memcpy(self.defragmentation_buffer[fragment_state.end..end], fragment);
                    self.state = .{ .pending_fragmentation_unit = .{ .end = end } };
                },
                .retry, .ready => {
                    const fu_indicator_0 = packet.payload[0];
                    const fu_header = packet.payload[2];
                    const first = (fu_header & 0x80) > 0;
                    const fu_type = fu_header & 0x3f;
                    if (!first) return DepacketizeError.Unexpected; // This one must be the first

                    const header_0 = (fu_indicator_0 & 0x81) | (fu_type << 1);
                    const header_1 = packet.payload[1];
                    const fragment = packet.payload[3..];
                    const end = 2 + fragment.len;
                    if (end > self.defragmentation_buffer.len) return DepacketizeError.Overflow;

                    self.defragmentation_buffer[0] = header_0; // Copy over NAL header for first fragment
                    self.defragmentation_buffer[1] = header_1;
                    @memcpy(self.defragmentation_buffer[2..end], fragment);
                    self.state = .{ .pending_fragmentation_unit = .{ .end = end } };
                },
            }

            return null;
        },
        // PACI
        50 => {
            // PACI packets carry payload header extensions such as TSCI etc.
            // that are not common in security cameras so we do not support it.
            return DepacketizeError.Unsupported;
        },
        // Reserved
        51...63 => {
            switch (self.state) {
                .pending_aggregation_packet => unreachable, // Caller did not drain the depacketizer
                .pending_fragmentation_unit => return try self.flush(),
                .retry, .ready => {},
            }

            self.state = .ready;

            // These must be ignored.
            return null;
        },
        else => unreachable,
    }
}

/// Flush defragmentation buffer.
/// Returns the full NALU from the defragmentation buffer. It is up to the
/// caller to ensure the NALU is complete.
fn flush(self: *H265Depacketizer) Nalu.ParseError!Nalu {
    switch (self.state) {
        .pending_fragmentation_unit => |*fragment_state| {
            const defragmented_unit_payload = self.defragmentation_buffer[0..fragment_state.end];

            // Signal to caller that instead of handling the packet we have
            // emitted a completed fragmentation unit, and thus the caller must
            // retry the packet.
            self.state = .retry;

            return try Nalu.parse_h265(defragmented_unit_payload);
        },
        else => unreachable,
    }
}

test "empty" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expectError(
        DepacketizeError.Malformed,
        depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{},
        }),
    );
}

test "ignore" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expectEqual(
        null,
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x7e, 0x00, 0x00 },
        }),
    );
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "unsupported nalu type" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expectError(
        DepacketizeError.Unsupported,
        depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x64, 0x00, 0x00 },
        }),
    );
}

test "invalid nalu type" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expectError(
        DepacketizeError.Malformed,
        depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{0x00},
        }),
    );
}

test "single nal" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    const payload = &.{ 0x02, 0x01, 0x90, 0x90 };
    try std.testing.expectEqualDeep(
        try Nalu.parse_h265(payload),
        (try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = payload,
        })).?,
    );
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "ap" {
    var buffer: [32]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    const payload = [_]u8{ 0x60, 0x01, 0x00, 0x04, 0x02, 0x01, 0xAA, 0xBB, 0x00, 0x03, 0x04, 0x01, 0xCC };
    const packet = Packet{
        .version = .@"2",
        .marker = false,
        .payload_type = 0,
        .sequence_number = 0,
        .timestamp = 0,
        .ssrc = 0,
        .csrc = undefined,
        .payload = &payload,
    };
    try std.testing.expectEqualDeep(try Nalu.parse_h265(payload[4..8]), (try depacketizer.depacketize(&packet)).?);
    try std.testing.expectEqual(.pending_aggregation_packet, std.meta.activeTag(depacketizer.state));
    try std.testing.expectEqualDeep(try Nalu.parse_h265(payload[10..13]), (try depacketizer.depacketize(&packet)).?);
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "ap incomplete" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expectError(
        DepacketizeError.Malformed,
        depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x60, 0x01, 0x00, 0x04, 0x02, 0x01, 0xAA },
        }),
    );
}

test "fu" {
    var buffer: [32]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expect(
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x62, 0x01, 0x81, 0x01, 0x02, 0x03 },
        }) == null,
    );
    try std.testing.expectEqual(.pending_fragmentation_unit, std.meta.activeTag(depacketizer.state));
    try std.testing.expect(
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x62, 0x01, 0x01, 0x04, 0x05, 0x06 },
        }) == null,
    );
    try std.testing.expectEqual(.pending_fragmentation_unit, std.meta.activeTag(depacketizer.state));
    try std.testing.expect(
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x62, 0x01, 0x41, 0x07, 0x08, 0x09 },
        }) == null,
    );
    try std.testing.expectEqual(.pending_fragmentation_unit, std.meta.activeTag(depacketizer.state));
    const final_packet = Packet{
        .version = .@"2",
        .marker = false,
        .payload_type = 0,
        .sequence_number = 0,
        .timestamp = 0,
        .ssrc = 0,
        .csrc = undefined,
        .payload = &.{ 0x02, 0x01, 0xaa, 0xbb },
    };
    try std.testing.expectEqualDeep(
        try Nalu.parse_h265(&.{ 0x02, 0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 }),
        (try depacketizer.depacketize(&final_packet)).?,
    );
    try std.testing.expectEqual(.retry, depacketizer.state);
    try std.testing.expectEqualDeep(try Nalu.parse_h265(final_packet.payload), (try depacketizer.depacketize(&final_packet)).?);
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "fu flushes before ignored reserved nal" {
    var buffer: [32]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expect(
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x62, 0x01, 0x93, 0x01, 0x02 },
        }) == null,
    );
    try std.testing.expect(
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x62, 0x01, 0x13, 0x03 },
        }) == null,
    );
    const ignored_packet = Packet{
        .version = .@"2",
        .marker = false,
        .payload_type = 0,
        .sequence_number = 0,
        .timestamp = 0,
        .ssrc = 0,
        .csrc = undefined,
        .payload = &.{ 0x7e, 0x00, 0x00 },
    };
    try std.testing.expectEqualDeep(
        try Nalu.parse_h265(&.{ 0x26, 0x01, 0x01, 0x02, 0x03 }),
        (try depacketizer.depacketize(&ignored_packet)).?,
    );
    try std.testing.expectEqual(.retry, depacketizer.state);
    try std.testing.expect(try depacketizer.depacketize(&ignored_packet) == null);
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "fu flushes before next fu start" {
    var buffer: [32]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expect(
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x62, 0x01, 0x93, 0xA1 },
        }) == null,
    );
    try std.testing.expect(
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x62, 0x01, 0x13, 0xA2 },
        }) == null,
    );
    const next_packet = Packet{
        .version = .@"2",
        .marker = false,
        .payload_type = 0,
        .sequence_number = 0,
        .timestamp = 0,
        .ssrc = 0,
        .csrc = undefined,
        .payload = &.{ 0x62, 0x01, 0x81, 0xB1 },
    };
    try std.testing.expectEqualDeep(
        try Nalu.parse_h265(&.{ 0x26, 0x01, 0xA1, 0xA2 }),
        (try depacketizer.depacketize(&next_packet)).?,
    );
    try std.testing.expectEqual(.retry, depacketizer.state);
    try std.testing.expect(try depacketizer.depacketize(&next_packet) == null);
    try std.testing.expectEqual(.pending_fragmentation_unit, std.meta.activeTag(depacketizer.state));

    const ignored_packet = Packet{
        .version = .@"2",
        .marker = false,
        .payload_type = 0,
        .sequence_number = 0,
        .timestamp = 0,
        .ssrc = 0,
        .csrc = undefined,
        .payload = &.{ 0x7e, 0x00, 0x00 },
    };
    try std.testing.expectEqualDeep(
        try Nalu.parse_h265(&.{ 0x02, 0x01, 0xB1 }),
        (try depacketizer.depacketize(&ignored_packet)).?,
    );
    try std.testing.expectEqual(.retry, depacketizer.state);
    try std.testing.expect(try depacketizer.depacketize(&ignored_packet) == null);
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "fu requires first fragment" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H265Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expectError(
        DepacketizeError.Unexpected,
        depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x62, 0x01, 0x13, 0xAA },
        }),
    );
}
