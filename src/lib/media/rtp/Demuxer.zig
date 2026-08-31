const std = @import("std");
const stdx = @import("stdx");
const Diagnostics = stdx.Diagnostics;

const Codec = @import("../codec.zig").Codec;
const Nalu = @import("../Nalu.zig");
const rtp = @import("../rtp.zig");
const H264Depacketizer = rtp.H264Depacketizer;
const H265Depacketizer = rtp.H265Depacketizer;
const Packet = rtp.Packet;

const Demuxer = @This();

depacketizer: union(Codec) {
    h264: H264Depacketizer,
    h265: H265Depacketizer,
},

fragmentation_state: enum { init, sync, desync } = .init,

pending_packet: ?Packet = null,

sequence_number: ?u16 = null,

clock_rate: u32 = 90_000,
time: u128 = 0,
last_delta: ?u32 = null,
last_timestamp: ?u32 = null,

pub const FeedError = Packet.ParseError;

/// Feed packet data to the demuxer.
/// The packet data must remain valid for all calls to demux until the next call to feed.
pub fn feed(self: *Demuxer, diagnostics: Diagnostics, packet_data: []const u8) FeedError!void {
    std.debug.assert(self.pending_packet == null);

    self.pending_packet = try Packet.parse(packet_data);

    self.record_sequence_number(diagnostics);
    self.record_timestamp(diagnostics);
}

pub const DemuxError = error{
    InvalidRtpPacket,
    UnexpectedRtpFragment,
    UnsupportedRtpPacketType,
    Overflow,
};

/// Demux one NALU from the RTP stream.
/// The returned NALU data is valid for the duration of the packet data.
/// Call this in a loop until it returns null.
pub fn demux(self: *Demuxer, diagnostics: Diagnostics) DemuxError!?Nalu {
    if (self.pending_packet == null) return null;

    return switch (self.depacketizer) {
        .h264 => |*depacketizer| self.depacketize_h26x(diagnostics, H264Depacketizer, depacketizer),
        .h265 => |*depacketizer| self.depacketize_h26x(diagnostics, H265Depacketizer, depacketizer),
    } catch |err| switch (err) {
        error.Malformed => DemuxError.InvalidRtpPacket,
        error.Unexpected => DemuxError.UnexpectedRtpFragment,
        error.Unsupported => DemuxError.UnsupportedRtpPacketType,
        error.Overflow => DemuxError.Overflow,
    };
}

const DepacketizeH26xError = rtp.H264Depacketizer.DepacketizeError || rtp.H265Depacketizer.DepacketizeError;

fn depacketize_h26x(self: *Demuxer, diagnostics: Diagnostics, Depacketizer: type, depacketizer: *Depacketizer) DepacketizeH26xError!?Nalu {
    const depacketizer_out = depacketizer.depacketize(&self.pending_packet.?) catch |err| switch (err) {
        // Fragmentation state bookkeeping:
        DepacketizeH26xError.Unexpected => {
            // A non-first fragment still consumes the current packet even when we ignore it.
            self.pending_packet = null;

            // If we are in the desync state already we do not care either since we already warned before.
            switch (self.fragmentation_state) {
                // If we are in the init state (demuxer is new) then a desynced fragment is expected and we can just skip it.
                .init => return null,
                // If we are in the desync state already we do not care either since we already warned before.
                .desync => return null,
                // If we are in the sync state then this is a new desync and we set the state to desync.
                .sync => {
                    diagnostics.report(.warn, null, "Received out-of-order rtp fragment. Fragment will be ignored.", .{});
                    self.fragmentation_state = .desync;
                    return null;
                },
            }
        },
        else => return err,
    };
    self.fragmentation_state = .sync; // Any successful depacketize always sets state to sync.
    if (depacketizer_out == null or depacketizer.state == .ready) self.pending_packet = null;
    return depacketizer_out;
}

fn record_sequence_number(self: *Demuxer, diagnostics: Diagnostics) void {
    const sequence_number = self.pending_packet.?.sequence_number;

    if (self.sequence_number) |last_sequence_number| {
        const expected_sequence_number = last_sequence_number +% 1;
        if (expected_sequence_number != sequence_number) {
            diagnostics.report(.err, null, "Received out-of-order rtp packet: Expected sequence number {d}, but got {d}.", .{ expected_sequence_number, sequence_number });
        }
    }

    self.sequence_number = sequence_number;
}

fn record_timestamp(self: *Demuxer, diagnostics: Diagnostics) void {
    const timestamp = self.pending_packet.?.timestamp;

    if (self.last_timestamp) |last_timestamp| {
        var delta = if (timestamp >= last_timestamp)
            timestamp - last_timestamp
        else if ((last_timestamp - timestamp) > (1 << 31))
            std.math.maxInt(u32) - last_timestamp + timestamp + 1
        else
            0;

        const max_delta = 10 *| self.clock_rate;
        const old_delta = delta;
        delta = if (delta < max_delta) delta else self.last_delta orelse 0;

        if (old_delta >= max_delta) {
            diagnostics.report(.warn, null, "Detected large RTP time delta of {d}.{d:0>3} secs (using fallback delta = {d}.{d:0>3} secs).", .{
                old_delta / self.clock_rate,
                (old_delta % self.clock_rate) * 1000 / self.clock_rate,
                delta / self.clock_rate,
                (delta % self.clock_rate) * 1000 / self.clock_rate,
            });
        }

        self.time = self.time +| @as(u128, delta);
        self.last_delta = delta;
        self.last_timestamp = timestamp;
    } else {
        self.time = 0;
        self.last_delta = null;
        self.last_timestamp = timestamp;
    }
}

test "rtp time state init" {
    var buffer: [16]u8 = undefined;
    const demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 90_000 };
    try std.testing.expectEqual(90_000, demuxer.clock_rate);
    try std.testing.expectEqual(0, demuxer.time);
    try std.testing.expectEqual(null, demuxer.last_delta);
    try std.testing.expectEqual(null, demuxer.last_timestamp);
}

test "rtp time first" {
    var buffer: [16]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 90_000 };
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0, 0, 0, 123, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expectEqual(0, demuxer.time);
    try std.testing.expectEqual(null, demuxer.last_delta);
    try std.testing.expectEqual(123, demuxer.last_timestamp);
}

test "rtp time reset" {
    var buffer: [16]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 90_000, .time = 12345, .last_delta = 999 };
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0, 0, 2, 43, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expectEqual(0, demuxer.time);
    try std.testing.expectEqual(null, demuxer.last_delta);
    try std.testing.expectEqual(555, demuxer.last_timestamp);
}

test "rtp time delta" {
    var buffer: [16]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 90_000 };
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0, 0, 3, 232, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 1, 0, 0, 5, 220, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expectEqual(500, demuxer.time);
    try std.testing.expectEqual(500, demuxer.last_delta);
    try std.testing.expectEqual(1500, demuxer.last_timestamp);
}

test "rtp time delta wraparound 1" {
    var buffer: [16]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 90_000 };
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0xff, 0xff, 0xff, 0xfd, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 1, 0, 0, 0, 3, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expectEqual(6, demuxer.time);
    try std.testing.expectEqual(6, demuxer.last_delta);
    try std.testing.expectEqual(3, demuxer.last_timestamp);
}

test "rtp time delta wraparound 2" {
    var buffer: [16]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 90_000 };
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 1, 0, 0, 0, 99, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expectEqual(100, demuxer.time);
    try std.testing.expectEqual(100, demuxer.last_delta);
    try std.testing.expectEqual(99, demuxer.last_timestamp);
}

test "rtp time delta wraparound 3" {
    var buffer: [16]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 90_000 };
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0xff, 0xff, 0xff, 0xf6, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expectEqual(10, demuxer.time);
    try std.testing.expectEqual(10, demuxer.last_delta);
    try std.testing.expectEqual(0, demuxer.last_timestamp);
}

test "rtp time delta big" {
    var buffer: [16]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 1_000 };
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 1, 0, 0, 39, 15, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expectEqual(9_999, demuxer.time);
    try std.testing.expectEqual(9_999, demuxer.last_delta);
    try std.testing.expectEqual(9_999, demuxer.last_timestamp);
}

test "rtp time delta too big" {
    var buffer: [16]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 1_000 };
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 1, 0, 0, 0, 17, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 2, 0, 0, 39, 33, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expectEqual(14, demuxer.time);
    try std.testing.expectEqual(7, demuxer.last_delta);
    try std.testing.expectEqual(10_017, demuxer.last_timestamp);
}

test "rtp time delta too big fallback" {
    var buffer: [16]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 1_000 };
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 1, 0, 0, 39, 17, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expectEqual(0, demuxer.time);
    try std.testing.expectEqual(0, demuxer.last_delta);
    try std.testing.expectEqual(10_001, demuxer.last_timestamp);
}

test "rtp time delta backwards" {
    var buffer: [16]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 90_000 };
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0, 0, 3, 232, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 1, 0, 0, 5, 220, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 2, 0, 0, 5, 210, 0, 0, 0, 0, 0x65 });
    _ = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expectEqual(500, demuxer.time);
    try std.testing.expectEqual(0, demuxer.last_delta);
    try std.testing.expectEqual(1490, demuxer.last_timestamp);
}

test "rtp time absolute time 1" {
    var buffer: [16]u8 = undefined;
    const demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 90_000, .time = 90_000 };
    try std.testing.expectEqual(1_000_000_000, (demuxer.time *| 1_000_000_000) / demuxer.clock_rate);
}

test "rtp time absolute time 2" {
    var buffer: [16]u8 = undefined;
    const demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } }, .clock_rate = 3, .time = 1 };
    try std.testing.expectEqual(333_333_333, (demuxer.time *| 1_000_000_000) / demuxer.clock_rate);
}

test "h264 unexpected fragment enters desync and recovers" {
    var buffer: [32]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h264 = .{ .defragmentation_buffer = &buffer } } };

    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x65 });
    const first = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expect(first != null);
    try std.testing.expectEqualSlices(u8, &.{0x65}, first.?.data);
    try std.testing.expectEqual(.sync, demuxer.fragmentation_state);

    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 1, 0, 0, 0, 10, 0, 0, 0, 0, 0x7c, 0x05, 0xAA });
    try std.testing.expect(try demuxer.demux(stdx.Diagnostics.discarding) == null);
    try std.testing.expect(demuxer.pending_packet == null);
    try std.testing.expectEqual(.desync, demuxer.fragmentation_state);

    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 2, 0, 0, 0, 11, 0, 0, 0, 0, 0x7c, 0x05, 0xBB });
    try std.testing.expect(try demuxer.demux(stdx.Diagnostics.discarding) == null);
    try std.testing.expect(demuxer.pending_packet == null);
    try std.testing.expectEqual(.desync, demuxer.fragmentation_state);

    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 3, 0, 0, 0, 20, 0, 0, 0, 0, 0x7c, 0x85, 0x01 });
    try std.testing.expect(try demuxer.demux(stdx.Diagnostics.discarding) == null);
    try std.testing.expectEqual(.sync, demuxer.fragmentation_state);

    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 4, 0, 0, 0, 20, 0, 0, 0, 0, 0x7c, 0x05, 0x02 });
    try std.testing.expect(try demuxer.demux(stdx.Diagnostics.discarding) == null);
    try std.testing.expectEqual(.sync, demuxer.fragmentation_state);

    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 5, 0, 0, 0, 20, 0, 0, 0, 0, 0xff, 0x00, 0x00 });
    const reassembled = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expect(reassembled != null);
    try std.testing.expectEqualSlices(u8, &.{ 0x65, 0x01, 0x02 }, reassembled.?.data);
    try std.testing.expect(try demuxer.demux(stdx.Diagnostics.discarding) == null);
    try std.testing.expect(demuxer.pending_packet == null);
    try std.testing.expectEqual(.sync, demuxer.fragmentation_state);
}

test "h265 unexpected fragment state cleared by next first fragment" {
    var buffer: [32]u8 = undefined;
    var demuxer = Demuxer{ .depacketizer = .{ .h265 = .{ .defragmentation_buffer = &buffer } } };

    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0x62, 0x01, 0x13, 0xAA });
    try std.testing.expect(try demuxer.demux(stdx.Diagnostics.discarding) == null);
    try std.testing.expect(demuxer.pending_packet == null);
    try std.testing.expectEqual(.init, demuxer.fragmentation_state);

    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 1, 0, 0, 0, 20, 0, 0, 0, 0, 0x62, 0x01, 0x93, 0x01 });
    try std.testing.expect(try demuxer.demux(stdx.Diagnostics.discarding) == null);
    try std.testing.expectEqual(.sync, demuxer.fragmentation_state);

    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 2, 0, 0, 0, 20, 0, 0, 0, 0, 0x62, 0x01, 0x13, 0x02 });
    try std.testing.expect(try demuxer.demux(stdx.Diagnostics.discarding) == null);
    try std.testing.expectEqual(.sync, demuxer.fragmentation_state);

    try demuxer.feed(stdx.Diagnostics.discarding, &.{ 0x80, 96, 0, 3, 0, 0, 0, 20, 0, 0, 0, 0, 0x7e, 0x00, 0x00 });
    const reassembled = try demuxer.demux(stdx.Diagnostics.discarding);
    try std.testing.expect(reassembled != null);
    try std.testing.expectEqualSlices(u8, &.{ 0x26, 0x01, 0x01, 0x02 }, reassembled.?.data);
    try std.testing.expect(try demuxer.demux(stdx.Diagnostics.discarding) == null);
    try std.testing.expect(demuxer.pending_packet == null);
    try std.testing.expectEqual(.sync, demuxer.fragmentation_state);
}
