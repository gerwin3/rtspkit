const std = @import("std");
const rtsp = @import("../rtsp.zig");
const Version = rtsp.Version;
const Status = rtsp.Status;

pub const Response = @This();

head: Head,
body: []const u8 = &.{},

pub const Head = struct {
    status: Status,
    version: Version,

    connection: ?enum { keep_alive, close } = null,
    content_base: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    content_language: ?[]const u8 = null,
    content_length: ?usize = null,
    content_type: ?[]const u8 = null,
    cseq: ?usize = null,
    public: ?[]const u8 = null,
    range: ?[]const u8 = null,
    rtp_info: ?[]const u8 = null,
    session: ?[]const u8 = null,
    transport: ?[]const u8 = null,
    www_authenticate_basic: ?[]const u8 = null,
    www_authenticate_digest: ?[]const u8 = null,

    pub const ParseError = error{
        UnsupportedVersion,
        MissingStatusCode,
        InvalidStatusCode,
        InvalidHeader,
        InvalidHeaderConnection,
        InvalidHeaderContentLength,
        InvalidHeaderCSeq,
        MissingHeaderCSeq,
    };

    pub fn parse(head: *Head, buffer: []const u8) ParseError!void {
        var lines = std.mem.splitSequence(u8, buffer, "\r\n");

        var first_line_parts = std.mem.splitSequence(u8, lines.first(), " ");
        const version: Version = if (std.mem.eql(u8, first_line_parts.first(), "RTSP/1.0")) .@"1.0" else return ParseError.UnsupportedVersion;
        const status_code = first_line_parts.next() orelse return ParseError.MissingStatusCode;
        const status: Status = @enumFromInt(std.fmt.parseInt(u16, status_code, 10) catch return ParseError.InvalidStatusCode);

        head.* = Head{ .version = version, .status = status };

        while (lines.next()) |line| {
            var key_val_iter = std.mem.splitScalar(u8, line, ':');
            const key = key_val_iter.first();
            const val = std.mem.trim(u8, key_val_iter.rest(), " \t");
            if (std.ascii.eqlIgnoreCase(key, "connection"))
                head.connection = if (std.ascii.eqlIgnoreCase(val, "keep-alive"))
                    .keep_alive
                else if (std.ascii.eqlIgnoreCase(val, "close"))
                    .close
                else
                    return ParseError.InvalidHeaderConnection
            else if (std.ascii.eqlIgnoreCase(key, "content-base"))
                head.content_base = val
            else if (std.ascii.eqlIgnoreCase(key, "content-encoding"))
                head.content_encoding = val
            else if (std.ascii.eqlIgnoreCase(key, "content-language"))
                head.content_language = val
            else if (std.ascii.eqlIgnoreCase(key, "content-length"))
                head.content_length = std.fmt.parseInt(usize, val, 10) catch return ParseError.InvalidHeaderContentLength
            else if (std.ascii.eqlIgnoreCase(key, "content-type"))
                head.content_type = val
            else if (std.ascii.eqlIgnoreCase(key, "cseq"))
                head.cseq = std.fmt.parseInt(usize, val, 10) catch return ParseError.InvalidHeaderCSeq
            else if (std.ascii.eqlIgnoreCase(key, "public"))
                head.public = val
            else if (std.ascii.eqlIgnoreCase(key, "range"))
                head.range = val
            else if (std.ascii.eqlIgnoreCase(key, "rtp-info"))
                head.rtp_info = val
            else if (std.ascii.eqlIgnoreCase(key, "session"))
                head.session = val
            else if (std.ascii.eqlIgnoreCase(key, "transport"))
                head.transport = val
            else if (std.ascii.eqlIgnoreCase(key, "www-authenticate") and std.mem.startsWith(u8, val, "Basic "))
                head.www_authenticate_basic = val
            else if (std.ascii.eqlIgnoreCase(key, "www-authenticate") and std.mem.startsWith(u8, val, "Digest "))
                head.www_authenticate_digest = val;
        }

        if (head.status == .ok and head.cseq == null) return ParseError.MissingHeaderCSeq;
    }
};
