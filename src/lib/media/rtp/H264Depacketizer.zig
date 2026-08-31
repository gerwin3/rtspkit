const std = @import("std");

const Codec = @import("../codec.zig").Codec;
const rtp = @import("../rtp.zig");
const Packet = rtp.Packet;
const Nalu = @import("../Nalu.zig");

pub const H264Depacketizer = @This();

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
pub fn depacketize(self: *H264Depacketizer, packet: *const Packet) DepacketizeError!?Nalu {
    if (packet.payload.len == 0) return DepacketizeError.Malformed;
    if (packet.payload.len > std.math.maxInt(u16)) return DepacketizeError.Overflow;

    const nal_unit_type = packet.payload[0] & 0x1f;
    switch (nal_unit_type) {
        // NAL: Single NAL Unit
        1...23 => {
            switch (self.state) {
                .pending_aggregation_packet => unreachable, // Caller did not drain the depacketizer
                .pending_fragmentation_unit => return try self.flush(),
                .retry, .ready => {},
            }

            self.state = .ready;

            return try Nalu.parse_h264(packet.payload);
        },
        // STAP-A: Single-time aggregation packet
        24 => {
            switch (self.state) {
                .pending_aggregation_packet => {},
                .pending_fragmentation_unit => return try self.flush(),
                .retry, .ready => {
                    self.state = .{ .pending_aggregation_packet = .{ .pos = 1 } };
                },
            }

            const pos = &self.state.pending_aggregation_packet.pos;

            const remaining = packet.payload[pos.*..];
            if (remaining.len < 2) return DepacketizeError.Malformed;

            const len = std.mem.readInt(u16, remaining[0..2], .big);
            if ((2 + len) > remaining.len) return DepacketizeError.Malformed;

            const pos_new = pos.* + 2 + len;
            if (pos_new < packet.payload.len) {
                pos.* = pos_new;
            } else {
                self.state = .ready;
            }

            // FIXME: Technically we should handle 30..31 NALUs here and ignore
            // them. This is not something that actually happens in production
            // as far as I know and the case is hard to handle here since if we
            // return null we signal to the caller that they can stop flushing
            // (which is incorrect). If we recurse there is a chance we
            // eventually overflow the stack. If we do a loop here that is quite
            // hacky.

            return try Nalu.parse_h264(remaining[2 .. 2 + len]);
        },
        // STAP-B
        25 => {
            // Only supported in packetization mode 2 (not supported here).
            return DepacketizeError.Unsupported;
        },
        // MTAP
        26...27 => {
            // Only supported in packetization mode 2 (not supported here).
            return DepacketizeError.Unsupported;
        },
        // FU-A: Fragmentation unit.
        28 => {
            if (packet.payload.len < 3) return DepacketizeError.Malformed;

            switch (self.state) {
                .pending_aggregation_packet => unreachable, // Caller did not drain the depacketizer
                .pending_fragmentation_unit => |*fragment_state| {
                    const fu_header = packet.payload[1];
                    const first = (fu_header & 0x80) > 0;
                    if (first) return try self.flush();

                    const fragment = packet.payload[2..];
                    const end = fragment_state.end +| fragment.len;
                    if (end > self.defragmentation_buffer.len) return DepacketizeError.Overflow;

                    @memcpy(self.defragmentation_buffer[fragment_state.end..end], fragment);
                    self.state = .{ .pending_fragmentation_unit = .{ .end = end } };
                },
                .retry, .ready => {
                    const fu_indicator = packet.payload[0];
                    const fu_header = packet.payload[1];
                    const first = (fu_header & 0x80) > 0;
                    if (!first) return DepacketizeError.Unexpected; // This one must be the first

                    const header = (fu_indicator & 0xe0) | (fu_header & 0x1f); // Reconstruct NAL header
                    const fragment = packet.payload[2..];

                    self.defragmentation_buffer[0] = header; // Copy over NAL header for first fragment
                    @memcpy(self.defragmentation_buffer[1 .. 1 + fragment.len], fragment);
                    self.state = .{ .pending_fragmentation_unit = .{ .end = 1 + fragment.len } };
                },
            }

            return null;
        },
        // FU-B
        29 => {
            // Only supported in packetization mode 2 (not supported here).
            return DepacketizeError.Unsupported;
        },
        // Reserved
        30...31 => {
            switch (self.state) {
                .pending_aggregation_packet => unreachable, // Caller did not drain the depacketizer
                .pending_fragmentation_unit => return try self.flush(),
                .retry, .ready => {},
            }

            self.state = .ready;

            // These must be ignored.
            return null;
        },
        else => {
            // Invalid NALU type.
            return DepacketizeError.Malformed;
        },
    }
}

/// Flush defragmentation buffer.
/// Returns the full NALU from the defragmentation buffer. It is up to the
/// caller to ensure the NALU is complete.
fn flush(self: *H264Depacketizer) Nalu.ParseError!Nalu {
    switch (self.state) {
        .pending_fragmentation_unit => |*fragment_state| {
            const defragmented_unit_payload = self.defragmentation_buffer[0..fragment_state.end];

            // Signal to caller that instead of handling the packet we have
            // emitted a completed fragmentation unit, and thus the caller must
            // retry the packet.
            self.state = .retry;

            return try Nalu.parse_h264(defragmented_unit_payload);
        },
        else => unreachable,
    }
}

test "empty" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
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
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
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
            .payload = &.{ 0xff, 0x00, 0x00 },
        }),
    );
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "unsupported nalu type" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
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
            .payload = &.{ 25, 0x00, 0x00 },
        }),
    );
}

test "invalid nalu type" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
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
            .payload = &.{ 0x00, 0x00, 0x00 },
        }),
    );
}

test "single nal" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
    const payload = &.{ 0x65, 0x90, 0x90 };
    try std.testing.expectEqualDeep(
        try Nalu.parse_h264(payload),
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

test "stap a" {
    var buffer: [32]u8 = undefined;
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
    const payload = [_]u8{
        0x78, 0x00, 0x0f, 0x67, 0x42, 0xc0, 0x1f, 0x1a, 0x32, 0x35, 0x01, 0x40, 0x7a, 0x40, 0x3c,
        0x22, 0x11, 0xa8, 0x00, 0x05, 0x68, 0x1a, 0x34, 0xe3, 0xc8,
    };
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
    try std.testing.expectEqualDeep(try Nalu.parse_h264(payload[3..18]), (try depacketizer.depacketize(&packet)).?);
    try std.testing.expectEqual(.pending_aggregation_packet, std.meta.activeTag(depacketizer.state));
    try std.testing.expectEqualDeep(try Nalu.parse_h264(payload[20..25]), (try depacketizer.depacketize(&packet)).?);
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "stap a incomplete" {
    var buffer: [32]u8 = undefined;
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
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
            .payload = &.{
                0x78, 0x00, 0x0f, 0x67, 0x42, 0xc0, 0x1f, 0x1a, 0x32, 0x35, 0x01, 0x40, 0x7a, 0x40, 0x3c,
                0x22, 0x11,
            },
        }),
    );
}

test "fu a" {
    var buffer: [32]u8 = undefined;
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expect(
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x7c, 0x85, 0x01, 0x02, 0x03 },
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
            .payload = &.{ 0x7c, 0x05, 0x04, 0x05, 0x06 },
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
            .payload = &.{ 0x7c, 0x45, 0x07, 0x08, 0x09 },
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
        .payload = &.{ 0x61, 0xaa, 0xbb },
    };
    try std.testing.expectEqualDeep(
        try Nalu.parse_h264(&.{ 0x65, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 }),
        (try depacketizer.depacketize(&final_packet)).?,
    );
    try std.testing.expectEqual(.retry, depacketizer.state);
    try std.testing.expectEqualDeep(try Nalu.parse_h264(final_packet.payload), (try depacketizer.depacketize(&final_packet)).?);
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "fu a flushes before ignored reserved nal" {
    var buffer: [32]u8 = undefined;
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expect(
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x7c, 0x85, 0x01, 0x02 },
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
            .payload = &.{ 0x7c, 0x05, 0x03 },
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
        .payload = &.{ 0xff, 0x00, 0x00 },
    };
    try std.testing.expectEqualDeep(
        try Nalu.parse_h264(&.{ 0x65, 0x01, 0x02, 0x03 }),
        (try depacketizer.depacketize(&ignored_packet)).?,
    );
    try std.testing.expectEqual(.retry, depacketizer.state);
    try std.testing.expect(try depacketizer.depacketize(&ignored_packet) == null);
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "fu a flushes before next fu a start" {
    var buffer: [32]u8 = undefined;
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
    try std.testing.expect(
        try depacketizer.depacketize(&Packet{
            .version = .@"2",
            .marker = false,
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
            .csrc = undefined,
            .payload = &.{ 0x7c, 0x85, 0xA1 },
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
            .payload = &.{ 0x7c, 0x05, 0xA2 },
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
        .payload = &.{ 0x7c, 0x81, 0xB1 },
    };
    try std.testing.expectEqualDeep(
        try Nalu.parse_h264(&.{ 0x65, 0xA1, 0xA2 }),
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
        .payload = &.{ 0xff, 0x00, 0x00 },
    };
    try std.testing.expectEqualDeep(
        try Nalu.parse_h264(&.{ 0x61, 0xB1 }),
        (try depacketizer.depacketize(&ignored_packet)).?,
    );
    try std.testing.expectEqual(.retry, depacketizer.state);
    try std.testing.expect(try depacketizer.depacketize(&ignored_packet) == null);
    try std.testing.expectEqual(.ready, depacketizer.state);
}

test "fu a requires first fragment" {
    var buffer: [16]u8 = undefined;
    var depacketizer = H264Depacketizer{ .defragmentation_buffer = &buffer };
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
            .payload = &.{ 0x7c, 0x05, 0xAA },
        }),
    );
}
