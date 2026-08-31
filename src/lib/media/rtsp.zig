const std = @import("std");

pub const interleaved = @import("rtsp/interleaved.zig");
pub const Session = @import("rtsp/Session.zig");
pub const Request = @import("rtsp/Request.zig");
pub const Response = @import("rtsp/Response.zig");
pub const ResponseReader = @import("rtsp/ResponseReader.zig");
pub const Stream = @import("rtsp/Stream.zig");
pub const Transport = @import("rtsp/Transport.zig");

pub const Version = enum {
    @"1.0",
};

pub const Status = enum(u16) {
    @"continue" = 100,
    ok = 200,
    created = 201,
    lowon_storage_space = 250,
    multiple_choices = 300,
    moved_permanently = 301,
    moved_temporarily = 302,
    see_other = 303,
    use_proxy = 305,
    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    proxy_authentication_required = 407,
    request_timeout = 408,
    gone = 410,
    length_required = 411,
    precondition_failed = 412,
    request_entity_too_large = 413,
    request_uri_too_long = 414,
    unsupported_media_type = 415,
    invalid_parameter = 451,
    illegal_conference_identifier = 452,
    not_enough_bandwidth = 453,
    session_not_found = 454,
    method_not_valid_in_this_state = 455,
    header_field_not_valid = 456,
    invalid_range = 457,
    parameter_is_read_only = 458,
    aggregate_operation_not_allowed = 459,
    only_aggregate_operation_allowed = 460,
    unsupported_transport = 461,
    destination_unreachable = 462,
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    rtsp_version_not_supported = 505,
    option_not_supported = 551,
    _,

    pub fn phrase(self: Status) ?[]const u8 {
        return switch (self) {
            .@"continue" => "Continue",
            .ok => "OK",
            .created => "Created",
            .lowon_storage_space => "Low On Storage Space",
            .multiple_choices => "Multiple Choices",
            .moved_permanently => "Moved Permanently",
            .moved_temporarily => "Moved Temporarily",
            .see_other => "See Other",
            .use_proxy => "Use Proxy",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .payment_required => "Payment Required",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .proxy_authentication_required => "Proxy Authentication Required",
            .request_timeout => "Request Timeout",
            .gone => "Gone",
            .length_required => "Length Required",
            .precondition_failed => "Precondition Failed",
            .request_entity_too_large => "Request Entity Too Large",
            .request_uri_too_long => "Request URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .invalid_parameter => "Invalid Parameter",
            .illegal_conference_identifier => "Illegal Conference Identifier",
            .not_enough_bandwidth => "Not Enough Bandwidth",
            .session_not_found => "Session Not Found",
            .method_not_valid_in_this_state => "Method Not Valid In This State",
            .header_field_not_valid => "Header Field Not Valid",
            .invalid_range => "Invalid Range",
            .parameter_is_read_only => "Parameter Is Read-Only",
            .aggregate_operation_not_allowed => "Aggregate Operation Not Allowed",
            .only_aggregate_operation_allowed => "Only Aggregate Operation Allowed",
            .unsupported_transport => "Unsupported Transport",
            .destination_unreachable => "Destination Unreachable",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .rtsp_version_not_supported => "RTSP Version Not Supported",
            .option_not_supported => "Option Not Supported",
            _ => null,
        };
    }

    pub fn format(self: Status, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.phrase()) |phrase_| {
            try writer.print("{s} ({d})", .{ phrase_, @intFromEnum(self) });
        } else {
            try writer.print("{d}", .{@intFromEnum(self)});
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
