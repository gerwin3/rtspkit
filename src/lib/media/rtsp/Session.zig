const std = @import("std");
const stdx = @import("stdx");

const Codec = @import("../codec.zig").Codec;
const rtsp = @import("../rtsp.zig");
const InterleavedData = rtsp.interleaved.Data;
const Request = rtsp.Request;
const Response = rtsp.Response;
const ResponseReader = rtsp.ResponseReader;
const Transport = rtsp.Transport;
const http = @import("../http.zig");
const Diagnostics = stdx.Diagnostics;

pub const Session = @This();

connection: *const Connection,
response_reader: ResponseReader,

user_agent: []const u8,

id_buffer: []u8,

state: struct {
    cseq: u32 = 1,
    id: ?[]const u8 = null,
    /// Timeout as requested by server in seconds.
    timeout: ?usize = null,
},

authentication: ?http.Authentication,

pub const Connection = struct {
    stream_reader: *std.Io.Reader,
    stream_writer: *std.Io.Writer,
};

pub const Credentials = http.Authentication.Credentials;

pub fn init(
    gpa: std.mem.Allocator,
    diagnostics: Diagnostics,
    connection: *Connection,
    credentials: ?Credentials,
    opts: struct {
        user_agent: []const u8 = "rtspkit/1.0",
        id_buffer_len: usize = 256,
        auth_challenge_buffer_len: usize = 4096,
        auth_response_buffer_len: usize = 4096,
    },
) std.mem.Allocator.Error!Session {
    _ = diagnostics;

    const id_buffer = try gpa.alloc(u8, opts.id_buffer_len);
    errdefer gpa.free(id_buffer);

    const authentication = if (credentials) |credentials_| try http.Authentication.init(
        gpa,
        credentials_,
        .{
            .challenge_buffer_len = opts.auth_challenge_buffer_len,
            .response_buffer_len = opts.auth_response_buffer_len,
        },
    ) else null;
    errdefer if (authentication) |*authentication_| authentication_.deinit(gpa);

    return .{
        .connection = connection,
        .response_reader = .{ .reader = connection.stream_reader },
        .user_agent = opts.user_agent,
        .id_buffer = id_buffer,
        .state = .{},
        .authentication = authentication,
    };
}

pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
    gpa.free(self.id_buffer);
    if (self.authentication) |*authentication| authentication.deinit(gpa);
}

pub fn reset(self: *Session) void {
    self.state = .{};
    @memset(self.id_buffer, 0);
    if (self.authentication) |*authentication| authentication.reset();
}

pub const RequestError = error{
    ResponseStatusCode,
    ResponseCSeqMissing,
    ResponseCSeqIncorrect,
    ResponseWwwAuthenticateMissing,
    NoSession,
    CredentialsInvalid,
    CredentialsMissing,
    Overflow,
} || ResponseReader.Error || http.Authentication.SetChallengeError || std.Io.Writer.Error;

/// OPTIONS request.
/// Response is valid until next request.
pub fn options(self: *Session, io: std.Io, diagnostics: Diagnostics, target: []const u8, response: *Response) RequestError!void {
    var request = Request{
        .method = .options,
        .target = target,
        .cseq = undefined,
        .user_agent = undefined,
    };
    try self.request_impl(io, diagnostics, &request, response);
}

/// DESCRIBE request.
/// Response is valid until next request.
pub fn describe(self: *Session, io: std.Io, diagnostics: Diagnostics, target: []const u8, response: *Response) RequestError!void {
    var request = Request{
        .method = .describe,
        .target = target,
        .accept = "application/sdp",
        .cseq = undefined,
        .user_agent = undefined,
    };
    try self.request_impl(io, diagnostics, &request, response);
}

/// SETUP request.
/// Places parsed Transport header in transport.
/// Response is valid until next request.
pub fn setup(self: *Session, io: std.Io, diagnostics: Diagnostics, target: []const u8, transport: Transport, response: *Response) RequestError!void {
    var request = Request{
        .method = .setup,
        .target = target,
        .transport = transport,
        .cseq = undefined,
        .user_agent = undefined,
    };
    try self.request_impl(io, diagnostics, &request, response);

    const session = parse_session_info(response.head.session orelse return RequestError.NoSession);
    self.state.id = std.fmt.bufPrint(self.id_buffer, "{s}", .{session.id}) catch return RequestError.Overflow;
    self.state.timeout = session.timeout;
}

/// PLAY request.
pub fn play(self: *Session, io: std.Io, diagnostics: Diagnostics, target: []const u8, response: *Response) RequestError!void {
    var request = Request{
        .method = .play,
        .target = target,
        .session = self.state.id orelse return RequestError.NoSession,
        .cseq = undefined,
        .user_agent = undefined,
    };
    try self.request_impl(io, diagnostics, &request, response);
}

/// TEARDOWN request.
pub fn teardown(self: *Session, io: std.Io, diagnostics: Diagnostics, target: []const u8, response: *Response) RequestError!void {
    var request = Request{
        .method = .teardown,
        .target = target,
        .session = self.state.id orelse return RequestError.NoSession,
        .cseq = undefined,
        .user_agent = undefined,
    };
    try self.request_impl(io, diagnostics, &request, response);
}

pub const ReceiveInterleavedError = ResponseReader.Error;

pub fn receive_interleaved_data(self: *const Session, diagnostics: Diagnostics) ReceiveInterleavedError!InterleavedData {
    while (true) {
        switch (try self.response_reader.read()) {
            .interleaved_data => |interleaved_data| return interleaved_data,
            .response => |response| {
                diagnostics.report(.warn, null, "Received RTSP response with status code {f} while awaiting interleaved data. Response will be ignored.", .{response.head.status});
            },
        }
    }
}

/// Make a request.
/// This function overwrites request.cseq and request.user_agent.
/// The response is placed in response.
fn request_impl(self: *Session, io: std.Io, diagnostics: Diagnostics, request: *Request, response: *Response) RequestError!void {
    request.cseq = self.state.cseq;
    request.user_agent = self.user_agent;
    try self.authorize_request(request);

    // var stdout_buffer: [1024]u8 = undefined;
    // var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    // request.write(&stdout_writer.interface) catch unreachable;
    // stdout_writer.interface.writeAll("\n\n") catch unreachable;
    // stdout_writer.flush() catch unreachable;

    try request.write(self.connection.stream_writer);
    try self.connection.stream_writer.flush();

    const expected_cseq = self.state.cseq;
    self.state.cseq +%= 1;

    while (true) {
        switch (try self.response_reader.read()) {
            .response => |response_| {
                response.* = response_;
                break;
            },
            .interleaved_data => |interleaved_data| {
                diagnostics.report(.warn, null, "Received interleaved data while awaiting RTSP response on channel: {d}. Data will be ignored.", .{interleaved_data.channel});
            },
        }
    }

    if (response.head.status == .ok) {
        // If response status code is 200 OK: Check CSeq and return.
        const cseq = response.head.cseq orelse return RequestError.ResponseCSeqMissing;
        if (cseq != expected_cseq) return RequestError.ResponseCSeqIncorrect;
    } else if (response.head.status == .unauthorized) {
        // If response status code is Unauthorized but we already had the Authorization header set then the credentials were incorrect.
        if (request.authorization != null) return RequestError.CredentialsInvalid;
        // If response status code is Unauthorized and there are no credentials then the user should have passed credentials.
        var authentication = &(self.authentication orelse return RequestError.CredentialsMissing);

        // Otherwise try and authorize, then do the request again...
        // This will set authentication state to either basic or digest (out of unauthorized).
        const www_authenticate_header = response.head.www_authenticate_digest orelse response.head.www_authenticate_basic orelse return RequestError.ResponseWwwAuthenticateMissing;
        try authentication.set_challenge(io, www_authenticate_header);

        // This repeats the same request but with the Authorization header set.
        // Recurse request_impl. Since authentication state is now basic or digest (and not unauthorized)
        // this will cause request_impl to set the authorization header.
        return self.request_impl(io, diagnostics, request, response);
    } else {
        diagnostics.report(.err, RequestError.ResponseStatusCode, "Received RTSP response with error status code: {f}.", .{response.head.status});
        return RequestError.ResponseStatusCode;
    }
}

fn authorize_request(self: *Session, request: *Request) http.Authentication.AuthorizeError!void {
    var authentication = &(self.authentication orelse return);

    // Only authorize request if we have moved past the unauthorized state.
    if (authentication.state == .unauthorized) return;

    request.authorization = try authentication.authorize(.{
        .method = request.method.as_slice(),
        .uri = request.target,
        .body = &.{},
    });
}

const SessionInfo = struct {
    id: []const u8,
    timeout: ?usize,
};

fn parse_session_info(session: []const u8) SessionInfo {
    const timeout_prefix = "timeout=";

    var parts = std.mem.splitScalar(u8, session, ';');
    const id = parts.first();

    var timeout: ?usize = null;
    while (parts.next()) |part_untrimmed| {
        const part = std.mem.trim(u8, part_untrimmed, " \t");
        const is_timeout = std.mem.startsWith(u8, part, timeout_prefix);
        if (is_timeout) timeout = std.fmt.parseUnsigned(usize, part[timeout_prefix.len..], 10) catch null;
    }

    return .{ .id = id, .timeout = timeout };
}

test "parse_session_info parses bare session id" {
    try std.testing.expectEqualDeep(SessionInfo{ .id = "12345678", .timeout = null }, parse_session_info("12345678"));
}

test "parse_session_info parses timeout parameter" {
    try std.testing.expectEqualDeep(SessionInfo{ .id = "12345678", .timeout = 60 }, parse_session_info("12345678;timeout=60"));
}

test "parse_session_info trims timeout parameter whitespace" {
    try std.testing.expectEqualDeep(SessionInfo{ .id = "12345678", .timeout = 60 }, parse_session_info("12345678; timeout=60 "));
}

test "parse_session_info ignores unrelated parameters" {
    try std.testing.expectEqualDeep(SessionInfo{ .id = "12345678", .timeout = 30 }, parse_session_info("12345678;foo=bar;timeout=30"));
}

test "parse_session_info ignores malformed timeout" {
    try std.testing.expectEqualDeep(SessionInfo{ .id = "12345678", .timeout = null }, parse_session_info("12345678;timeout=abc"));
}
