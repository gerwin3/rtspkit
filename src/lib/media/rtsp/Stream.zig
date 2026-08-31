//! RTSP stream.
//!
//! Currently only support RTSP RTP/AVP/TCP Interleaved.

const std = @import("std");
const stdx = @import("stdx");
const Diagnostics = stdx.Diagnostics;
const uri = stdx.uri;

const codec = @import("../codec.zig");
const Codec = codec.Codec;
const ParameterSets = codec.ParameterSets;
const Nalu = @import("../Nalu.zig");
const rtsp = @import("../rtsp.zig");
const rtp = @import("../rtp.zig");
const sdp = @import("../sdp.zig");

pub const Stream = @This();

const transport_description = rtsp.Transport{
    .mode = .unicast,
    .lower = .tcp,
    .interleaved = .{},
};

request_uri: []const u8,
codec_list: []const Codec,

rtsp_session: rtsp.Session,
rtsp_control_state: struct {
    track_control_uri: ?[]const u8 = null,
    aggregate_control_uri: ?[]const u8 = null,
} = .{},

parameter_sets: ?ParameterSets = null,

rtp_demuxer: ?rtp.Demuxer = null,

ping: ?std.Io.Timestamp,

track_control_uri_buffer: []u8,
aggregate_control_uri_buffer: []u8,

defragmentation_buffer: []u8,

pub fn init(
    gpa: std.mem.Allocator,
    diagnostics: Diagnostics,
    connection: *rtsp.Session.Connection,
    request_uri: []const u8,
    credentials: ?rtsp.Session.Credentials,
    codec_list: []const Codec,
    opts: struct {
        user_agent: []const u8 = "rtspkit/1.0",
        id_buffer_len: usize = 256,
        auth_response_buffer_len: usize = 4096,
        auth_challenge_buffer_len: usize = 4096,
        control_uri_buffer_len: usize = 4096,
        defragmentation_buffer_len: usize = 32 * 1024 * 1024,
    },
) std.mem.Allocator.Error!Stream {
    var rtsp_session = try rtsp.Session.init(
        gpa,
        diagnostics,
        connection,
        credentials,
        .{
            .user_agent = opts.user_agent,
            .id_buffer_len = opts.id_buffer_len,
            .auth_challenge_buffer_len = opts.auth_challenge_buffer_len,
            .auth_response_buffer_len = opts.auth_response_buffer_len,
        },
    );
    errdefer rtsp_session.deinit(gpa);

    const track_control_uri_buffer = try gpa.alloc(u8, opts.control_uri_buffer_len);
    errdefer gpa.free(track_control_uri_buffer);
    const aggregate_control_uri_buffer = try gpa.alloc(u8, opts.control_uri_buffer_len);
    errdefer gpa.free(aggregate_control_uri_buffer);
    const defragmentation_buffer = try gpa.alloc(u8, opts.defragmentation_buffer_len);
    errdefer gpa.free(defragmentation_buffer);

    return .{
        .request_uri = request_uri,
        .codec_list = codec_list,
        .rtsp_session = rtsp_session,
        .rtp_demuxer = null,
        .ping = null,
        .track_control_uri_buffer = track_control_uri_buffer,
        .aggregate_control_uri_buffer = aggregate_control_uri_buffer,
        .defragmentation_buffer = defragmentation_buffer,
    };
}

pub fn deinit(self: *Stream, gpa: std.mem.Allocator) void {
    gpa.free(self.track_control_uri_buffer);
    gpa.free(self.aggregate_control_uri_buffer);
    gpa.free(self.defragmentation_buffer);
    self.rtsp_session.deinit(gpa);
}

pub fn reset(self: *Stream) void {
    self.rtsp_session.reset();
    self.rtsp_control_state = .{};
    self.rtp_demuxer = null;
    @memset(self.track_control_uri_buffer, 0);
    @memset(self.aggregate_control_uri_buffer, 0);
    @memset(self.defragmentation_buffer, 0);
}

pub const SetupError = error{
    MalformedSdp,
    UnsupportedSdp,
    UnsupportedMedia,
    MalformedTransport,
    UnsupportedTransport,
    Overflow,
} || rtsp.Session.RequestError || ParameterSets.ParseBase64Error;

pub fn setup(self: *Stream, io: std.Io, diagnostics: Diagnostics) SetupError!void {
    var response: rtsp.Response = undefined;

    // Send OPTIONS request to ping server and pre-authenticate.
    _ = try self.rtsp_session.options(io, diagnostics, self.request_uri, &response);

    // Send DESCRIBE request, parse the SDP and select the media we want based on codec_list.
    try self.rtsp_session.describe(io, diagnostics, self.request_uri, &response);
    var sdp_parser = sdp.Parser{ .buffer = response.body };
    var sdp_selector = sdp.Selector{ .codecs = self.codec_list, .parser = &sdp_parser };
    const media = sdp_selector.select() catch |err| switch (err) {
        sdp.Parser.ParseError.Malformed => return SetupError.MalformedSdp,
        sdp.Parser.ParseError.Unsupported => return SetupError.UnsupportedSdp,
    } orelse return SetupError.UnsupportedMedia;

    const base_uri = response.head.content_base orelse self.request_uri;
    if (media.control) |control| self.rtsp_control_state.track_control_uri =
        try uri.resolve(self.track_control_uri_buffer, base_uri, control.uri);
    if (media.aggregate_control) |control| self.rtsp_control_state.aggregate_control_uri =
        try uri.resolve(self.aggregate_control_uri_buffer, base_uri, control.uri);
    if (media.format_parameters) |format_parameters| {
        const params = format_parameters.parameter_sets;
        switch (media.codec) {
            .h264 => self.parameter_sets = try .parse_h264_base64(params.sps, params.pps),
            .h265 => self.parameter_sets = try .parse_h265_base64(params.vps, params.sps, params.pps),
        }
    }

    // Send SETUP request to negotiate the transport.
    // This session always uses RTP/AVP/TCP transport or we return error UnsupportedTransport.
    try self.rtsp_session.setup(
        io,
        diagnostics,
        self.rtsp_control_state.track_control_uri orelse base_uri,
        transport_description,
        &response,
    );

    const transport = rtsp.Transport.parse(response.head.transport orelse return SetupError.UnsupportedTransport) catch |err| switch (err) {
        rtsp.Transport.ParseError.Malformed => return SetupError.MalformedTransport,
        rtsp.Transport.ParseError.Unsupported => return SetupError.UnsupportedTransport,
    };
    if (!transport.is_compatible(transport_description)) return SetupError.UnsupportedTransport;

    self.rtp_demuxer = .{
        .depacketizer = switch (media.codec) {
            .h264 => .{ .h264 = .{ .defragmentation_buffer = self.defragmentation_buffer } },
            .h265 => .{ .h265 = .{ .defragmentation_buffer = self.defragmentation_buffer } },
        },
        .clock_rate = media.clock_rate,
    };

    if (self.rtsp_session.state.timeout) |_| self.ping = std.Io.Clock.real.now(io);
}

pub const PlayError = rtsp.Session.RequestError;

pub fn play(self: *Stream, io: std.Io, diagnostics: Diagnostics) PlayError!void {
    var response: rtsp.Response = undefined;
    try self.rtsp_session.play(
        io,
        diagnostics,
        self.rtsp_control_state.aggregate_control_uri orelse self.request_uri,
        &response,
    );

    if (self.rtsp_session.state.timeout) |_| self.ping = std.Io.Clock.real.now(io);
}

pub const ReceiveError = error{InvalidRtpPacket} || rtsp.Session.RequestError || rtsp.Session.ReceiveInterleavedError;

/// Receive data from the underlying stream.
/// This invalidates any NALUs returned by earlier calls to next.
pub fn receive(self: *Stream, io: std.Io, diagnostics: Diagnostics) ReceiveError!void {
    try self.keep_alive(io, diagnostics);

    const interleaved_data = try self.rtsp_session.receive_interleaved_data(diagnostics);

    if (interleaved_data.channel == transport_description.interleaved.?.channel_rtcp) {
        diagnostics.report(.dbg, null, "Received interleaved RTCP data on channel: {d}. Data will be ignored.", .{interleaved_data.channel});
        return;
    }
    if (interleaved_data.channel != transport_description.interleaved.?.channel_rtp) {
        diagnostics.report(.err, null, "Received interleaved data on unknown channel: {d}.", .{interleaved_data.channel});
        return;
    }

    self.rtp_demuxer.?.feed(diagnostics, interleaved_data.data) catch |err| switch (err) {
        rtp.Demuxer.FeedError.Malformed => return ReceiveError.InvalidRtpPacket,
    };
}

pub const DepacketizeError = rtp.Demuxer.DemuxError;

/// Demux one NALU from the RTSP stream.
/// Call this in a loop until it returns null.
pub fn demux(self: *Stream, diagnostics: Diagnostics) DepacketizeError!?Nalu {
    return self.rtp_demuxer.?.demux(diagnostics);
}

fn keep_alive(self: *Stream, io: std.Io, diagnostics: Diagnostics) rtsp.Session.RequestError!void {
    const timeout = self.rtsp_session.state.timeout orelse return;
    const elapsed = self.ping.?.untilNow(io, std.Io.Clock.real).toSeconds();
    if ((elapsed -| 10) >= timeout) {
        var response: rtsp.Response = undefined;
        _ = try self.rtsp_session.options(io, diagnostics, self.request_uri, &response);

        self.ping = std.Io.Clock.real.now(io);
    }
}

inline fn test_stream_request_response(
    request_uri: []const u8,
    credentials: ?rtsp.Session.Credentials,
    expected_requests: []const u8,
    expected_responses: []const u8,
) !void {
    return test_stream_request_response_chunked(request_uri, credentials, expected_requests, expected_responses, expected_responses.len);
}

inline fn test_stream_request_response_chunked(
    request_uri: []const u8,
    credentials: ?rtsp.Session.Credentials,
    expected_requests: []const u8,
    expected_responses: []const u8,
    chunk_size: usize,
) !void {
    std.debug.assert(expected_requests.len > 0);
    std.debug.assert(expected_responses.len > 0);
    std.debug.assert(chunk_size > 0);

    const read_buffer = try std.testing.allocator.alloc(u8, expected_responses.len);
    defer std.testing.allocator.free(read_buffer);

    const calls = try std.testing.allocator.alloc(std.testing.Reader.Call, expected_responses.len);
    defer std.testing.allocator.free(calls);

    var call_count: usize = 0;
    var offset: usize = 0;
    while (offset < expected_responses.len) : (call_count += 1) {
        const end = @min(offset + chunk_size, expected_responses.len);
        calls[call_count] = .{ .buffer = expected_responses[offset..end] };
        offset = end;
    }
    if (call_count == 0) {
        calls[0] = .{ .buffer = "" };
        call_count = 1;
    }

    var reader = std.testing.Reader.init(read_buffer, calls[0..call_count]);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    var connection = rtsp.Session.Connection{
        .stream_reader = &reader.interface,
        .stream_writer = &writer.writer,
    };

    var stream = try init(
        std.testing.allocator,
        stdx.Diagnostics.discarding,
        &connection,
        request_uri,
        credentials,
        &.{ .h264, .h265 },
        .{},
    );
    defer stream.deinit(std.testing.allocator);

    try stream.setup(std.testing.io, stdx.Diagnostics.discarding);
    try stream.play(std.testing.io, stdx.Diagnostics.discarding);

    try std.testing.expectEqualStrings(expected_requests, writer.written());
}

test "session simple" {
    try test_stream_request_response(
        "rtsp://example.com/stream",
        null,
        "OPTIONS rtsp://example.com/stream RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://example.com/stream RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 2\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "SETUP rtsp://example.com/stream/streamid=0 RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 3\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "PLAY rtsp://example.com/stream RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 4\r\n" ++
            "Session: 12345678\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n",
        "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 1\r\n" ++
            "Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 2\r\n" ++
            "Content-Base: rtsp://example.com/stream/\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Content-Length: 142\r\n" ++
            "\r\n" ++
            "v=0\r\n" ++
            "o=- 2890844526 2890844526 IN IP4 127.0.0.1\r\n" ++
            "s=Example Stream\r\n" ++
            "t=0 0\r\n" ++
            "m=video 0 RTP/AVP 96\r\n" ++
            "a=rtpmap:96 H264/90000\r\n" ++
            "a=control:streamid=0\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 3\r\n" ++
            "Session: 12345678;timeout=60\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 4\r\n" ++
            "\r\n",
    );
}

test "session simple chunked" {
    const chunk_sizes: [6]usize = .{ 1, 2, 4, 8, 256, 1024 };
    for (chunk_sizes) |chunk_size| try test_stream_request_response_chunked(
        "rtsp://example.com/stream",
        null,
        "OPTIONS rtsp://example.com/stream RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://example.com/stream RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 2\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "SETUP rtsp://example.com/stream/streamid=0 RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 3\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "PLAY rtsp://example.com/stream RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 4\r\n" ++
            "Session: 12345678\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n",
        "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 1\r\n" ++
            "Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 2\r\n" ++
            "Content-Base: rtsp://example.com/stream/\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Content-Length: 142\r\n" ++
            "\r\n" ++
            "v=0\r\n" ++
            "o=- 2890844526 2890844526 IN IP4 127.0.0.1\r\n" ++
            "s=Example Stream\r\n" ++
            "t=0 0\r\n" ++
            "m=video 0 RTP/AVP 96\r\n" ++
            "a=rtpmap:96 H264/90000\r\n" ++
            "a=control:streamid=0\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 3\r\n" ++
            "Session: 12345678;timeout=60\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 4\r\n" ++
            "\r\n",
        chunk_size,
    );
}

test "session gortsplib cam1001" {
    try test_stream_request_response(
        "rtsp://100.10.200.100:3554/cam1001",
        null,
        "OPTIONS rtsp://100.10.200.100:3554/cam1001 RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://100.10.200.100:3554/cam1001 RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 2\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "SETUP rtsp://100.10.200.100:3554/cam1001/trackID=0 RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 3\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "PLAY rtsp://100.10.200.100:3554/cam1001 RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 4\r\n" ++
            "Session: 0483639e58264217abe29be4806d5875\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n",
        "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 1\r\n" ++
            "Public: DESCRIBE, ANNOUNCE, SETUP, PLAY, RECORD, PAUSE, GET_PARAMETER, TEARDOWN\r\n" ++
            "Server: gortsplib\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 2\r\n" ++
            "Content-Base: rtsp://100.10.200.100:3554/cam1001/\r\n" ++
            "Content-Length: 265\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Server: gortsplib\r\n" ++
            "\r\n" ++
            "v=0\r\n" ++
            "o=- 0 0 IN IP4 127.0.0.1\r\n" ++
            "s=Session streamed by \"ssrtspd\"\r\n" ++
            "c=IN IP4 0.0.0.0\r\n" ++
            "t=0 0\r\n" ++
            "m=video 0 RTP/AVP 96\r\n" ++
            "a=control:trackID=0\r\n" ++
            "a=rtpmap:96 H264/90000\r\n" ++
            "a=fmtp:96 packetization-mode=1; profile-level-id=640033; sprop-parameter-sets=Z2QAM6wVFKB4AiflQA==,aO48sA==\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 3\r\n" ++
            "Server: gortsplib\r\n" ++
            "Session: 0483639e58264217abe29be4806d5875;timeout=60\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=B36240BD\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 4\r\n" ++
            "RTP-Info: url=rtsp://100.10.200.100:3554/cam1001/trackID=0;seq=58429;rtptime=2877623216\r\n" ++
            "Server: gortsplib\r\n" ++
            "Session: 0483639e58264217abe29be4806d5875;timeout=60\r\n" ++
            "\r\n",
    );
}

test "session digifort basic auth" {
    try test_stream_request_response(
        "rtsp://192.168.99.99:554/Interface/Cameras/Media?Camera=CAM001",
        .{ .user = "test", .password = "test" },
        "OPTIONS rtsp://192.168.99.99:554/Interface/Cameras/Media?Camera=CAM001 RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://192.168.99.99:554/Interface/Cameras/Media?Camera=CAM001 RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 2\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://192.168.99.99:554/Interface/Cameras/Media?Camera=CAM001 RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Authorization: Basic dGVzdDp0ZXN0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 3\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "SETUP rtsp://192.168.99.99:554/Interface/Cameras/Media?Camera=CAM001/trackID=1 RTSP/1.0\r\n" ++
            "Authorization: Basic dGVzdDp0ZXN0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 4\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "PLAY rtsp://192.168.99.99:554/Interface/Cameras/Media?Camera=CAM001 RTSP/1.0\r\n" ++
            "Authorization: Basic dGVzdDp0ZXN0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 5\r\n" ++
            "Session: 12345678\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n",
        "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 1\r\n" ++
            "Public: DESCRIBE, PAUSE, PLAY, SETUP, TEARDOWN\r\n" ++
            "\r\n" ++
            "RTSP/1.0 401 Unauthorized\r\n" ++
            "CSeq: 2\r\n" ++
            "WWW-Authenticate: Basic realm=\"Digifort RTSP Server\"\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 3\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Content-Length: 332\r\n" ++
            "\r\n" ++
            "v=0\r\n" ++
            "o=- 1234567890 1234567890 IN IP4 192.168.99.99\r\n" ++
            "s=Digifort Media\r\n" ++
            "c=IN IP4 192.168.99.99\r\n" ++
            "t=0 0\r\n" ++
            "m=video 0 RTP/AVP 96\r\n" ++
            "a=control:rtsp://192.168.99.99:554/Interface/Cameras/Media?Camera=CAM001/trackID=1\r\n" ++
            "a=rtpmap:96 H264/90000\r\n" ++
            "a=fmtp:96 packetization-mode=1; sprop-parameter-sets=Z2QAKa0AxSAtAoabgICA0oAG3dAAzf5gAg==,aO48sA==\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 4\r\n" ++
            "Transport: RTP/AVP/TCP;interleaved=0-1\r\n" ++
            "Session: 12345678\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 5\r\n" ++
            "Session: 12345678\r\n" ++
            "RTP-Info: url=rtsp://192.168.99.99:554/Interface/Cameras/Media?Camera=CAM001/trackID=1;seq=0;rtptime=0\r\n" ++
            "\r\n",
    );
}

test "session live555 digest auth sms100 unicast" {
    try test_stream_request_response(
        "rtsp://100.10.10.10:554/Sms=100.unicast",
        .{ .user = "test", .password = "test" },
        "OPTIONS rtsp://100.10.10.10:554/Sms=100.unicast RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://100.10.10.10:554/Sms=100.unicast RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 2\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://100.10.10.10:554/Sms=100.unicast RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"LIVE555 Streaming Media\",nonce=\"c5b6707025bd9992a00165b2fd3e7e66\",uri=\"rtsp://100.10.10.10:554/Sms=100.unicast\",response=\"4ff62fbfe604d0893d8a74bed60c69d4\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 3\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "SETUP rtsp://127.0.0.1/devType=1&devId=100/1,100_high.unicast/track1 RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"LIVE555 Streaming Media\",nonce=\"c5b6707025bd9992a00165b2fd3e7e66\",uri=\"rtsp://127.0.0.1/devType=1&devId=100/1,100_high.unicast/track1\",response=\"b60492b33eda1e4bb2d67e0116d25a2b\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 4\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "PLAY rtsp://127.0.0.1/devType=1&devId=100/1,100_high.unicast/ RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"LIVE555 Streaming Media\",nonce=\"c5b6707025bd9992a00165b2fd3e7e66\",uri=\"rtsp://127.0.0.1/devType=1&devId=100/1,100_high.unicast/\",response=\"481b91ef5ab5ac408ee99f55b21a6a8b\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 5\r\n" ++
            "Session: 5613CE3D\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n",
        "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 1\r\n" ++
            "Date: Tue, Feb 03 2026 12:09:13 GMT\r\n" ++
            "Public: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER\r\n" ++
            "\r\n" ++
            "RTSP/1.0 401 Unauthorized\r\n" ++
            "CSeq: 2\r\n" ++
            "Date: Tue, Feb 03 2026 12:09:13 GMT\r\n" ++
            "WWW-Authenticate: Digest realm=\"LIVE555 Streaming Media\", nonce=\"c5b6707025bd9992a00165b2fd3e7e66\"\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 3\r\n" ++
            "Date: Tue, Feb 03 2026 12:09:13 GMT\r\n" ++
            "Content-Base: rtsp://127.0.0.1/devType=1&devId=100/1,100_high.unicast/\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Content-Length: 480\r\n" ++
            "\r\n" ++
            "v=0\r\n" ++
            "o=- 1770055367281926 1 IN IP4 192.168.9.99\r\n" ++
            "s=Session streamed by \"ssrtspd\"\r\n" ++
            "i=1,100_high.unicast\r\n" ++
            "t=0 0\r\n" ++
            "a=tool:LIVE555 Streaming Media v9999.00.00\r\n" ++
            "a=type:broadcast\r\n" ++
            "a=control:*\r\n" ++
            "a=range:npt=0-\r\n" ++
            "a=x-qt-text-nam:Session streamed by \"ssrtspd\"\r\n" ++
            "a=x-qt-text-inf:1,100_high.unicast\r\n" ++
            "m=video 0 RTP/AVP 96\r\n" ++
            "c=IN IP4 0.0.0.0\r\n" ++
            "b=AS:500\r\n" ++
            "a=rtpmap:96 H264/90000\r\n" ++
            "a=fmtp:96 packetization-mode=1;profile-level-id=640033;sprop-parameter-sets=Z2QAM6wVFKAoALWQ,aO48sA==\r\n" ++
            "a=control:track1\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 4\r\n" ++
            "Date: Tue, Feb 03 2026 12:09:13 GMT\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;destination=127.0.0.1;source=127.0.0.1;interleaved=0-1\r\n" ++
            "Session: 5613CE3D\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 5\r\n" ++
            "Date: Tue, Feb 03 2026 12:09:13 GMT\r\n" ++
            "Range: npt=8666.057-\r\n" ++
            "Session: 5613CE3D\r\n" ++
            "RTP-Info: url=rtsp://127.0.0.1/1,100_high.unicast/track1;seq=37143;rtptime=3632008373\r\n" ++
            "\r\n",
    );
}

test "session axis gstreamer digest auth" {
    try test_stream_request_response(
        "rtsp://192.168.10.10/axis-media/media.amp",
        .{ .user = "test", .password = "test" },
        "OPTIONS rtsp://192.168.10.10/axis-media/media.amp RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://192.168.10.10/axis-media/media.amp RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 2\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://192.168.10.10/axis-media/media.amp RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"AXIS_000000000000\",nonce=\"0000002eY58201830228ecf0d17659e11c069f0b57392e\",uri=\"rtsp://192.168.10.10/axis-media/media.amp\",response=\"67080f8302a905f39046d8754bb0d1e8\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 3\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "SETUP rtsp://192.168.10.10/axis-media/media.amp/stream=0 RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"AXIS_000000000000\",nonce=\"0000002eY58201830228ecf0d17659e11c069f0b57392e\",uri=\"rtsp://192.168.10.10/axis-media/media.amp/stream=0\",response=\"383b266d24b0be1d3b64024c19a59563\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 4\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "PLAY rtsp://192.168.10.10/axis-media/media.amp RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"AXIS_000000000000\",nonce=\"0000002eY58201830228ecf0d17659e11c069f0b57392e\",uri=\"rtsp://192.168.10.10/axis-media/media.amp\",response=\"aee714276dfdb39cb8b90ddbe02eb715\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 5\r\n" ++
            "Session: y7wDXudGMHMUUMtO\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n",
        "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 1\r\n" ++
            "Public: OPTIONS, DESCRIBE, GET_PARAMETER, PAUSE, PLAY, SETUP, SET_PARAMETER, TEARDOWN\r\n" ++
            "Server: GStreamer RTSP server\r\n" ++
            "Date: Tue, 03 Feb 2026 12:56:54 GMT\r\n" ++
            "\r\n" ++
            "RTSP/1.0 401 Unauthorized\r\n" ++
            "CSeq: 2\r\n" ++
            "WWW-Authenticate: Digest realm=\"AXIS_000000000000\", nonce=\"0000002eY58201830228ecf0d17659e11c069f0b57392e\", stale=FALSE\r\n" ++
            "WWW-Authenticate: Basic realm=\"AXIS_000000000000\"\r\n" ++
            "Server: GStreamer RTSP server\r\n" ++
            "Date: Tue, 03 Feb 2026 12:56:54 GMT\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 3\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Content-Base: rtsp://192.168.10.10/axis-media/media.amp/\r\n" ++
            "Server: GStreamer RTSP server\r\n" ++
            "Date: Tue, 03 Feb 2026 12:56:56 GMT\r\n" ++
            "Content-Length: 860\r\n" ++
            "\r\n" ++
            "v=0\r\n" ++
            "o=- 1188340656180883 1 IN IP4 192.168.10.10\r\n" ++
            "s=Session streamed with GStreamer\r\n" ++
            "i=rtsp-server\r\n" ++
            "t=0 0\r\n" ++
            "a=tool:GStreamer\r\n" ++
            "a=type:broadcast\r\n" ++
            "a=range:npt=now-\r\n" ++
            "a=control:rtsp://192.168.10.10/axis-media/media.amp\r\n" ++
            "m=video 0 RTP/AVP 96\r\n" ++
            "c=IN IP4 0.0.0.0\r\n" ++
            "b=AS:50000\r\n" ++
            "a=rtpmap:96 H264/90000\r\n" ++
            "a=fmtp:96 packetization-mode=1;profile-level-id=4d0029;sprop-parameter-sets=Z00AKeKQDwBE/LgLcBAQGkHiRFQ=,aO48gA==\r\n" ++
            "a=control:rtsp://192.168.10.10/axis-media/media.amp/stream=0\r\n" ++
            "a=framerate:25.000000\r\n" ++
            "a=transform:-1.000000,0.000000,0.000000;0.000000,-1.000000,0.000000;0.000000,0.000000,1.000000\r\n" ++
            "m=audio 0 RTP/AVP 97\r\n" ++
            "c=IN IP4 0.0.0.0\r\n" ++
            "b=AS:32\r\n" ++
            "a=rtpmap:97 MPEG4-GENERIC/8000/1\r\n" ++
            "a=fmtp:97 streamtype=5;profile-level-id=2;mode=AAC-hbr;config=1588;sizelength=13;indexlength=3;indexdeltalength=3;bitrate=32000\r\n" ++
            "a=control:rtsp://192.168.10.10/axis-media/media.amp/stream=1\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 4\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=EF981646;mode=\"PLAY\"\r\n" ++
            "Server: GStreamer RTSP server\r\n" ++
            "Session: y7wDXudGMHMUUMtO; timeout=60\r\n" ++
            "Date: Tue, 03 Feb 2026 12:56:56 GMT\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 5\r\n" ++
            "RTP-Info: url=rtsp://192.168.10.10/axis-media/media.amp/stream=0;seq=12630;rtptime=3971244293\r\n" ++
            "Range: npt=now-\r\n" ++
            "Server: GStreamer RTSP server\r\n" ++
            "Session: y7wDXudGMHMUUMtO; timeout=60\r\n" ++
            "Date: Tue, 03 Feb 2026 12:56:56 GMT\r\n" ++
            "\r\n",
    );
}

test "session digest auth s0" {
    try test_stream_request_response(
        "rtsp://192.168.10.10:554/s0",
        .{ .user = "test", .password = "test" },
        "OPTIONS rtsp://192.168.10.10:554/s0 RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "OPTIONS rtsp://192.168.10.10:554/s0 RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"Please log in with a valid username\",nonce=\"1459175f5bd9528e432f5de06df01d4c\",uri=\"rtsp://192.168.10.10:554/s0\",response=\"e7cc383d1a579155aa33326d4236068a\",algorithm=MD5,opaque=\"\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 2\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://192.168.10.10:554/s0 RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"Please log in with a valid username\",nonce=\"1459175f5bd9528e432f5de06df01d4c\",uri=\"rtsp://192.168.10.10:554/s0\",response=\"e783fcdb6beafca4836bec2992de6184\",algorithm=MD5,opaque=\"\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 3\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "SETUP rtsp://192.168.10.10:554/?s0&stream=video RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"Please log in with a valid username\",nonce=\"1459175f5bd9528e432f5de06df01d4c\",uri=\"rtsp://192.168.10.10:554/?s0&stream=video\",response=\"80a82078739d039569f1310cc51d728d\",algorithm=MD5,opaque=\"\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 4\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "PLAY rtsp://192.168.10.10:554/?s0 RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"Please log in with a valid username\",nonce=\"1459175f5bd9528e432f5de06df01d4c\",uri=\"rtsp://192.168.10.10:554/?s0\",response=\"c69ccca6c8b074b20d324965387c0685\",algorithm=MD5,opaque=\"\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 5\r\n" ++
            "Session: 12340a4c56785c9\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n",
        "RTSP/1.0 401 Unauthorized\r\n" ++
            "CSeq: 1\r\n" ++
            "WWW-Authenticate: Digest realm=\"Please log in with a valid username\",nonce=\"1459175f5bd9528e432f5de06df01d4c\",opaque=\"\",stale=FALSE,algorithm=MD5\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 2\r\n" ++
            "Public: DESCRIBE, SETUP, TEARDOWN, PLAY, SET_PARAMETER, GET_PARAMETER, PAUSE\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 3\r\n" ++
            "Cache-control: no-cache\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Content-Base: rtsp://192.168.10.10:554/\r\n" ++
            "Content-Length: 224\r\n" ++
            "\r\n" ++
            "v=0\r\n" ++
            "o=- 0 0 IN IP4 192.168.10.10\r\n" ++
            "s=LIVE VIEW\r\n" ++
            "c=IN IP4 0.0.0.0\r\n" ++
            "t=0 0\r\n" ++
            "a=control:rtsp://192.168.10.10:554/?s0\r\n" ++
            "m=video 0 RTP/AVP 35\r\n" ++
            "a=rtpmap:35 H264/90000\r\n" ++
            "a=control:rtsp://192.168.10.10:554/?s0&stream=video\r\n" ++
            "a=recvonly\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 4\r\n" ++
            "Session: 12340a4c56785c9;timeout=30\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=0600e01e\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 5\r\n" ++
            "Session: 12340a4c56785c9\r\n" ++
            "\r\n",
    );
}

test "session evostream digest auth s0" {
    try test_stream_request_response(
        "rtsp://192.168.10.10/s0",
        .{ .user = "test", .password = "test" },
        "OPTIONS rtsp://192.168.10.10/s0 RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://192.168.10.10/s0 RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 2\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://192.168.10.10/s0 RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"RTSP UVC G4 Bullet (9BB2)\",nonce=\"cd1c0cd09edf806f29dd17e516d2f7dd\",uri=\"rtsp://192.168.10.10/s0\",response=\"56899cf63f8b4870fb289fe1e601f28a\",algorithm=\"MD5\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 3\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "SETUP rtsp://192.168.10.10/s0/trackID=2 RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"RTSP UVC G4 Bullet (9BB2)\",nonce=\"cd1c0cd09edf806f29dd17e516d2f7dd\",uri=\"rtsp://192.168.10.10/s0/trackID=2\",response=\"875280c63eaf223d85f34ef447ad0a5c\",algorithm=\"MD5\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 4\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "PLAY rtsp://192.168.10.10/s0/ RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"RTSP UVC G4 Bullet (9BB2)\",nonce=\"cd1c0cd09edf806f29dd17e516d2f7dd\",uri=\"rtsp://192.168.10.10/s0/\",response=\"3a9368861b69ecca02659f0d87c5cfa6\",algorithm=\"MD5\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 5\r\n" ++
            "Session: nDNHknc5\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n",
        "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 1\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Date: Sat, 01 Jan 2000 00:00:21 UTC\r\n" ++
            "Expires: Sat, 01 Jan 2000 00:00:21 UTC\r\n" ++
            "Pragma: no-cache\r\n" ++
            "Public: DESCRIBE, OPTIONS, PAUSE, PLAY, SETUP, TEARDOWN, ANNOUNCE, RECORD\r\n" ++
            "Server: EvoStream Media Server (www.evostream.com)\r\n" ++
            "\r\n" ++
            "RTSP/1.0 401 Unauthorized\r\n" ++
            "CSeq: 2\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Date: Sat, 01 Jan 2000 00:00:21 UTC\r\n" ++
            "Expires: Sat, 01 Jan 2000 00:00:21 UTC\r\n" ++
            "Pragma: no-cache\r\n" ++
            "Server: EvoStream Media Server (www.evostream.com)\r\n" ++
            "WWW-Authenticate: Digest realm=\"RTSP UVC G4 Bullet (9BB2)\", nonce=\"cd1c0cd09edf806f29dd17e516d2f7dd\", algorithm=\"MD5\"\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 3\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Content-Base: rtsp://192.168.10.10/s0/\r\n" ++
            "Content-Length: 583\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Date: Sat, 01 Jan 2000 00:00:21 UTC\r\n" ++
            "Expires: Sat, 01 Jan 2000 00:00:21 UTC\r\n" ++
            "Pragma: no-cache\r\n" ++
            "Server: EvoStream Media Server (www.evostream.com)\r\n" ++
            "\r\n" ++
            "v=0\r\n" ++
            "o=- 43 0 IN IP4 192.168.10.10\r\n" ++
            "s=s0\r\n" ++
            "u=www.evostream.com\r\n" ++
            "e=contact@evostream.com\r\n" ++
            "c=IN IP4 192.168.10.10\r\n" ++
            "t=0 0\r\n" ++
            "a=recvonly\r\n" ++
            "a=control:*\r\n" ++
            "a=range:npt=now-\r\n" ++
            "m=audio 0 RTP/AVP 96\r\n" ++
            "a=recvonly\r\n" ++
            "a=rtpmap:96 mpeg4-generic/48000/1\r\n" ++
            "a=control:trackID=1\r\n" ++
            "a=fmtp:96 streamtype=5; profile-level-id=15; mode=AAC-hbr; config=1188; SizeLength=13; IndexLength=3; IndexDeltaLength=3;\r\n" ++
            "m=video 0 RTP/AVP 97\r\n" ++
            "a=recvonly\r\n" ++
            "a=control:trackID=2\r\n" ++
            "a=rtpmap:97 H264/90000\r\n" ++
            "a=fmtp:97 profile-level-id=4d4032; packetization-mode=1; sprop-parameter-sets=Z01AMo2NQBUAX/y4C3AQEBQAAA+gAALuAnaCIRqA,aO44gA==\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 4\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Date: Sat, 01 Jan 2000 00:00:21 UTC\r\n" ++
            "Expires: Sat, 01 Jan 2000 00:00:21 UTC\r\n" ++
            "Pragma: no-cache\r\n" ++
            "Server: EvoStream Media Server (www.evostream.com)\r\n" ++
            "Session: nDNHknc5\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 5\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Date: Sat, 01 Jan 2000 00:00:21 UTC\r\n" ++
            "Expires: Sat, 01 Jan 2000 00:00:21 UTC\r\n" ++
            "Pragma: no-cache\r\n" ++
            "RTP-Info: url=rtsp://192.168.10.10/s0/trackID=2;seq=39547;rtptime=0\r\n" ++
            "Range: npt=now-\r\n" ++
            "Server: EvoStream Media Server (www.evostream.com)\r\n" ++
            "Session: nDNHknc5\r\n" ++
            "\r\n",
    );
}

test "session streaming server digest auth" {
    try test_stream_request_response(
        "rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2",
        .{ .user = "test", .password = "test" },
        "OPTIONS rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2 RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2 RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 2\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2 RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"Streaming Server\",nonce=\"bdbb6157b3534eab0811efb3bc7571d0\",uri=\"rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2\",response=\"31c3cd2bcedef78069778a5d5fde8cee\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 3\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "SETUP rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2/trackID=1 RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"Streaming Server\",nonce=\"bdbb6157b3534eab0811efb3bc7571d0\",uri=\"rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2/trackID=1\",response=\"58968b8609bf982ff181adecae65ce0b\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 4\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "PLAY rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2/ RTSP/1.0\r\n" ++
            "Authorization: Digest username=\"test\",realm=\"Streaming Server\",nonce=\"bdbb6157b3534eab0811efb3bc7571d0\",uri=\"rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2/\",response=\"e736b67497fef9a6ff5296246e0c934f\"\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 5\r\n" ++
            "Session: 38070590126670\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n",
        "RTSP/1.0 200 OK\r\n" ++
            "Server: Streaming Server/1.4.0.0\r\n" ++
            "Cseq: 1\r\n" ++
            "Public: DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE, OPTIONS\r\n" ++
            "\r\n" ++
            "RTSP/1.0 401 Unauthorized\r\n" ++
            "Server: Streaming Server/1.0.0.0\r\n" ++
            "Cseq: 2\r\n" ++
            "WWW-Authenticate: Digest realm=\"Streaming Server\", nonce=\"bdbb6157b3534eab0811efb3bc7571d0\"\r\n" ++
            "WWW-Authenticate: NTLM\r\n" ++
            "WWW-Authenticate: Negotiate\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "Server: Streaming Server/1.4.0.0\r\n" ++
            "Cseq: 3\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Content-length: 517\r\n" ++
            "Date: Tue, 03 Feb 2026 12:23:11 GMT\r\n" ++
            "Expires: Tue, 03 Feb 2026 12:23:11 GMT\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "x-Accept-Retransmit: our-retransmit\r\n" ++
            "x-Accept-Dynamic-Rate: 1\r\n" ++
            "Content-Base: rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2/\r\n" ++
            "\r\n" ++
            "v=0\r\n" ++
            "o=RTSP 2056818783 2464230593 IN IP4 0.0.0.0\r\n" ++
            "s=RTSP server\r\n" ++
            "c=IN IP4 0.0.0.0\r\n" ++
            "t=0 0\r\n" ++
            "a=control:*\r\n" ++
            "a=etag:1234567890\r\n" ++
            "a=range:npt=0-\r\n" ++
            "a=control:*\r\n" ++
            "m=video 0 RTP/AVP 98\r\n" ++
            "a=control:trackID=1\r\n" ++
            "b=AS:0\r\n" ++
            "a=rtpmap:98 H264/90000\r\n" ++
            "a=fmtp:98 packetization-mode=1;profile-level-id=4d001f;sprop-parameter-sets=Z00AH+kAoAt0IAAAfSAAF3YAgA==,aOqPIA==\r\n" ++
            "m=application 0 RTP/AVP 107\r\n" ++
            "a=control:trackID=3\r\n" ++
            "a=rtpmap:107 vnd.onvif.metadata/90000\r\n" ++
            "m=application 0 RTP/AVP 108\r\n" ++
            "a=control:trackID=4\r\n" ++
            "a=rtpmap:108 vnd.vivotek.metj/90000\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "Server: Streaming Server/1.4.0.0\r\n" ++
            "Cseq: 4\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Session: 38070590126670\r\n" ++
            "Date: Tue, 03 Feb 2026 12:23:11 GMT\r\n" ++
            "Expires: Tue, 03 Feb 2026 12:23:11 GMT\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "Server: Streaming Server/1.4.0.0\r\n" ++
            "Cseq: 5\r\n" ++
            "Session: 38070590126670\r\n" ++
            "Range: npt=0-\r\n" ++
            "RTP-Info: url=rtsp://100.10.9.99:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_99&streamindex=2/trackID=1;seq=63496;rtptime=622795500\r\n" ++
            "\r\n",
    );
}

test "session ui media server selects video track as aggregate" {
    try test_stream_request_response(
        "rtsp://192.168.10.1:7447/dummy",
        null,
        "OPTIONS rtsp://192.168.10.1:7447/dummy RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "DESCRIBE rtsp://192.168.10.1:7447/dummy RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 2\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "SETUP rtsp://192.168.10.1:7447/dummy/trackID=2 RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 3\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n" ++
            "PLAY rtsp://192.168.10.1:7447/dummy/ RTSP/1.0\r\n" ++
            "Content-Length: 0\r\n" ++
            "CSeq: 4\r\n" ++
            "Session: 0N9VbSBs\r\n" ++
            "User-Agent: rtspkit/1.0\r\n" ++
            "\r\n",
        "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 1\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Date: Thu, 05 Feb 2026 15:19:44 UTC\r\n" ++
            "Expires: Thu, 05 Feb 2026 15:19:44 UTC\r\n" ++
            "Pragma: no-cache\r\n" ++
            "Public: DESCRIBE, OPTIONS, PAUSE, PLAY, SETUP, TEARDOWN, ANNOUNCE, RECORD\r\n" ++
            "Server: Media Server (www.ui.com)\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 2\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Content-Base: rtsp://192.168.10.1:7447/dummy/\r\n" ++
            "Content-Length: 655\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Date: Thu, 05 Feb 2026 15:19:44 UTC\r\n" ++
            "Expires: Thu, 05 Feb 2026 15:19:44 UTC\r\n" ++
            "Pragma: no-cache\r\n" ++
            "Server: Media Server (www.ui.com)\r\n" ++
            "\r\n" ++
            "v=0\r\n" ++
            "o=- 1363 0 IN IP4 192.168.10.1\r\n" ++
            "s=000000000000_1\r\n" ++
            "u=www.ui.com\r\n" ++
            "e=info@ui.com\r\n" ++
            "c=IN IP4 192.168.10.1\r\n" ++
            "t=0 0\r\n" ++
            "a=recvonly\r\n" ++
            "a=control:*\r\n" ++
            "a=range:npt=now-\r\n" ++
            "m=audio 0 RTP/AVP 96\r\n" ++
            "a=recvonly\r\n" ++
            "a=rtpmap:96 mpeg4-generic/16000/1\r\n" ++
            "a=control:trackID=0\r\n" ++
            "a=fmtp:96 streamtype=5; profile-level-id=15; mode=AAC-hbr; config=1408; SizeLength=13; IndexLength=3; IndexDeltaLength=3;\r\n" ++
            "m=audio 0 RTP/AVP 96\r\n" ++
            "a=recvonly\r\n" ++
            "a=rtpmap:96 opus/48000/2\r\n" ++
            "a=control:trackID=1\r\n" ++
            "m=video 0 RTP/AVP 97\r\n" ++
            "a=recvonly\r\n" ++
            "a=control:trackID=2\r\n" ++
            "a=rtpmap:97 H264/90000\r\n" ++
            "a=fmtp:97 profile-level-id=4d401f; packetization-mode=1; sprop-parameter-sets=Z01AH6aAUAW6bgICAoAAAfSAAHVOTtBEI1A=,aOqPIA==\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 3\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Date: Thu, 05 Feb 2026 15:19:44 UTC\r\n" ++
            "Expires: Thu, 05 Feb 2026 15:19:44 UTC\r\n" ++
            "Pragma: no-cache\r\n" ++
            "Server: Media Server (www.ui.com)\r\n" ++
            "Session: 0N9VbSBs\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "\r\n" ++
            "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 4\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Date: Thu, 05 Feb 2026 15:19:44 UTC\r\n" ++
            "Expires: Thu, 05 Feb 2026 15:19:44 UTC\r\n" ++
            "Pragma: no-cache\r\n" ++
            "RTP-Info: url=rtsp://192.168.10.1:7447/dummy/trackID=2;seq=42817;rtptime=0\r\n" ++
            "Range: npt=now-\r\n" ++
            "Server: Media Server (www.ui.com)\r\n" ++
            "Session: 0N9VbSBs\r\n" ++
            "\r\n",
    );
}
