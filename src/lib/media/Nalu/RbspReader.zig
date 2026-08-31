const std = @import("std");

pub const RbspReader = struct {
    in: *std.Io.Reader,
    state: struct { zero_count: usize } = .{ .zero_count = 0 },
    buffer: [1]u8,
    interface: std.Io.Reader,

    pub fn init(in: *std.Io.Reader) RbspReader {
        var reader = RbspReader{
            .in = in,
            .state = .{ .zero_count = 0 },
            .buffer = undefined,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = undefined,
                .seek = 0,
                .end = 0,
            },
        };
        reader.interface.buffer = &reader.buffer;
        return reader;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *RbspReader = @alignCast(@fieldParentPtr("interface", r));
        if (!limit.nonzero()) return 0;

        if (try self.in.peekByte() == 0x03 and self.state.zero_count == 2) {
            _ = self.in.takeByte() catch unreachable;
            self.state.zero_count = 0;
        }
        _ = try self.in.peekByte();

        const dest = limit.slice(try w.writableSliceGreedy(1));

        var pos: usize = 0;
        while (pos < dest.len) {
            const source_byte = try self.in.takeByte();
            if (source_byte == 0x03 and self.state.zero_count == 2) {
                self.state.zero_count = 0;
                continue;
            } else if (source_byte == 0x00 and self.state.zero_count < 2) {
                self.state.zero_count += 1;
            } else if (source_byte != 0x00) {
                self.state.zero_count = 0;
            }
            dest[pos] = source_byte;
            pos += 1;
            w.advance(1);
        }
        return pos;
    }
};

fn test_rbsp_reader(comptime input: []const u8, comptime output: []const u8) !void {
    var in_reader: std.Io.Reader = .fixed(input);
    var rbsp_reader = RbspReader.init(&in_reader);

    var out_buffer: [@max(output.len, 1)]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(out_buffer[0..]);

    while (true) {
        const n = rbsp_reader.interface.stream(&out_writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try std.testing.expect(n > 0);
    }

    try std.testing.expectEqualSlices(u8, output, out_writer.buffered());
}

test "RbspReader fixed passthrough" {
    try test_rbsp_reader("", "");
    try test_rbsp_reader("\x12\x34\x56", "\x12\x34\x56");
}

test "RbspReader fixed strips emulation bytes" {
    try test_rbsp_reader("\x00\x00\x03\x01", "\x00\x00\x01");
    try test_rbsp_reader("\x12\x00\x00\x03\x02\x34", "\x12\x00\x00\x02\x34");
}

fn test_rbsp_reader_varying_io_params_impl(comptime input: []const u8, comptime output: []const u8, reader_buffer_size: usize, writer_limit: usize) !void {
    var in_buffer: [8]u8 = undefined;
    var in_reader = std.testing.Reader.init(in_buffer[0..reader_buffer_size], &[_]std.testing.Reader.Call{.{ .buffer = input }});
    in_reader.artificial_limit = .limited(reader_buffer_size);

    var out_buffer: [@max(output.len, 1)]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(out_buffer[0..]);

    var rbsp_reader = RbspReader.init(&in_reader.interface);
    while (true) {
        const n = rbsp_reader.interface.stream(&out_writer, .limited(writer_limit)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try std.testing.expect(n > 0);
    }
    try std.testing.expectEqualSlices(u8, output, out_writer.buffered());
}

fn test_rbsp_reader_varying_io_params(comptime input: []const u8, comptime output: []const u8) !void {
    for ([_]usize{ 1, 2, 3, 8 }) |reader_buffer_size| {
        for ([_]usize{ 1, 2, 3, 8 }) |writer_limit| {
            try test_rbsp_reader_varying_io_params_impl(input, output, reader_buffer_size, writer_limit);
        }
    }
}

test "RbspReader passthrough" {
    try test_rbsp_reader_varying_io_params("", "");
    try test_rbsp_reader_varying_io_params("\x12", "\x12");
    try test_rbsp_reader_varying_io_params("\x12\x34\x56", "\x12\x34\x56");
    try test_rbsp_reader_varying_io_params("\x00", "\x00");
    try test_rbsp_reader_varying_io_params("\x00\x00", "\x00\x00");
    try test_rbsp_reader_varying_io_params("\x00\x03", "\x00\x03");
    try test_rbsp_reader_varying_io_params("\x00\x00\x00", "\x00\x00\x00");
    try test_rbsp_reader_varying_io_params("\x00\x00\x04", "\x00\x00\x04");
    try test_rbsp_reader_varying_io_params("\x12\x00\x00\x04\x34", "\x12\x00\x00\x04\x34");
}

test "RbspReader strips emulation bytes" {
    try test_rbsp_reader_varying_io_params("\x00\x00\x03\x00", "\x00\x00\x00");
    try test_rbsp_reader_varying_io_params("\x00\x00\x03\x01", "\x00\x00\x01");
    try test_rbsp_reader_varying_io_params("\x00\x00\x03\x02", "\x00\x00\x02");
    try test_rbsp_reader_varying_io_params("\x00\x00\x03\x03", "\x00\x00\x03");
    try test_rbsp_reader_varying_io_params("\x12\x00\x00\x03\x01\x34", "\x12\x00\x00\x01\x34");
}

test "RbspReader repeated patterns" {
    try test_rbsp_reader_varying_io_params("\x00\x00\x03\x00\x00\x03\x01", "\x00\x00\x00\x00\x01");
    try test_rbsp_reader_varying_io_params("\x00\x00\x03\x00\x11\x00\x00\x03\x02", "\x00\x00\x00\x11\x00\x00\x02");
    try test_rbsp_reader_varying_io_params("\x00\x00\x04\x03\x00\x00\x05\x03", "\x00\x00\x04\x03\x00\x00\x05\x03");
}

test "RbspReader end of stream around zeros" {
    try test_rbsp_reader_varying_io_params("\x00\x00", "\x00\x00");
    try test_rbsp_reader_varying_io_params("\x00\x00\x03", "\x00\x00");
    try test_rbsp_reader_varying_io_params("\x12\x00\x00\x03", "\x12\x00\x00");
    try test_rbsp_reader_varying_io_params("\x00\x00\x00\x00", "\x00\x00\x00\x00");
}
