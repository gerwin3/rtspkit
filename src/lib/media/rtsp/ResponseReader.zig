const std = @import("std");
const rtsp = @import("../rtsp.zig");
const Response = rtsp.Response;
const InterleavedData = rtsp.interleaved.Data;

pub const ResponseReader = @This();

reader: *std.Io.Reader,

max_head_len: usize = 4096,
max_message_len: usize = 64 * 1024,
max_interleaved_size: usize = 64 * 1024,

pub const Error = error{Overflow} || Response.Head.ParseError || std.Io.Reader.Error;

/// Read RTSP message from reader.
/// If an error is returend, it is in an inconsistent state and must be reset.
/// In case of success, it returns a union which contains either a normal RTSP
/// response or RTSP interleaved data.
/// The returned data is valid until the next call to read.
pub fn read(self: *const ResponseReader) Error!union(enum) { response: Response, interleaved_data: InterleavedData } {
    try self.reader.fill(1);

    const frame_type: enum { interleaved, message } =
        if (try self.reader.peekByte() == '$') .interleaved else .message;

    switch (frame_type) {
        .message => {
            const body_separator = "\r\n\r\n";

            var offset: usize = 0;
            var head: Response.Head = undefined;

            while (true) {
                const buffer = self.reader.buffered();
                const search_offset = offset -| body_separator.len;
                const body_separator_offset_rel_opt = std.mem.indexOf(u8, buffer[search_offset..], body_separator);

                if (body_separator_offset_rel_opt) |body_separator_offset_rel| {
                    const headers_end = search_offset + body_separator_offset_rel;
                    offset = headers_end + body_separator.len;

                    try head.parse(buffer[0..headers_end]);

                    break;
                } else {
                    offset = buffer.len;
                }

                try self.reader.fillMore();

                if (self.reader.bufferedLen() > self.max_head_len) return Error.Overflow;
            }

            const message_len = offset + (head.content_length orelse 0);
            if (message_len > self.reader.buffer.len) return Error.Overflow;
            if (message_len > self.max_message_len) return Error.Overflow;

            try self.reader.fill(message_len);

            const body = self.reader.buffered()[offset..message_len];
            self.reader.toss(message_len); // buffered data remains valid until next peek

            return .{ .response = .{ .head = head, .body = body } };
        },
        .interleaved => {
            const InterleavedDataHead = packed struct {
                size: u16,
                channel: u8,
                magic: u8,
            };

            const head = try self.reader.peekStruct(InterleavedDataHead, .big);
            std.debug.assert(head.magic == '$');

            const size = @sizeOf(InterleavedDataHead) + head.size;
            if (size > self.reader.buffer.len) return Error.Overflow;
            if (size > self.max_interleaved_size) return Error.Overflow;

            try self.reader.fill(size);

            const data = self.reader.buffered()[@sizeOf(InterleavedDataHead)..size];
            self.reader.toss(size); // buffered data remains valid until next peek

            return .{ .interleaved_data = .{ .channel = head.channel, .data = data } };
        },
    }
}

test "parse response OPTIONS" {
    var reader = std.Io.Reader.fixed(
        "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 1\r\n" ++
            "Public: DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE\r\n" ++
            "\r\n",
    );
    var response_reader = ResponseReader{ .reader = &reader };
    const response = (try response_reader.read()).response;

    try std.testing.expectEqual(.@"1.0", response.head.version);
    try std.testing.expectEqual(.ok, response.head.status);
    try std.testing.expectEqual(1, response.head.cseq.?);
    try std.testing.expectEqualStrings(
        "DESCRIBE, SETUP, TEARDOWN, PLAY, PAUSE",
        response.head.public.?,
    );
}

test "parse response OPTIONS error" {
    var reader = std.Io.Reader.fixed(
        "RTSP/1.0 404 Stream Not Found\r\n" ++
            "CSeq: 1\r\n" ++
            "\r\n",
    );
    var response_reader = ResponseReader{ .reader = &reader };
    const response = (try response_reader.read()).response;

    try std.testing.expectEqual(.@"1.0", response.head.version);
    try std.testing.expectEqual(.not_found, response.head.status);
    try std.testing.expectEqual(1, response.head.cseq.?);
}

const responses_pipelined =
    "RTSP/1.0 200 OK\r\n" ++
    "CSeq: 1\r\n" ++
    "Public: OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN\r\n" ++
    "\r\n" ++
    "RTSP/1.0 200 OK\r\n" ++
    "CSeq: 2\r\n" ++
    "Content-Type: application/sdp\r\n" ++
    "Content-Length: 317\r\n" ++
    "\r\n" ++
    "v=0\r\n" ++
    "o=mhandley 2890844526 2890845468 IN IP4 126.16.64.4\r\n" ++
    "s=SDP Seminar\r\n" ++
    "i=A Seminar on the session description protocol\r\n" ++
    "u=http://www.cs.ucl.ac.uk/staff/M.Handley/sdp.03.ps\r\n" ++
    "e=mjh@isi.edu (Mark Handley)\r\n" ++
    "c=IN IP4 224.2.17.12/127\r\n" ++
    "t=2873397496 2873404696\r\n" ++
    "a=recvonly\r\n" ++
    "m=audio 3456 RTP/AVP 0\r\n" ++
    "m=video 2232 RTP/AVP 31\r\n";

inline fn test_responses_pipelined(reader: *std.Io.Reader) !void {
    var response_reader = ResponseReader{ .reader = reader };

    const response1 = (try response_reader.read()).response;
    try std.testing.expectEqual(.@"1.0", response1.head.version);
    try std.testing.expectEqual(.ok, response1.head.status);
    try std.testing.expectEqual(1, response1.head.cseq.?);
    try std.testing.expectEqualStrings(
        "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN",
        response1.head.public.?,
    );

    const response2 = (try response_reader.read()).response;
    try std.testing.expectEqual(.@"1.0", response2.head.version);
    try std.testing.expectEqual(2, response2.head.cseq.?);
    try std.testing.expectEqualStrings("application/sdp", response2.head.content_type.?);
    try std.testing.expectEqual(317, response2.head.content_length.?);
    try std.testing.expectEqual(317, response2.body.len);

    try std.testing.expectError(error.EndOfStream, response_reader.read());
}

test "parse responses pipelined" {
    var reader = std.Io.Reader.fixed(responses_pipelined);
    try test_responses_pipelined(&reader);
}

test "parse responses pipelined piecewise fixed 1" {
    var reader = test_reader(responses_pipelined, .{ .fixed = 1 });
    try test_responses_pipelined(&reader.interface);
}

test "parse responses pipelined piecewise fixed 2" {
    var reader = test_reader(responses_pipelined, .{ .fixed = 2 });
    try test_responses_pipelined(&reader.interface);
}

test "parse responses pipelined piecewise fixed 3" {
    var reader = test_reader(responses_pipelined, .{ .fixed = 3 });
    try test_responses_pipelined(&reader.interface);
}

test "parse responses pipelined varying" {
    var reader = test_reader(responses_pipelined, .varying);
    try test_responses_pipelined(&reader.interface);
}

const response_describe =
    "RTSP/1.0 200 OK\r\n" ++
    "CSeq: 2\r\n" ++
    "Content-Type: application/sdp\r\n" ++
    "Content-Length: 118\r\n" ++
    "\r\n" ++
    "v=0\r\n" ++
    "o=- 2890844526 2890844526 IN IP4 127.0.0.1\r\n" ++
    "s=Example Stream\r\n" ++
    "t=0 0\r\n" ++
    "m=video 0 RTP/AVP 96\r\n" ++
    "a=control:streamid=0\r\n";

inline fn test_response_describe(reader: *std.Io.Reader) !void {
    var response_reader = ResponseReader{ .reader = reader };

    const response = (try response_reader.read()).response;
    try std.testing.expectEqual(.@"1.0", response.head.version);
    try std.testing.expectEqual(.ok, response.head.status);
    try std.testing.expectEqual(2, response.head.cseq.?);
    try std.testing.expectEqualStrings("application/sdp", response.head.content_type.?);
    try std.testing.expectEqual(118, response.head.content_length.?);
    try std.testing.expectEqualStrings(
        "v=0\r\n" ++
            "o=- 2890844526 2890844526 IN IP4 127.0.0.1\r\n" ++
            "s=Example Stream\r\n" ++
            "t=0 0\r\n" ++
            "m=video 0 RTP/AVP 96\r\n" ++
            "a=control:streamid=0\r\n",
        response.body,
    );

    try std.testing.expectError(error.EndOfStream, response_reader.read());
}

test "parse response DESCRIBE" {
    var reader = std.Io.Reader.fixed(response_describe);
    try test_response_describe(&reader);
}

test "parse response DESCRIBE piecewise fixed 1" {
    var reader = test_reader(response_describe, .{ .fixed = 1 });
    try test_response_describe(&reader.interface);
}

test "parse response DESCRIBE piecewise fixed 2" {
    var reader = test_reader(response_describe, .{ .fixed = 2 });
    try test_response_describe(&reader.interface);
}

test "parse response DESCRIBE piecewise fixed 3" {
    var reader = test_reader(response_describe, .{ .fixed = 3 });
    try test_response_describe(&reader.interface);
}

test "parse response DESCRIBE varying" {
    var reader = test_reader(response_describe, .varying);
    try test_response_describe(&reader.interface);
}

test "parse response DESCRIBE 2" {
    var reader = std.Io.Reader.fixed(
        "RTSP/1.0 200 OK\r\n" ++
            "CSeq: 2\r\n" ++
            "Content-Base: rtsp://example.com/media.mp4\r\n" ++
            "Content-Type: application/sdp\r\n" ++
            "Content-Length: 460\r\n" ++
            "\r\n" ++
            "m=video 0 RTP/AVP 96\r\n" ++
            "a=control:streamid=0\r\n" ++
            "a=range:npt=0-7.741000\r\n" ++
            "a=length:npt=7.741000\r\n" ++
            "a=rtpmap:96 MP4V-ES/5544\r\n" ++
            "a=mimetype:string;\"video/MP4V-ES\"\r\n" ++
            "a=AvgBitRate:integer;304018\r\n" ++
            "a=StreamName:string;\"hinted video track\"\r\n" ++
            "m=audio 0 RTP/AVP 97\r\n" ++
            "a=control:streamid=1\r\n" ++
            "a=range:npt=0-7.712000\r\n" ++
            "a=length:npt=7.712000\r\n" ++
            "a=rtpmap:97 mpeg4-generic/32000/2\r\n" ++
            "a=mimetype:string;\"audio/mpeg4-generic\"\r\n" ++
            "a=AvgBitRate:integer;65790\r\n" ++
            "a=StreamName:string;\"hinted audio track\"\r\n",
    );
    var response_reader = ResponseReader{ .reader = &reader };
    const response = (try response_reader.read()).response;

    try std.testing.expectEqual(.@"1.0", response.head.version);
    try std.testing.expectEqual(.ok, response.head.status);
    try std.testing.expectEqual(2, response.head.cseq.?);
    try std.testing.expectEqualStrings("rtsp://example.com/media.mp4", response.head.content_base.?);
    try std.testing.expectEqualStrings("application/sdp", response.head.content_type.?);
    try std.testing.expectEqual(460, response.head.content_length.?);
}

test "parse interleaved frame" {
    var reader = std.Io.Reader.fixed(&.{ '$', 0x02, 0x00, 0x04, 0xaa, 0xbb, 0xcc, 0xdd });
    var response_reader = ResponseReader{ .reader = &reader };
    const interleaved = (try response_reader.read()).interleaved_data;

    try std.testing.expectEqual(2, interleaved.channel);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc, 0xdd }, interleaved.data);
}

test "parse prefers digest www-authenticate" {
    var reader = std.Io.Reader.fixed(
        "RTSP/1.0 401 Unauthorized\r\n" ++
            "CSeq: 9\r\n" ++
            "WWW-Authenticate: Basic realm=\"cam\"\r\n" ++
            "WWW-Authenticate: Digest realm=\"cam\", nonce=\"abc\"\r\n" ++
            "\r\n",
    );
    var response_reader = ResponseReader{ .reader = &reader };
    const response = (try response_reader.read()).response;

    try std.testing.expectEqualStrings(
        "Digest realm=\"cam\", nonce=\"abc\"",
        response.head.www_authenticate_digest.?,
    );
}

test "parse rejects ok response without cseq" {
    var reader = std.Io.Reader.fixed("RTSP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n");
    var response_reader = ResponseReader{ .reader = &reader };
    try std.testing.expectError(Response.Head.ParseError.MissingHeaderCSeq, response_reader.read());
}

test "parse overflows when response does not fit buffer" {
    var buffer: [64]u8 = undefined;
    var source = std.testing.Reader.init(&buffer, &.{.{ .buffer = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 100\r\n\r\n" }});
    var response_reader = ResponseReader{ .reader = &source.interface };
    try std.testing.expectError(ResponseReader.Error.Overflow, response_reader.read());
}

test "parse overflows when interleaved frame does not fit buffer" {
    var buffer: [8]u8 = undefined;
    var source = std.testing.Reader.init(&buffer, &.{.{ .buffer = &.{ '$', 0x00, 0x00, 0x08 } }});
    var response_reader = ResponseReader{ .reader = &source.interface };
    try std.testing.expectError(ResponseReader.Error.Overflow, response_reader.read());
}

fn test_reader(data: []const u8, piece_mode: union(enum) { fixed: usize, varying }) std.testing.Reader {
    const buffer = std.heap.page_allocator.alloc(u8, data.len) catch unreachable;
    const calls = std.heap.page_allocator.alloc(std.testing.Reader.Call, data.len) catch unreachable;
    const calls_slice = calls_slice: switch (piece_mode) {
        .fixed => |size| {
            var call_index: usize = 0;
            var offset: usize = 0;
            while (offset < data.len) : (call_index += 1) {
                calls[call_index] = .{ .buffer = data[offset..@min(offset + size, data.len)] };
                offset += size;
            }
            break :calls_slice calls[0..call_index];
        },
        .varying => {
            var call_index: usize = 0;
            var offset: usize = 0;
            while (offset < data.len) : (call_index += 1) {
                const end = @min(offset + @max((offset * 2) % 9, 1), data.len);
                calls[call_index] = .{ .buffer = data[offset..end] };
                offset = end;
            }
            break :calls_slice calls[0..call_index];
        },
    };
    std.debug.assert(calls_slice.len <= data.len);
    return std.testing.Reader.init(buffer, calls_slice);
}
