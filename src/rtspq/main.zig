const std = @import("std");
const stdx = @import("stdx");

const Diagnostics = stdx.Diagnostics;

const media = @import("media");
const rtsp = media.rtsp;

const Task = @import("Task.zig");
const Info = @import("Info.zig");
const DiagnosticsCollector = @import("DiagnosticsCollector.zig");

pub fn main(init: std.process.Init) void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    run(arena, io, init.minimal.args, stdout, stderr) catch |err| switch (err) {
        RunError.Usage => {
            stderr.print(
                \\rtspq: Query RTSP stream information.
                \\
                \\Usage: rtspq input1 [input2 ...] [-j|--json] [-c|--csv]
                \\    input1, input2, etc.: RTSP URIs to query for stream information.
                \\    -j, --json: Present stream information in JSON format.
                \\    -c, --csv: Present stream information in CSV format.
                \\    If no output format is selected a table is printed.
                \\
                \\Example usage:
                \\    Print this usage message:
                \\      rtspq
                \\    Query information for a single stream and print a table:
                \\      rtspq 'rtsp://10.0.0.1/stream/0'
                \\    Query information for multiple streams and print as JSON:
                \\      rtspq 'rtsp://nvr-a/0' 'rtsp://nvr-b0' 'rtsp://nvr-a/1' --json
                \\    Provide credentials and print as CSV:
                \\      rtspq 'rtsp://user:pass@192.168.1.100/live' --csv
                \\
                \\Output (printed to stdout):
                \\    index: Index of input stream. Use this to cross-reference the
                \\      output to the original input stream.
                \\    codec: The video codec: Either H.264 (h264) or H.265 (h265).
                \\      Other codecs are not supported.
                \\    profile: The encoding profile, such as baseline, main or high.
                \\      For H.265 if the stream uses the Format Range Extensions (4)
                \\      the reported profile will be rext.
                \\    width/height: Display dimensions of the stream in pixels.
                \\    frame_rate: The reported frame rate. If the stream SPS contains
                \\      VUI with timing information, rtspq will use this info to
                \\      determine frame rate. If not, it will try and estimate the
                \\      frame rate by probing the stream and counting frame deltas.
                \\
                \\Failing streams:
                \\    If a stream fails and information cannot be queried it will not
                \\    be present in the output. Instead an error message with more
                \\    information is printed to stderr.
            , .{}) catch {};
        },
        std.Io.Writer.Error.WriteFailed => @panic("failed to write to stdout/stderr"),
        std.Io.Cancelable.Canceled => unreachable,
    };
}

const RunError = error{Usage} || std.Io.Writer.Error || std.Io.Cancelable;

fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    args: std.process.Args,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) RunError!void {
    var output_mode: enum { table, json, csv } = .table;

    var args_iter = args.iterateAllocator(arena) catch @panic("oom");
    _ = args_iter.skip();

    var tasks: std.ArrayList(Task) = .empty;
    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json"))
                output_mode = .json
            else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--csv"))
                output_mode = .csv
            else
                @panic("unknown option");
            continue;
        }

        const diagnostics_collector: DiagnosticsCollector = .init(arena);
        tasks.append(arena, .{ .uri = arg, .diagnostics_collector = diagnostics_collector }) catch @panic("oom");
    }

    if (tasks.items.len == 0) return RunError.Usage;

    var task_group: std.Io.Group = .init;
    for (tasks.items) |*task| task_group.async(io, Task.run, .{ task, io, arena });
    try task_group.await(io);

    var table_col_widths: struct {
        profile: usize = 20,
    } = undefined;

    switch (output_mode) {
        .table => {
            table_col_widths = .{};
            var profile_col_width: usize = "profile".len;
            for (tasks.items) |*task| {
                if (task.out) |*info| profile_col_width = @max(profile_col_width, info.profile.len) else |_| {}
            }
            table_col_widths.profile = profile_col_width;
            try write_table_header(arena, stdout, table_col_widths.profile);
        },
        .json => try stdout.writeAll("["),
        .csv => {},
    }

    var item0 = true;

    for (0.., tasks.items) |index, *task| {
        if (task.out) |*info| {
            if (!item0) switch (output_mode) {
                .table => try write_table_row_sep(stdout),
                .json => try write_json_sep(stdout),
                .csv => try write_csv_row_sep(stdout),
            };
            item0 = false;
            switch (output_mode) {
                .table => try write_table_row_item(arena, index, info, stdout, table_col_widths.profile),
                .json => try write_json_item(index, info, stdout),
                .csv => try write_csv_item(index, info, stdout),
            }
        } else |err| {
            try stderr.print("Error on stream {d}: {s}\n", .{ index, get_error_detail(err) });
            for (task.diagnostics_collector.list.items) |diagnostics_item| switch (diagnostics_item.level) {
                .incident, .err, .warn => try stderr.print(" `- {s}\n", .{diagnostics_item.message}),
                else => {},
            };
        }
    }

    switch (output_mode) {
        .table => {},
        .json => try stdout.writeAll("]"),
        .csv => {},
    }
}

fn write_table_header(
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    profile_col_width: usize,
) std.Io.Writer.Error!void {
    const row0 = table_row(arena, profile_col_width);
    _ = std.fmt.bufPrint(row0.cols[0], "{s}", .{"index"}) catch unreachable;
    _ = std.fmt.bufPrint(row0.cols[1], "{s}", .{"codec"}) catch unreachable;
    _ = std.fmt.bufPrint(row0.cols[2], "{s}", .{"profile"}) catch unreachable;
    _ = std.fmt.bufPrint(row0.cols[3], "{s}", .{"width"}) catch unreachable;
    _ = std.fmt.bufPrint(row0.cols[4], "{s}", .{"height"}) catch unreachable;
    _ = std.fmt.bufPrint(row0.cols[5], "{s}", .{"fps"}) catch unreachable;
    try writer.writeAll(row0.buffer);
    try writer.writeByte('\n');

    const row1 = table_row(arena, profile_col_width);
    inline for (row1.cols) |col| @memset(col, '-');
    try writer.writeAll(row1.buffer);
    try writer.writeByte('\n');
}

fn write_table_row_item(
    arena: std.mem.Allocator,
    index: usize,
    info: *const Info,
    writer: *std.Io.Writer,
    profile_col_width: usize,
) std.Io.Writer.Error!void {
    const row = table_row(arena, profile_col_width);
    _ = std.fmt.bufPrint(row.cols[0], "{d}", .{index}) catch @panic("table row overflow");
    _ = std.fmt.bufPrint(row.cols[1], "{s}", .{@tagName(info.codec)}) catch @panic("table row overflow");
    _ = std.fmt.bufPrint(row.cols[2], "{s}", .{info.profile}) catch @panic("table row overflow");
    _ = std.fmt.bufPrint(row.cols[3], "{d}", .{info.dimensions.width}) catch @panic("table row overflow");
    _ = std.fmt.bufPrint(row.cols[4], "{d}", .{info.dimensions.height}) catch @panic("table row overflow");
    if (info.frame_rate_f32()) |frame_rate| _ = std.fmt.bufPrint(row.cols[5], "{d:.2}", .{frame_rate}) catch @panic("table row overflow");
    try writer.writeAll(row.buffer);
}

fn write_table_row_sep(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte('\n');
}

fn table_row(arena: std.mem.Allocator, profile_col_width: usize) struct { buffer: []const u8, cols: [6][]u8 } {
    const col_widths: [6]usize = .{ 6, 6, profile_col_width, 6, 6, 6 };
    var col_offsets: [6]usize = undefined;
    var row_width: usize = 0;
    inline for (0.., col_widths) |col_index, col_width| {
        col_offsets[col_index] = row_width;
        row_width += col_width;
        if (col_index != col_widths.len - 1) row_width += 3;
    }
    var buffer = arena.alloc(u8, row_width) catch @panic("oom");
    var cols: [6][]u8 = undefined;
    @memset(buffer, ' ');
    inline for (0..col_widths.len - 1) |col_index| buffer[col_offsets[col_index] + col_widths[col_index] + 1] = '|';
    inline for (0..col_widths.len) |col_index| cols[col_index] = buffer[col_offsets[col_index] .. col_offsets[col_index] + col_widths[col_index]];
    return .{ .buffer = buffer, .cols = cols };
}

fn write_csv_item(
    index: usize,
    info: *const Info,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print("{d}", .{index});
    try writer.print(",{s}", .{@tagName(info.codec)});
    try writer.print(",{s}", .{info.profile});
    try writer.print(",{d},{d},", .{ info.dimensions.width, info.dimensions.height });
    if (info.frame_rate_f32()) |frame_rate| try writer.print("{d:.2}", .{frame_rate});
}

fn write_csv_row_sep(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte('\n');
}

fn write_json_item(
    index: usize,
    info: *const Info,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.writeAll("{");
    try writer.print("\"index\": \"{d}\"", .{index});
    try writer.print(",\"codec\": \"{s}\"", .{@tagName(info.codec)});
    try writer.print(",\"profile\": \"{s}\"", .{info.profile});
    try writer.print(",\"width\": {d},\"height\": {d}", .{ info.dimensions.width, info.dimensions.height });
    if (info.frame_rate_f32()) |frame_rate| try writer.print(",\"frame_rate\": {d:.2}", .{frame_rate});
    try writer.writeAll("}");
}

fn write_json_sep(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte(',');
}

fn get_error_detail(err: Task.Error) []const u8 {
    return switch (err) {
        error.Timeout => "Connection failed: Timeout occurred.",
        error.Overflow => "A buffer overflow occurred. This is either a bug or a faulty camera.",
        error.Canceled => unreachable,
        Task.Error.InvalidScheme => "Invalid URI: Invalid scheme: The stream URI should start with `rtsp://`.",
        Task.Error.InsufficientInfo => "Insufficient information from stream: No SPS NALU was received during the probe duration. The camera is faulty or not sending packets.",
        std.Uri.ParseError.UnexpectedCharacter => "Invalid URI: Unexpected character in URI.",
        std.Uri.ParseError.InvalidFormat => "Invalid URI: Invalid format.",
        std.Uri.ParseError.InvalidPort => "Invalid URI: Invalid port.",
        std.Uri.ParseError.InvalidHostName => "Invalid URI: Invalid hostname. It may contain components that are too long, or invalid characters.",
        std.Io.net.HostName.ValidateError.NameTooLong => "Invalid hostname: Name is too long.",
        std.Io.net.HostName.LookupError.UnknownHostName => "Connection failed: Unknown hostname.",
        std.Io.net.HostName.LookupError.ResolvConfParseFailed => "Connection failed: Hostname could not be resolved due to resolv.conf parsing issue. Your resolv.confg may be invalid.",
        std.Io.net.HostName.LookupError.InvalidDnsARecord => "Connection failed: Hostname could not be resolved due to invalid A record.",
        std.Io.net.HostName.LookupError.InvalidDnsAAAARecord => "Connection failed: Hostname could not be resolved due to invalid AAAA record.",
        std.Io.net.HostName.LookupError.InvalidDnsCnameRecord => "Connection failed: Hostname could not be resolved due to invalid CNAME record.",
        std.Io.net.HostName.LookupError.NameServerFailure => "Connection failed: Hostname could not be resolved due to nameserver failure.",
        std.Io.net.HostName.LookupError.NoAddressReturned => "Connection failed: Hostname did not resolve to an address.",
        std.Io.net.HostName.LookupError.DetectingNetworkConfigurationFailed => "Connection failed: Failed to open /etc/hosts or /etc/resolv.conf.",
        std.Io.net.IpAddress.BindError.AddressInUse => "Connection failed: Address is already in use.",
        std.Io.net.IpAddress.ConnectError.AddressUnavailable => "Connection failed: Address is unavailable.",
        std.Io.net.IpAddress.ConnectError.AddressFamilyUnsupported => "Connection failed: Address family is not supported.",
        std.Io.net.IpAddress.ConnectError.SystemResources => "Connection failed: Operating system reports insufficient memory or other resource.",
        std.Io.net.IpAddress.ConnectError.ConnectionPending => "Connection failed: Connection is already pending.",
        std.Io.net.IpAddress.ConnectError.ConnectionRefused => "Connection failed: Connection was refused by peer.",
        std.Io.net.IpAddress.ConnectError.ConnectionResetByPeer => "Connection failed: Connection was reset by peer.",
        std.Io.net.IpAddress.ConnectError.HostUnreachable => "Connection failed: Host is not reachable.",
        std.Io.net.IpAddress.ConnectError.NetworkUnreachable => "Connection failed: Network unreachable.",
        std.Io.net.IpAddress.ConnectError.OptionUnsupported => unreachable,
        std.Io.net.IpAddress.ConnectError.ProcessFdQuotaExceeded => "Connection failed: Per-process file descriptor limit hit.",
        std.Io.net.IpAddress.ConnectError.SystemFdQuotaExceeded => "Connection failed: System-wide file descriptor limit hit.",
        std.Io.net.IpAddress.ConnectError.ProtocolUnsupportedBySystem => "Connection failed: System does not support transport protocol.",
        std.Io.net.IpAddress.ConnectError.ProtocolUnsupportedByAddressFamily => "Connection failed: System does not support address family.",
        std.Io.net.IpAddress.ConnectError.SocketModeUnsupported => "Connection failed: System does not supported socket mode.",
        std.Io.net.IpAddress.ConnectError.AccessDenied => "Connection failed: Access denied. Could be caused by trying to connect to a broadcast address or a local firewall rule.",
        std.Io.net.IpAddress.ConnectError.WouldBlock => "Connection failed: Non-blocking was requested and the operation cannot return immediately.",
        std.Io.net.IpAddress.ConnectError.NetworkDown => "Connection failed: Network is down.",
        std.Io.UnexpectedError.Unexpected => "An unexpected error occurred. This may be a bug.",
        std.Io.Reader.Error.ReadFailed => "Connection broken: The peer may have unexpectedly closed the connection.",
        std.Io.Reader.Error.EndOfStream => "Connection broken: Unexpected end of stream. The peer may have unexpectedly closed the connection.",
        std.Io.Writer.Error.WriteFailed => "Connection broken: The peer may have unexpectedly closed the connection.",
        rtsp.Stream.SetupError.UnsupportedSdp => "The stream presented SDP contents that cannot be parsed by this program. File an issue.",
        rtsp.Stream.SetupError.MalformedSdp => "The stream presented invalid SDP contents. The camera is not compliant.",
        rtsp.Stream.SetupError.UnsupportedMedia => "The stream is of a codec or format that is not supported. Only H.264 and H.265 are supported.",
        rtsp.Stream.SetupError.UnsupportedTransport => "The stream is of a codec or format that is not supported. Only H.264 and H.265 are supported.",
        rtsp.Stream.SetupError.MalformedTransport => "The stream presented an invalid transport header. The camera is not compliant.",
        rtsp.Stream.ReceiveError.InvalidRtpPacket => "The peer sent an invalid RTP packet. The camera is buggy.",
        rtsp.Session.RequestError.ResponseStatusCode => "The stream returned an RTSP error status code.",
        rtsp.Session.RequestError.ResponseCSeqMissing => "Invalid RTSP response: The response is missing the CSeq header. The camera is not compliant.",
        rtsp.Session.RequestError.ResponseCSeqIncorrect => "Invalid RTSP response: The response contains an invalid CSeq header value. The camera is not compliant.",
        rtsp.Session.RequestError.ResponseWwwAuthenticateMissing => "Invalid RTSP response: The response is missing the WWW-Authenticate header.",
        rtsp.Session.RequestError.NoSession => "Invalid RTSP conversation: The peer never set the Session header. The camera is not compliant.",
        rtsp.Session.RequestError.CredentialsInvalid => "Unauthorized: You provided incorrect credentials.",
        rtsp.Session.RequestError.CredentialsMissing => "Unauthorized: You must provide credentials.",
        rtsp.Response.Head.ParseError.UnsupportedVersion => "The stream reports an unsupported RTSP version.",
        rtsp.Response.Head.ParseError.MissingStatusCode => "Invalid RTSP response: The response is missing a status code. The camera is not compliant.",
        rtsp.Response.Head.ParseError.InvalidStatusCode => "Invalid RTSP response: The response contains an invalid status code. The camera is not compliant.",
        rtsp.Response.Head.ParseError.InvalidHeader => "Invalid RTSP response: The response contains an invalid header. The camera is not compliant.",
        rtsp.Response.Head.ParseError.InvalidHeaderConnection => "Invalid RTSP response: The response contains an invalid Connection header. The camera is not compliant.",
        rtsp.Response.Head.ParseError.InvalidHeaderContentLength => "Invalid RTSP response: The response contains an invalid Content-Length header. The camera is not compliant.",
        rtsp.Response.Head.ParseError.InvalidHeaderCSeq => "Invalid RTSP response: The response contains an invalid CSeq header. The camera is not compliant.",
        rtsp.Response.Head.ParseError.MissingHeaderCSeq => "Invalid RTSP response: The response is missing the CSeq header. The camera is not compliant.",
        media.http.Authentication.SetChallengeError.UnsupportedScheme => "Authentication failed: The peer authentication scheme is not supported.",
        media.http.Authentication.digest.Challenge.ParseError.MissingEqualsSign, media.http.Authentication.digest.Challenge.ParseError.MissingNonce, media.http.Authentication.digest.Challenge.ParseError.MissingRealm, media.http.Authentication.digest.Challenge.ParseError.InvalidStale => "Authentication failed: The challenge is invalid and cannot be parsed.",
        media.http.Authentication.digest.Challenge.ParseError.UnsupportedAlgorithm => "Authentication failed: The peer authentication algorithm is not supported.",
        media.http.Authentication.digest.Challenge.ParseError.UnsupportedHeaderFormat => "Authentication failed: The peer header format is not supported.",
        media.http.Authentication.digest.Challenge.ParseError.UnsupportedMethod => "Authentication failed: The peer authentication method is not supported.",
        media.http.Authentication.digest.Challenge.ParseError.UnsupportedQOP => "Authentication failed: The peer QOP is not supported.",
        media.ParameterSets.ParseError.InvalidVPS => "Invalid data: Received invalid VPS NALU.",
        media.ParameterSets.ParseError.InvalidSPS => "Invalid data: Received invalid SPS NALU.",
        media.ParameterSets.ParseError.InvalidPPS => "Invalid data: Received invalid PPS NALU.",
        media.ParameterSets.ParseBase64Error.InvalidParameterSetBase64 => "Invalid parameter sets received: The SDP parameter sets were not base64-decodable.",
        media.rtp.Demuxer.DemuxError.UnexpectedRtpFragment => "Invalid data: Received spurious RTP fragment.",
        media.rtp.Demuxer.DemuxError.UnsupportedRtpPacketType => "Unsupported data: Received unsupported RTP packet.",
    };
}
