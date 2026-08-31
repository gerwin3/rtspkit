const std = @import("std");

const media = @import("media");
const Codec = media.Codec;
const Nalu = media.Nalu;

const Dimensions = @import("Dimensions.zig");
const Rational = @import("Rational.zig");
const avc_utils = @import("avc_utils.zig");
const hevc_utils = @import("hevc_utils.zig");

const InfoCollector = @This();

codec: ?Codec = null,
profile: ?[]const u8 = null,
dimensions: ?Dimensions = null,
frame_rate: ?Rational = null,
frame_rate_estimator: FrameRateEstimator,

pub fn init(arena: std.mem.Allocator) InfoCollector {
    return .{ .frame_rate_estimator = .init(arena) };
}

pub fn feed(self: *InfoCollector, time: u128, nalu: *const Nalu) void {
    var is_picture = false;
    switch (nalu.header) {
        .h264 => |header| switch (header.nal_unit) {
            .sps => |*sps| self.feed_h264_sps(sps),
            .slice, .idr => is_picture = true,
            else => self.codec = .h264,
        },
        .h265 => |header| switch (header.nal_unit) {
            .sps => |*sps| self.feed_h265_sps(sps),
            .slice, .idr, .cra => is_picture = true,
            else => self.codec = .h265,
        },
    }
    if (is_picture) {
        self.frame_rate_estimator.submit(time);
        if (self.frame_rate_estimator.read()) |frame_rate| self.frame_rate = frame_rate;
    }
}

pub fn feed_h264_sps(self: *InfoCollector, sps: *const Nalu.Header.H264.SPS) void {
    self.codec = .h264;
    self.profile = @tagName(sps.profile_idc);
    self.dimensions = avc_utils.display_dimensions(sps);
    if (avc_utils.frame_rate(sps)) |frame_rate| self.frame_rate = frame_rate;
}

pub fn feed_h265_sps(self: *InfoCollector, sps: *const Nalu.Header.H265.SPS) void {
    self.codec = .h265;
    self.profile = @tagName(sps.profile_idc);
    self.dimensions = hevc_utils.display_dimensions(sps);
    if (hevc_utils.frame_rate(sps)) |frame_rate| self.frame_rate = frame_rate;
}

pub fn have_all_info(self: *const InfoCollector) bool {
    return self.codec != null and self.profile != null and self.dimensions != null and self.frame_rate != null;
}

pub fn have_min_info(self: *const InfoCollector) bool {
    return self.codec != null and self.profile != null and self.dimensions != null;
}

const FrameRateEstimator = struct {
    const history_size: usize = 60;
    const estimate_num: usize = 50;

    history: std.Deque(u128),

    pub fn init(arena: std.mem.Allocator) FrameRateEstimator {
        return .{ .history = std.Deque(u128).initCapacity(arena, history_size) catch @panic("oom") };
    }

    /// time in nanos.
    pub fn submit(self: *FrameRateEstimator, time: u128) void {
        if (self.history.back()) |last_time| if (last_time == time) return; // Dedup
        if (self.history.len == self.history.buffer.len) _ = self.history.popFront();
        self.history.pushBackAssumeCapacity(time);
    }

    /// Read accurate frame rate estimate in frames per second.
    pub fn read(self: *const FrameRateEstimator) ?Rational {
        if (self.history.len == 0) return null;

        // There are 8 buckets with delta values for which we will keep count.
        // This value epxerimentally seems to be fine.
        var buckets: [8]struct { delta: u128, count: usize } = undefined;
        var buckets_used: usize = 0;
        var time_prev_iter: ?u128 = null;
        var history_iter = self.history.iterator();
        while (history_iter.next()) |time| {
            defer time_prev_iter = time;
            const prev_time = time_prev_iter orelse continue;
            const delta = time - prev_time;
            if (delta == 0) continue;
            // Find a bucket that is within 2 millis and increase its count.
            var bucket_found = false;
            for (buckets[0..buckets_used]) |*bucket| {
                if (absdiff(delta, bucket.delta) < 2000000) {
                    bucket.count +|= 1;
                    bucket_found = true;
                }
            }
            // Or assign a new bucket. If we are out of buckets the delta will
            // be ignored.
            if (!bucket_found and buckets_used < buckets.len) {
                buckets[buckets_used] = .{ .delta = delta, .count = 1 };
                buckets_used += 1;
            }
            // for (0.., buckets[0..buckets_used]) |i, bucket| std.debug.print("bucket {d} = {d} x {d}, ", .{ i, bucket.delta, bucket.count });
            // std.debug.print("prev_time = {any}, time = {d}\n", .{ time_prev_iter, time });
        }

        if (buckets_used == 0) return null;

        // Find the bucket with the highest count.
        var bucket_hi: usize = 0;
        for (0.., buckets[0..buckets_used]) |i, *bucket| {
            if (bucket.count > buckets[bucket_hi].count) bucket_hi = i;
        }
        const winner = buckets[bucket_hi];

        if (winner.count >= estimate_num) {
            return .{ .num = 1_000_000_000, .den = winner.delta };
        } else if (self.history.len == history_size) {
            // The fallback algorithm for when there is no winning bucket just takes the mean.
            var delta_sum: u128 = 0;
            var count: usize = 0;
            for (buckets[0..buckets_used]) |bucket| {
                delta_sum +|= bucket.count *| bucket.delta;
                count +|= bucket.count;
            }
            const delta_est = delta_sum / count;
            // Still we check that the 8 buckets cover at least 30 of the 40 history (good enough).
            return if (count > estimate_num) .{ .num = 1_000_000_000, .den = delta_est } else null;
        } else return null;
    }
};

inline fn absdiff(a: u128, b: u128) u128 {
    return if (a > b) a - b else b - a;
}
