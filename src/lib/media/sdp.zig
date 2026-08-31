const std = @import("std");

const Codec = @import("codec.zig").Codec;

pub const Parser = @import("sdp/Parser.zig");
pub const Selector = @import("sdp/Selector.zig");

/// SDP Version (RFC 2327 §6, Protocol Version)
pub const Version = enum {
    @"0",
};

/// SDP Media Description (RFC 2327 §6, Media description)
pub const Media = struct {
    kind: Type,
    port: u32,
    protocol: TransportProtocol,
    payload_type: ?u8,

    /// SDP Media Type (RFC 2327 §5.1, Media Information)
    pub const Type = enum {
        audio,
        video,
        text,
        application,
        message,
    };

    /// SDP Transport Protocol (RFC 2327 §5.1, Media Information)
    pub const TransportProtocol = enum {
        @"RTP/AVP",
        @"RTP/SAVP",
        @"RTP/AVP/TCP",
        other,
    };
};

/// SDP Attribute (RFC 2327 §6, Attributes)
pub const Attribute = union(enum) {
    fmtp: Fmtp,
    rtpmap: RtpMap,
    control: Control,

    /// SDP FMTP Attribute (RFC 2327 §6, Suggested Attributes)
    pub const Fmtp = struct {
        payload_type: u8,
        parameters: FormatParameters,

        /// SDP Format-Specific Parameters (RFC 2327 §6, Suggested Attributes)
        pub const FormatParameters = struct {
            packetization_mode: ?u8 = null,
            profile_level_id: ?[]const u8 = null,
            /// SDP Format-Specific Parameter Sets (RFC 2327 §6, Suggested Attributes)
            parameter_sets: struct {
                vps: ?[]const u8 = null,
                sps: ?[]const u8 = null,
                pps: ?[]const u8 = null,
            } = .{},
        };
    };

    /// SDP RTP Map Attribute (RFC 2327 §6, Media Announcements)
    pub const RtpMap = struct {
        payload_type: u8,
        codec: Codec,
        clock_rate: u32,
    };

    /// RTSP Control Attribute (RFC 2326 Appendix C.1.1, Control URL)
    pub const Control = struct {
        uri: []const u8,
    };
};

test {
    std.testing.refAllDecls(@This());
}
