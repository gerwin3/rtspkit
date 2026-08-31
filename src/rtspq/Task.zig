const std = @import("std");

const stdx = @import("stdx");
const Diagnostics = stdx.Diagnostics;

const media = @import("media");
const rtsp = media.rtsp;
const Codec = media.Codec;

const Target = @import("Target.zig");
const InfoCollector = @import("InfoCollector.zig");
const Info = @import("Info.zig");
const DiagnosticsCollector = @import("DiagnosticsCollector.zig");

const Task = @This();

uri: []const u8,
diagnostics_collector: DiagnosticsCollector,
out: Error!Info = undefined,

pub const Error = error{
    InvalidScheme,
    InsufficientInfo,
    Overflow,
} || std.Uri.ParseError || std.Io.net.HostName.ValidateError || std.Io.net.HostName.ConnectError || rtsp.Stream.SetupError || rtsp.Stream.ReceiveError || rtsp.Stream.DepacketizeError;

pub fn run(self: *Task, io: std.Io, arena: std.mem.Allocator) std.Io.Cancelable!void {
    if (self.run_impl(io, arena)) |info| {
        self.out = info;
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => self.out = err,
    }
}

fn run_impl(self: *Task, io: std.Io, arena: std.mem.Allocator) Error!Info {
    const probe_iters_max: usize = 300;
    const codec_list: [2]Codec = .{ .h264, .h265 };
    const diagnostics = self.diagnostics_collector.diagnostics();

    var target: Target = try .parse(arena, self.uri, .{});

    const stream = try target.host.connect(
        io,
        target.port,
        .{ .mode = .stream, .protocol = .tcp },
    );
    defer stream.close(io);

    const stream_reader_buffer = arena.alloc(u8, 64 * 1024) catch @panic("oom");
    const stream_writer_buffer = arena.alloc(u8, 4096) catch @panic("oom");
    var stream_reader = stream.reader(io, stream_reader_buffer);
    var stream_writer = stream.writer(io, stream_writer_buffer);

    var connection = rtsp.Session.Connection{
        .stream_reader = &stream_reader.interface,
        .stream_writer = &stream_writer.interface,
    };

    var rtsp_stream = rtsp.Stream.init(
        arena,
        diagnostics,
        &connection,
        target.request_uri,
        target.credentials,
        &codec_list,
        .{},
    ) catch @panic("oom");

    try rtsp_stream.setup(io, diagnostics);
    try rtsp_stream.play(io, diagnostics);

    var info_collector: InfoCollector = .init(arena);

    // In most cases we will have already received the parameter sets in the
    // session description information during the DESCRIBE phase of the RTSP
    // conversation. This information already contains codec, profile,
    // dimensions (in SPS) and in some cases frame rate through the VUI
    // information. If that is the case, we never have to probe at all after
    // this.
    if (rtsp_stream.parameter_sets) |parameter_sets| {
        info_collector.codec = std.meta.activeTag(parameter_sets);
        switch (parameter_sets) {
            .h264 => |params| if (params.sps) |*sps| info_collector.feed_h264_sps(sps),
            .h265 => |params| if (params.sps) |*sps| info_collector.feed_h265_sps(sps),
        }
    }

    // In the case we did not receive parameter sets early, we need to receive
    // NALUs and find the SPS. If the SPS does not have VUI information, we need
    // to infer the frame rate by guessing.
    var probe_count: usize = 0;
    while (probe_count < probe_iters_max) {
        if (info_collector.have_all_info()) break; // Break out if we have all information.
        try rtsp_stream.receive(io, diagnostics);
        while (try rtsp_stream.demux(diagnostics)) |nalu| {
            const demuxer = &rtsp_stream.rtp_demuxer.?;
            const time = (demuxer.time *| 1_000_000_000) / demuxer.clock_rate;
            info_collector.feed(time, &nalu);
            probe_count +|= 1;
            if (probe_count >= probe_iters_max) break;
        }
    }

    return if (info_collector.have_min_info()) .{
        .codec = info_collector.codec.?,
        .profile = info_collector.profile.?,
        .dimensions = info_collector.dimensions.?,
        .frame_rate = info_collector.frame_rate,
    } else Error.InsufficientInfo;
}
