const std = @import("std");

const Nalu = @import("Nalu.zig");

pub const Codec = enum {
    h264,
    h265,
};

pub const ParameterSets = union(Codec) {
    h264: struct {
        sps: ?Nalu.Header.H264.SPS = null,
        pps: ?Nalu.Header.H264.PPS = null,
    },
    h265: struct {
        vps: ?Nalu.Header.H265.VPS = null,
        sps: ?Nalu.Header.H265.SPS = null,
        pps: ?Nalu.Header.H265.PPS = null,
    },

    pub const ParseError = error{
        InvalidVPS,
        InvalidSPS,
        InvalidPPS,
    };

    pub fn parse_h264(sps_raw_opt: ?[]const u8, pps_raw_opt: ?[]const u8) ParseError!ParameterSets {
        const sps = if (sps_raw_opt) |sps_raw| (Nalu.parse_h264_sps(sps_raw) catch return ParseError.InvalidSPS).header.h264.nal_unit.sps else null;
        const pps = if (pps_raw_opt) |pps_raw| (Nalu.parse_h264_pps(pps_raw) catch return ParseError.InvalidPPS).header.h264.nal_unit.pps else null;
        return .{ .h264 = .{ .sps = sps, .pps = pps } };
    }

    pub fn parse_h265(vps_raw_opt: ?[]const u8, sps_raw_opt: ?[]const u8, pps_raw_opt: ?[]const u8) ParseError!ParameterSets {
        const vps = if (vps_raw_opt) |vps_raw| (Nalu.parse_h265_vps(vps_raw) catch return ParseError.InvalidVPS).header.h265.nal_unit.vps else null;
        const sps = if (sps_raw_opt) |sps_raw| (Nalu.parse_h265_sps(sps_raw) catch return ParseError.InvalidSPS).header.h265.nal_unit.sps else null;
        const pps = if (pps_raw_opt) |pps_raw| (Nalu.parse_h265_pps(pps_raw) catch return ParseError.InvalidPPS).header.h265.nal_unit.pps else null;
        return .{ .h265 = .{ .vps = vps, .sps = sps, .pps = pps } };
    }

    pub const ParseBase64Error = ParseError || ParseParameterSetBase64Error;

    pub fn parse_h264_base64(sps_base64_opt: ?[]const u8, pps_base64_opt: ?[]const u8) ParseBase64Error!ParameterSets {
        var base64_buffer: [1024]u8 = undefined;
        const sps = if (sps_base64_opt) |sps_base64| (Nalu.parse_h264_sps(try parse_base64(sps_base64, &base64_buffer)) catch return ParseError.InvalidSPS).header.h264.nal_unit.sps else null;
        const pps = if (pps_base64_opt) |pps_base64| (Nalu.parse_h264_pps(try parse_base64(pps_base64, &base64_buffer)) catch return ParseError.InvalidPPS).header.h264.nal_unit.pps else null;
        return .{ .h264 = .{ .sps = sps, .pps = pps } };
    }

    pub fn parse_h265_base64(vps_base64_opt: ?[]const u8, sps_base64_opt: ?[]const u8, pps_base64_opt: ?[]const u8) ParseBase64Error!ParameterSets {
        var base64_buffer: [1024]u8 = undefined;
        const vps = if (vps_base64_opt) |vps_base64| (Nalu.parse_h265_vps(try parse_base64(vps_base64, &base64_buffer)) catch return ParseError.InvalidVPS).header.h265.nal_unit.vps else null;
        const sps = if (sps_base64_opt) |sps_base64| (Nalu.parse_h265_sps(try parse_base64(sps_base64, &base64_buffer)) catch return ParseError.InvalidSPS).header.h265.nal_unit.sps else null;
        const pps = if (pps_base64_opt) |pps_base64| (Nalu.parse_h265_pps(try parse_base64(pps_base64, &base64_buffer)) catch return ParseError.InvalidPPS).header.h265.nal_unit.pps else null;
        return .{ .h265 = .{ .vps = vps, .sps = sps, .pps = pps } };
    }

    const ParseParameterSetBase64Error = error{
        Overflow,
        InvalidParameterSetBase64,
    };

    inline fn parse_base64(source: []const u8, buffer: []u8) ParseParameterSetBase64Error![]const u8 {
        var base64_decoder = std.base64.standard.Decoder;
        const size = base64_decoder.calcSizeForSlice(source) catch return ParseParameterSetBase64Error.InvalidParameterSetBase64;
        if (size > buffer.len) return ParseParameterSetBase64Error.Overflow;
        base64_decoder.decode(buffer, source) catch return ParseParameterSetBase64Error.InvalidParameterSetBase64;
        return buffer[0..size];
    }
};
