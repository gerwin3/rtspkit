const std = @import("std");
const rtsp = @import("../rtsp.zig");
const Version = rtsp.Version;
const Transport = rtsp.Transport;

pub const Request = @This();

method: Method,
target: []const u8,
version: Version = .@"1.0",
accept: ?[]const u8 = null,
cseq: u32,
session: ?[]const u8 = null,
transport: ?Transport = null,
authorization: ?[]const u8 = null,
content_type: ?[]const u8 = null,
user_agent: []const u8,
body: []const u8 = &.{},

pub const Method = enum {
    describe,
    announce,
    get_parameter,
    options,
    pause,
    play,
    record,
    redirect,
    setup,
    set_parameter,
    teardown,

    pub inline fn as_slice(self: Method) []const u8 {
        return switch (self) {
            .describe => "DESCRIBE",
            .announce => "ANNOUNCE",
            .get_parameter => "GET_PARAMETER",
            .options => "OPTIONS",
            .pause => "PAUSE",
            .play => "PLAY",
            .record => "RECORD",
            .redirect => "REDIRECT",
            .setup => "SETUP",
            .set_parameter => "SET_PARAMETER",
            .teardown => "TEARDOWN",
        };
    }
};

pub fn write(self: *const Request, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(self.method.as_slice());
    try writer.writeAll(" ");
    try writer.writeAll(self.target);
    try writer.writeAll(" ");
    try writer.writeAll(switch (self.version) {
        .@"1.0" => "RTSP/1.0",
    });
    try writer.writeAll("\r\n");

    if (self.accept) |accept| {
        try writer.writeAll("Accept: ");
        try writer.writeAll(accept);
        try writer.writeAll("\r\n");
    }

    if (self.authorization) |authorization| {
        try writer.writeAll("Authorization: ");
        try writer.writeAll(authorization);
        try writer.writeAll("\r\n");
    }

    if (self.content_type) |content_type| {
        try writer.writeAll("Content-Type: ");
        try writer.writeAll(content_type);
        try writer.writeAll("\r\n");
    }

    try writer.print("Content-Length: {d}\r\n", .{self.body.len});
    try writer.print("CSeq: {d}\r\n", .{self.cseq});

    if (self.session) |session| {
        try writer.writeAll("Session: ");
        try writer.writeAll(session);
        try writer.writeAll("\r\n");
    }

    if (self.transport) |transport| {
        try writer.writeAll("Transport: ");
        try transport.write(writer);
        try writer.writeAll("\r\n");
    }

    try writer.writeAll("User-Agent: ");
    try writer.writeAll(self.user_agent);
    try writer.writeAll("\r\n");
    try writer.writeAll("\r\n");
    try writer.writeAll(self.body);
}

test "write" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try (Request{
        .method = .setup,
        .target = "rtsp://example.com/stream/trackID=1",
        .accept = "application/sdp",
        .cseq = 7,
        .session = "12345678",
        .transport = .{
            .lower = .tcp,
            .mode = .unicast,
            .interleaved = .{
                .channel_rtp = 0,
                .channel_rtcp = 1,
            },
        },
        .authorization = "Digest username=\"alice\"",
        .content_type = "application/sdp",
        .user_agent = "rtspkit-test",
        .body = "v=0\r\n",
    }).write(&writer.writer);

    try std.testing.expectEqualStrings(
        "SETUP rtsp://example.com/stream/trackID=1 RTSP/1.0\r\n" ++
            "Accept: application/sdp\r\n" ++
            "Authorization: Digest username=\"alice\"\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Content-Length: 5\r\n" ++
            "CSeq: 7\r\n" ++
            "Session: 12345678\r\n" ++
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n" ++
            "User-Agent: rtspkit-test\r\n" ++
            "\r\n" ++
            "v=0\r\n",
        writer.written(),
    );
}
