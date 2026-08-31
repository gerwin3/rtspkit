const std = @import("std");
const Codec = @import("../codec.zig").Codec;
const sdp = @import("../sdp.zig");
const Attribute = sdp.Attribute;
const Parser = sdp.Parser;

pub const Selector = @This();

parser: *Parser,
codecs: []const Codec,

state: struct {
    aggregate_control: ?Attribute.Control = null,

    media: union(enum) {
        none,
        other,
        rtp_avp_video: struct {
            payload_type: u8,
            format_parameters: ?Attribute.Fmtp.FormatParameters = null,
            codec_info: ?Attribute.RtpMap = null,
            control: ?Attribute.Control = null,
        },
    } = .none,

    selected_media: ?Media = null,
    selected_media_codec_index: usize = std.math.maxInt(usize),
} = .{},

pub const Media = struct {
    codec: Codec,
    payload_type: u8,
    format_parameters: ?Attribute.Fmtp.FormatParameters,
    clock_rate: u32,
    control: ?Attribute.Control,
    aggregate_control: ?Attribute.Control,
};

pub fn select(self: *Selector) Parser.ParseError!?Media {
    while (try self.parser.next()) |item| {
        switch (item) {
            .version => {},
            .media => |media| {
                _ = self.flush();

                self.state.media = switch (media.kind) {
                    .video => switch (media.protocol) {
                        .@"RTP/AVP" => .{
                            .rtp_avp_video = .{
                                .payload_type = media.payload_type orelse return Parser.ParseError.Malformed,
                            },
                        },
                        else => .other,
                    },
                    else => .other,
                };
            },
            .attribute => |attribute| switch (self.state.media) {
                .none => switch (attribute) {
                    .control => |control| {
                        self.state.aggregate_control = control;
                    },
                    else => {},
                },
                .other => {},
                .rtp_avp_video => |candidate| {
                    var next_candidate = candidate;

                    switch (attribute) {
                        .control => |control| {
                            next_candidate.control = control;
                        },
                        .fmtp => |fmtp| {
                            if (fmtp.payload_type == next_candidate.payload_type) {
                                next_candidate.format_parameters = fmtp.parameters;
                            }
                        },
                        .rtpmap => |rtpmap| {
                            if (rtpmap.payload_type == next_candidate.payload_type) {
                                next_candidate.codec_info = rtpmap;
                            }
                        },
                    }

                    self.state.media = .{ .rtp_avp_video = next_candidate };
                },
            },
        }
    }

    _ = self.flush();

    return self.state.selected_media;
}

fn flush(self: *Selector) ?Media {
    const candidate = switch (self.state.media) {
        .rtp_avp_video => |candidate| candidate,
        else => return null,
    };

    const codec_info = candidate.codec_info orelse return null;
    const codec_index = std.mem.indexOfScalar(Codec, self.codecs, codec_info.codec) orelse return null;
    if (codec_index >= self.state.selected_media_codec_index) return null;

    self.state.selected_media_codec_index = codec_index;
    self.state.selected_media = .{
        .codec = codec_info.codec,
        .payload_type = candidate.payload_type,
        .format_parameters = candidate.format_parameters,
        .clock_rate = codec_info.clock_rate,
        .control = candidate.control,
        .aggregate_control = self.state.aggregate_control,
    };

    return self.state.selected_media;
}

inline fn expect_selected_media(
    buffer: []const u8,
    preferred_codecs: []const Codec,
    expected: *const Media,
) !void {
    var parser = Parser{ .buffer = buffer };
    var selector = Selector{
        .parser = &parser,
        .codecs = preferred_codecs,
    };
    try std.testing.expectEqualDeep(expected.*, try selector.select());
}

inline fn expect_parse_error(
    buffer: []const u8,
    preferred_codecs: []const Codec,
    expected_error: anyerror,
) !void {
    var parser = Parser{ .buffer = buffer };
    var selector = Selector{
        .parser = &parser,
        .codecs = preferred_codecs,
    };
    try std.testing.expectError(expected_error, selector.select());
}

test "rfc 6871 sample 1" {
    try expect_selected_media(
        \\v=0
        \\o=- 24351 621814 IN IP4 192.0.2.2
        \\s=
        \\c=IN IP4 192.0.2.2
        \\t=0 0
        \\a=rmcap:1 L16/8000/1
        \\a=rmcap:2 L16/16000/2
        \\a=rmcap:3 H263-1998/90000
        \\a=omcap:4 example
        \\m=audio 54320 RTP/AVP 0
        \\a=pcfg:1 m=1|2, pt=1:99,2:98
        \\m=video 66544 RTP/AVP 100
        \\a=rtpmap:100 H264/90000
        \\a=pcfg:10 m=3 pt=3:101
        \\a=tcap:1 TCP
        \\a=pcfg:11 m=4 t=1
    ,
        &.{.h264},
        &.{
            .codec = .h264,
            .payload_type = 100,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = null,
            .aggregate_control = null,
        },
    );
}

test "rfc 6871 sample 2" {
    try expect_selected_media(
        \\v=0
        \\o=- 25678 753849 IN IP4 192.0.2.1
        \\s=
        \\c=IN IP4 192.0.2.22
        \\t=0 0
        \\a=csup:med-v0
        \\a=sescap:1 1,4
        \\m=audio 23456 RTP/AVP 0
        \\a=rtpmap:0 PCMU/8000
        \\a=acfg:1
        \\m=video 41234 RTP/AVP 104
        \\a=rtpmap:104 H264/90000
        \\a=fmtp:104 profile-level-id=42A01E; packetization-mode=2
        \\a=acfg:4 m=1 a=1 pt=1:104
        \\m=video 0 RTP/AVP 103
        \\a=acfg:3
        \\m=application 0 TCP/BFCP *
        \\a=acfg:5
    ,
        &.{.h264},
        &.{
            .codec = .h264,
            .payload_type = 104,
            .format_parameters = .{
                .packetization_mode = 2,
                .profile_level_id = "42A01E",
            },
            .clock_rate = 90000,
            .control = null,
            .aggregate_control = null,
        },
    );
}

test "rfc 6871 sample 3" {
    try expect_selected_media(
        \\v=0
        \\o=- 25678 753849 IN IP4 192.0.2.1
        \\s=An SDP Media NEG example
        \\c=IN IP4 192.0.2.1
        \\t=0 0
        \\a=creq:med-v0
        \\a=ice-pwd:speEc3QGZiNWpVLFJhQX
        \\m=video 49170 RTP/AVP 100
        \\c=IN IP4 192.0.2.56
        \\a=maxprate:1000
        \\a=rtcp:51540
        \\a=sendonly
        \\a=candidate 12345 1 UDP 9 192.0.2.56 49170 host
        \\a=candidate 23456 2 UDP 9 192.0.2.56 51540 host
        \\a=candidate 34567 1 UDP 7 198.51.100.1 41345 srflx raddr 192.0.2.56 rport 49170
        \\a=candidate 45678 2 UDP 7 198.51.100.1 52567 srflx raddr 192.0.2.56 rport 51540
        \\a=candidate 56789 1 UDP 3 192.0.2.100 49000 relay raddr 192.0.2.56 rport 49170
        \\a=candidate 67890 2 UDP 3 192.0.2.100 49001 relay raddr 192.0.2.56 rport 51540
        \\b=AS:10000
        \\b=TIAS:10000000
        \\b=RR:4000
        \\b=RS:3000
        \\a=rtpmap:100 H264/90000
        \\a=fmtp:100 profile-level-id=42A01E; packetization-mode=2; sprop-parameter-sets=Z0IACpZTBYmI,aMljiA==; sprop-interleaving-depth=45; sprop-deint-buf-req=64000; sprop-init-buf-time=102478; deint-buf-cap=128000
        \\a=tcap:1 RTP/SAVPF RTP/SAVP RTP/AVPF
        \\a=rmcap:1-3,7-9 H264/90000
        \\a=rmcap:4-6 rtx/90000
        \\a=mfcap:1-9 profile-level-id=42A01E
        \\a=mfcap:1-9 aMljiA==
        \\a=mfcap:1,4,7 packetization-mode=0
        \\a=mfcap:2,5,8 packetization-mode=1
        \\a=mfcap:3,6,9 packetization-mode=2
        \\a=mfcap:1-9 sprop-parameter-sets=Z0IACpZTBYmI
        \\a=mfcap:1,7 sprop-interleaving-depth=45; sprop-deint-buf-req=64000; sprop-init-buf-time=102478; deint-buf-cap=128000
        \\a=mfcap:4 apt=100
        \\a=mfcap:5 apt=99
        \\a=mfcap:6 apt=98
        \\a=mfcap:4-6 rtx-time=3000
        \\a=mscap:1-6 rtcp-fb nack
        \\a=acap:1 crypto:1 AES_CM_128_HMAC_SHA1_80 inline:d0RmdmcmVCspeEc3QGZiNWpVLFJhQX1cfHAwJSoj|220|1:32
        \\a=pcfg:1 t=1 m=1,4 a=1 pt=1:100,4:97
        \\a=pcfg:2 t=1 m=2,5 a=1 pt=2:99,4:96
        \\a=pcfg:3 t=1 m=3,6 a=1 pt=3:98,6:95
        \\a=pcfg:4 t=2 m=7 a=1 pt=7:100
        \\a=pcfg:5 t=2 m=8 a=1 pt=8:99
        \\a=pcfg:6 t=2 m=9 a=1 pt=9:98
        \\a=pcfg:7 t=3 m=1,3 pt=1:100,4:97
        \\a=pcfg:8 t=3 m=2,4 pt=2:99,4:96
        \\a=pcfg:9 t=3 m=3,6 pt=3:98,6:95
        \\m=audio 49176 RTP/AVP 101 100 99 98
        \\c=IN IP4 192.0.2.56
        \\a=ptime:60
        \\a=maxptime:200
        \\a=rtcp:51534
        \\a=sendonly
        \\a=candidate 12345 1 UDP 9 192.0.2.56 49176 host
        \\a=candidate 23456 2 UDP 9 192.0.2.56 51534 host
        \\a=candidate 34567 1 UDP 7 198.51.100.1 41348 srflx raddr 192.0.2.56 rport 49176
        \\a=candidate 45678 2 UDP 7 198.51.100.1 52569 srflx raddr 192.0.2.56 rport 51534
        \\a=candidate 56789 1 UDP 3 192.0.2.100 49002 relay raddr 192.0.2.56 rport 49176
        \\a=candidate 67890 2 UDP 3 192.0.2.100 49003 relay raddr 192.0.2.56 rport 51534
        \\b=AS:512
        \\b=TIAS:512000
        \\b=RR:4000
        \\b=RS:3000
        \\a=maxprate:120
        \\a=rtpmap:98 AMR-WB/16000
        \\a=fmtp:98 octet-align=1; mode-change-capability=2
        \\a=rtpmap:99 AMR-WB/16000
        \\a=fmtp:99 octet-align=1; crc=1; mode-change-capability=2
        \\a=rtpmap:100 AMR-WB/16000/2
        \\a=fmtp:100 octet-align=1; interleaving=30
        \\a=rtpmap:101 AMR-WB+/72000/2
        \\a=fmtp:101 interleaving=50; int-delay=160000;
        \\a=rmcap:14 ac3/48000/6
        \\a=acap:23 crypto:1 AES_CM_128_HMAC_SHA1_80 inline:d0RmdmcmVCspeEc3QGZiNWpVLFJhQX1cfHAwJSoj|220|1:32
        \\a=tcap:4 RTP/SAVP
        \\a=pcfg:10 t=4 a=23
        \\a=pcfg:11 t=4 m=14 a=23 pt=14:102
    ,
        &.{.h264},
        &.{
            .codec = .h264,
            .payload_type = 100,
            .format_parameters = .{
                .packetization_mode = 2,
                .profile_level_id = "42A01E",
                .parameter_sets = .{
                    .sps = "Z0IACpZTBYmI",
                    .pps = "aMljiA==",
                },
            },
            .clock_rate = 90000,
            .control = null,
            .aggregate_control = null,
        },
    );
}

test "custom sample 1" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 1 RTP/AVP 101
        \\a=rtpmap:101 H264/90000
        \\a=control:trackID=123
    ,
        &.{.h264},
        &.{
            .codec = .h264,
            .payload_type = 101,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=123" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "custom sample fmtp sprop parameter sets two values end to end" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 1 RTP/AVP 101
        \\a=rtpmap:101 H264/90000
        \\a=fmtp:101 profile-level-id=42A01E; sprop-parameter-sets=Z0IACpZTBYmI,aMljiA==
        \\a=control:trackID=123
    ,
        &.{.h264},
        &.{
            .codec = .h264,
            .payload_type = 101,
            .format_parameters = .{
                .profile_level_id = "42A01E",
                .parameter_sets = .{
                    .sps = "Z0IACpZTBYmI",
                    .pps = "aMljiA==",
                },
            },
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=123" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "custom sample fmtp sprop parameter sets three values end to end" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 1 RTP/AVP 101
        \\a=rtpmap:101 H265/90000
        \\a=fmtp:101 sprop-parameter-sets=vpsb64,spsb64,ppsb64
        \\a=control:trackID=hev1
    ,
        &.{.h265},
        &.{
            .codec = .h265,
            .payload_type = 101,
            .format_parameters = .{
                .parameter_sets = .{
                    .vps = "vpsb64",
                    .sps = "spsb64",
                    .pps = "ppsb64",
                },
            },
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=hev1" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "custom sample fmtp individual sprop vps sps pps end to end" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 1 RTP/AVP 101
        \\a=rtpmap:101 H265/90000
        \\a=fmtp:101 sprop-vps=vps123; sprop-sps=sps456; sprop-pps=pps789
        \\a=control:trackID=hev1
    ,
        &.{.h265},
        &.{
            .codec = .h265,
            .payload_type = 101,
            .format_parameters = .{
                .parameter_sets = .{
                    .vps = "vps123",
                    .sps = "sps456",
                    .pps = "pps789",
                },
            },
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=hev1" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "custom sample fmtp applies only when payload type matches selected format" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 1 RTP/AVP 101
        \\a=rtpmap:101 H264/90000
        \\a=fmtp:102 sprop-parameter-sets=Z0IACpZTBYmI,aMljiA==
        \\a=control:trackID=123
    ,
        &.{.h264},
        &.{
            .codec = .h264,
            .payload_type = 101,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=123" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "custom sample codec preference selects h265 and keeps its sprops" {
    try expect_selected_media(
        \\v=0
        \\   a=control:*
        \\   m=video 1 RTP/AVP 96
        \\   a=rtpmap:96 H264/90000
        \\   a=fmtp:96 sprop-parameter-sets=Z0IACpZTBYmI,aMljiA==
        \\   a=control:trackID=h264
        \\   m=video 1 RTP/AVP 97
        \\   a=rtpmap:97 H265/90000
        \\   a=fmtp:97 sprop-vps=vpsX; sprop-sps=spsY; sprop-pps=ppsZ
        \\   a=control:trackID=h265
    ,
        &.{ .h265, .h264 },
        &.{
            .codec = .h265,
            .payload_type = 97,
            .format_parameters = .{
                .parameter_sets = .{
                    .vps = "vpsX",
                    .sps = "spsY",
                    .pps = "ppsZ",
                },
            },
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=h265" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "custom sample malformed sprop parameter sets bubbles error end to end" {
    try expect_parse_error(
        \\v=0
        \\   m=video 1 RTP/AVP 101
        \\   a=rtpmap:101 H264/90000
        \\   a=fmtp:101 sprop-parameter-sets=only-one
    ,
        &.{.h264},
        Parser.ParseError.Malformed,
    );
}

test "multi track some video rtp avp control uri" {
    try expect_selected_media(
        \\v=0
        \\o=- 0 0 IN IP4 127.0.0.1
        \\s=
        \\c=IN IP4 127.0.0.1
        \\t=0 0
        \\a=control:rtsp://example.com/stream/
        \\m=audio 0 RTP/AVP 0
        \\a=rtpmap:0 PCMU/8000
        \\a=control:trackID=1
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=control:trackID=2
        \\m=application 0 TCP/BFCP *
        \\a=control:trackID=3
    ,
        &.{.h264},
        &.{
            .codec = .h264,
            .payload_type = 96,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=2" },
            .aggregate_control = .{ .uri = "rtsp://example.com/stream/" },
        },
    );
}

test "some but not all tracks video rtp avp control and aggregate" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=application 0 TCP/BFCP *
        \\a=control:trackID=bfcp
        \\m=audio 0 RTP/AVP 0
        \\a=rtpmap:0 PCMU/8000
        \\a=control:trackID=audio
        \\m=video 0 RTP/AVP 102
        \\a=rtpmap:102 H264/90000
        \\a=control:trackID=video
    ,
        &.{.h264},
        &.{
            .codec = .h264,
            .payload_type = 102,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=video" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "multi video mixed profiles selects rtp avp video track" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 0 RTP/AVPF 96
        \\a=rtpmap:96 H264/90000
        \\a=control:trackID=video-avpf
        \\m=audio 0 RTP/AVP 0
        \\a=rtpmap:0 PCMU/8000
        \\a=control:trackID=audio
        \\m=video 0 RTP/AVP 101
        \\a=rtpmap:101 H264/90000
        \\a=control:trackID=video-avp
    ,
        &.{.h264},
        &.{
            .codec = .h264,
            .payload_type = 101,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=video-avp" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "video avp without media control still parses aggregate" {
    try expect_selected_media(
        \\v=0
        \\a=control:rtsp://example.com/agg
        \\m=video 0 RTP/AVP 100
        \\a=rtpmap:100 H264/90000
    ,
        &.{.h264},
        &.{
            .codec = .h264,
            .payload_type = 100,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = null,
            .aggregate_control = .{ .uri = "rtsp://example.com/agg" },
        },
    );
}

test "none are rtp avp returns err" {
    var parser = Parser{ .buffer =
        \\v=0
        \\a=control:rtsp://example.com/stream/
        \\m=audio 0 RTP/SAVPF 0
        \\a=rtpmap:0 PCMU/8000
        \\a=control:trackID=1
        \\m=video 0 RTP/AVPF 96
        \\a=rtpmap:96 H264/90000
        \\a=control:trackID=2
    };
    var selector = Selector{
        .parser = &parser,
        .codecs = &.{.h264},
    };
    try std.testing.expectEqual(null, try selector.select());
}

test "prefer h265 over h264 when both present" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=control:trackID=h264
        \\m=video 0 RTP/AVP 97
        \\a=rtpmap:97 H265/90000
        \\a=control:trackID=h265
    ,
        &.{ .h265, .h264 },
        &.{
            .codec = .h265,
            .payload_type = 97,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=h265" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "prefer h264 over h265 when order says so" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=control:trackID=h264
        \\m=video 0 RTP/AVP 97
        \\a=rtpmap:97 H265/90000
        \\a=control:trackID=h265
    ,
        &.{ .h264, .h265 },
        &.{
            .codec = .h264,
            .payload_type = 96,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=h264" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "multiple same codec selects first occurrence of that codec" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 0 RTP/AVP 97
        \\a=rtpmap:97 H265/90000
        \\a=control:trackID=h265-1
        \\m=video 0 RTP/AVP 98
        \\a=rtpmap:98 H265/90000
        \\a=control:trackID=h265-2
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=control:trackID=h264
    ,
        &.{ .h265, .h264 },
        &.{
            .codec = .h265,
            .payload_type = 97,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=h265-1" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "h265 present but not rtp avp is ignored so h264 avp selected" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 0 RTP/AVPF 97
        \\a=rtpmap:97 H265/90000
        \\a=control:trackID=h265-avpf
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=control:trackID=h264-avp
    ,
        &.{ .h265, .h264 },
        &.{
            .codec = .h264,
            .payload_type = 96,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=h264-avp" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "preferred codec missing returns err" {
    var parser = Parser{ .buffer =
        \\v=0
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
    };
    var selector = Selector{
        .parser = &parser,
        .codecs = &.{.h265},
    };
    try std.testing.expectEqual(null, try selector.select());
}

test "selects h265 even if h264 appears first" {
    try expect_selected_media(
        \\v=0
        \\a=control:rtsp://example.com/agg
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=control:trackID=h264
        \\m=audio 0 RTP/AVP 0
        \\a=rtpmap:0 PCMU/8000
        \\m=video 0 RTP/AVP 97
        \\a=rtpmap:97 H265/90000
        \\a=control:trackID=h265
    ,
        &.{ .h265, .h264 },
        &.{
            .codec = .h265,
            .payload_type = 97,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=h265" },
            .aggregate_control = .{ .uri = "rtsp://example.com/agg" },
        },
    );
}

test "missing rtpmap for higher priority codec falls back to lower priority" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 0 RTP/AVP 97
        \\a=control:trackID=h265-missing-rtpmap
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=control:trackID=h264
    ,
        &.{ .h265, .h264 },
        &.{
            .codec = .h264,
            .payload_type = 96,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=h264" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "fmtp associated with selected payload only" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=fmtp:96 profile-level-id=42A01E
        \\a=control:trackID=h264
        \\m=video 0 RTP/AVP 97
        \\a=rtpmap:97 H265/90000
        \\a=fmtp:97 profile-level-id=1
        \\a=control:trackID=h265
    ,
        &.{ .h265, .h264 },
        &.{
            .codec = .h265,
            .payload_type = 97,
            .format_parameters = .{
                .profile_level_id = "1",
            },
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=h265" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}

test "multiple h264 tracks prefers h264 and picks first h264 track" {
    try expect_selected_media(
        \\v=0
        \\a=control:*
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=control:trackID=h264-1
        \\m=video 0 RTP/AVP 97
        \\a=rtpmap:97 H265/90000
        \\a=control:trackID=h265
        \\m=video 0 RTP/AVP 98
        \\a=rtpmap:98 H264/90000
        \\a=control:trackID=h264-2
    ,
        &.{ .h264, .h265 },
        &.{
            .codec = .h264,
            .payload_type = 96,
            .format_parameters = null,
            .clock_rate = 90000,
            .control = .{ .uri = "trackID=h264-1" },
            .aggregate_control = .{ .uri = "*" },
        },
    );
}
