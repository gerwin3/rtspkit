const std = @import("std");

const media = @import("media");
const rtsp = media.rtsp;

const Target = @This();

const RTSP_SCHEME: []const u8 = "rtsp";
const RTSP_PORT: u16 = 554;

uri: std.Uri,
host_buffer: []u8,
host: std.Io.net.HostName,
port: u16,
user_buffer: []u8,
password_buffer: []u8,
credentials: ?rtsp.Session.Credentials,
request_uri_buffer: []u8,
request_uri: []const u8,

pub const ParseError = error{ InvalidScheme, Overflow } || std.Uri.ParseError || std.Io.net.HostName.ValidateError;

pub fn parse(
    arena: std.mem.Allocator,
    uri_raw: []const u8,
    opts: struct {
        host_buffer_len: usize = 1024,
        user_buffer_len: usize = 1024,
        password_buffer_len: usize = 1024,
        request_uri_buffer_len: usize = 1024,
    },
) ParseError!Target {
    const host_buffer = arena.alloc(u8, opts.host_buffer_len) catch @panic("oom");
    const user_buffer = arena.alloc(u8, opts.user_buffer_len) catch @panic("oom");
    const password_buffer = arena.alloc(u8, opts.password_buffer_len) catch @panic("oom");
    const request_uri_buffer = arena.alloc(u8, opts.request_uri_buffer_len) catch @panic("oom");

    var uri: std.Uri = try .parse(uri_raw);
    if (!std.mem.eql(u8, uri.scheme, RTSP_SCHEME)) return ParseError.InvalidScheme;

    const host: std.Io.net.HostName = try .init(uri.host.?.toRaw(host_buffer) catch return ParseError.Overflow);
    const port = uri.port orelse RTSP_PORT;
    const credentials: ?rtsp.Session.Credentials =
        if (uri.user) |user| if (uri.password) |password| .{
            .user = user.toRaw(user_buffer) catch return ParseError.Overflow,
            .password = password.toRaw(password_buffer) catch return ParseError.Overflow,
        } else null else null;
    const request_uri = try write_request_uri(&uri, request_uri_buffer);

    return .{
        .uri = uri,
        .host_buffer = host_buffer,
        .host = host,
        .port = port,
        .user_buffer = user_buffer,
        .password_buffer = password_buffer,
        .credentials = credentials,
        .request_uri_buffer = request_uri_buffer,
        .request_uri = request_uri,
    };
}

fn write_request_uri(uri: *const std.Uri, buffer: []u8) error{Overflow}![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    var flags: std.Uri.Format.Flags = .all;
    flags.authentication = false;
    uri.writeToStream(&writer, flags) catch return error.Overflow;
    return writer.buffered();
}
