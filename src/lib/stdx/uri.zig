const std = @import("std");

pub const ResolveError = error{Overflow};

/// Resolve base URI against relative URI for use with RTSP.
///
/// buffer is the buffer space where the output should be copied into.
///
/// If relative URI is an absolute RTSP URI it will be the resolved URI, and the base URI is discarded.
/// If the base URI is an absolute URI and the relative URI is a path they will be joined.
/// If the base URI is a path and the relative is a path too they will be joined.
/// If the relative URI is '*' it will be treated as if it were '' (empty byte sequence).
pub fn resolve(
    buffer: []u8,
    base_uri: []const u8,
    relative_uri: []const u8,
) ResolveError![]const u8 {
    const relative_uri_normalized = if (std.mem.eql(u8, relative_uri, "*")) "" else relative_uri;
    if (std.mem.startsWith(u8, relative_uri_normalized, "rtsp://")) {
        if (relative_uri_normalized.len > buffer.len) return ResolveError.Overflow;
        @memcpy(buffer[0..relative_uri_normalized.len], relative_uri_normalized);
        return buffer[0..relative_uri_normalized.len];
    } else {
        const insert_slash = !std.mem.endsWith(u8, base_uri, "/");
        var writer = std.Io.Writer.fixed(buffer);
        writer.writeAll(base_uri) catch return ResolveError.Overflow;
        if (insert_slash) writer.writeAll("/") catch return ResolveError.Overflow;
        writer.writeAll(relative_uri_normalized) catch return ResolveError.Overflow;
        return writer.buffered();
    }
}

test "resolve returns absolute RTSP URI unchanged" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "rtsp://example.com/trackID=1",
        try resolve(&buffer, "rtsp://base.example.com/stream", "rtsp://example.com/trackID=1"),
    );
}

test "resolve appends relative path to base without trailing slash" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "rtsp://example.com/stream/trackID=1",
        try resolve(&buffer, "rtsp://example.com/stream", "trackID=1"),
    );
}

test "resolve appends relative path to base with trailing slash" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "rtsp://example.com/stream/trackID=1",
        try resolve(&buffer, "rtsp://example.com/stream/", "trackID=1"),
    );
}

test "resolve appends relative path to relative base" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "stream/trackID=1",
        try resolve(&buffer, "stream", "trackID=1"),
    );
}

test "resolve treats star as empty relative URI" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "rtsp://example.com/stream/",
        try resolve(&buffer, "rtsp://example.com/stream/", "*"),
    );
}
