const std = @import("std");
const stdx = @import("stdx");

const Codec = @import("codec.zig").Codec;

pub const Nalu = @This();

header: Header,
/// NALU data excluding startcode.
data: []const u8,

/// NALU backing memory including startcode, header and payload.
/// This exists so downstream code can properly free the underlying memory.
slice: []const u8,

pub const Header = union(Codec) {
    h264: H264,
    h265: H265,

    pub const H264 = @import("Nalu/H264.zig");
    pub const H265 = @import("Nalu/H265.zig");
};

pub const ParseError = error{ Malformed, Unsupported };

/// Parse H.264 NALU that includes Annex B startcode.
pub fn parse_h264_annex_b(slice: []const u8) ParseError!Nalu {
    var slice_without_startcode = slice;
    if (std.mem.startsWith(u8, slice, &.{ 0x00, 0x00, 0x01 })) slice_without_startcode = slice[3..];
    if (std.mem.startsWith(u8, slice, &.{ 0x00, 0x00, 0x00, 0x01 })) slice_without_startcode = slice[4..];
    return .{
        .header = .{ .h264 = try Header.H264.parse(slice_without_startcode) },
        .data = slice_without_startcode,
        .slice = slice,
    };
}

/// Parse H.264 bare NALU.
pub fn parse_h264(slice: []const u8) ParseError!Nalu {
    return .{
        .header = .{ .h264 = try Header.H264.parse(slice) },
        .data = slice,
        .slice = slice,
    };
}

/// Parse H.264 bare SPS NALU.
/// Returns ParseError.Malformed if NALU is not SPS.
pub fn parse_h264_sps(slice: []const u8) ParseError!Nalu {
    const nalu = try Nalu.parse_h264(slice);
    return if (nalu.header.h264.nal_unit == .sps) nalu else ParseError.Malformed;
}

/// Parse H.264 bare PPS NALU.
/// Returns ParseError.Malformed if NALU is not PPS.
pub fn parse_h264_pps(slice: []const u8) ParseError!Nalu {
    const nalu = try Nalu.parse_h264(slice);
    return if (nalu.header.h264.nal_unit == .pps) nalu else ParseError.Malformed;
}

/// Parse H.265 NALU that includes Annex B startcode.
pub fn parse_h265_annex_b(slice: []const u8) ParseError!Nalu {
    var slice_without_startcode = slice;
    if (std.mem.startsWith(u8, slice, &.{ 0x00, 0x00, 0x01 })) slice_without_startcode = slice[3..];
    if (std.mem.startsWith(u8, slice, &.{ 0x00, 0x00, 0x00, 0x01 })) slice_without_startcode = slice[4..];
    return .{
        .header = .{ .h265 = try Header.H265.parse(slice_without_startcode) },
        .data = slice_without_startcode,
        .slice = slice,
    };
}

/// Parse H.265 bare NALU.
pub fn parse_h265(slice: []const u8) ParseError!Nalu {
    return .{
        .header = .{ .h265 = try Header.H265.parse(slice) },
        .data = slice,
        .slice = slice,
    };
}

/// Parse H.265 bare VPS NALU.
/// Returns ParseError.Malformed if NALU is not VPS.
pub fn parse_h265_vps(slice: []const u8) ParseError!Nalu {
    const nalu = try Nalu.parse_h265(slice);
    return if (nalu.header.h265.nal_unit == .vps) nalu else ParseError.Malformed;
}

/// Parse H.265 bare SPS NALU.
/// Returns ParseError.Malformed if NALU is not SPS.
pub fn parse_h265_sps(slice: []const u8) ParseError!Nalu {
    const nalu = try Nalu.parse_h265(slice);
    return if (nalu.header.h265.nal_unit == .sps) nalu else ParseError.Malformed;
}

/// Parse H.265 bare PPS NALU.
/// Returns ParseError.Malformed if NALU is not PPS.
pub fn parse_h265_pps(slice: []const u8) ParseError!Nalu {
    const nalu = try Nalu.parse_h265(slice);
    return if (nalu.header.h265.nal_unit == .pps) nalu else ParseError.Malformed;
}

test "parse_h264_annex_b high 1080p cropped SPS" {
    const sps = "\x00\x00\x00\x01\x67\x64\x00\x28\xac\xd9\x40\x78\x02\x27\xe5\xc0\x5a\x80\x80\x80\xa0\x00\x00\x03\x00\x20\x00\x00\x07\x81\xe3\x06\x32\xc0";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h264 = .{
                .forbidden_zero_bit = 0,
                .nal_ref_idc = 3,
                .nal_unit = .{ .sps = .{
                    .profile_idc = .high,
                    .profile_compatibility = .{},
                    .level_idc = 40,
                    .seq_parameter_set_id = 0,
                    .pic_width_in_mbs_minus1 = 119,
                    .pic_height_in_map_units_minus1 = 67,
                    .frame_mbs_only_flag = true,
                    .frame_cropping = .{
                        .left_offset = 0,
                        .right_offset = 0,
                        .top_offset = 0,
                        .bottom_offset = 4,
                    },
                    .vui = .{
                        .timing_info = .{
                            .num_units_in_tick = 1,
                            .time_scale = 60,
                            .fixed_frame_rate_flag = false,
                        },
                    },
                } },
            } },
            .data = sps[4..],
            .slice = sps,
        },
        try Nalu.parse_h264_annex_b(sps),
    );
}

test "parse_h264_annex_b high 1080p PPS" {
    const pps = "\x00\x00\x00\x01\x68\xe9\x3b\x2c\x8b";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h264 = .{
                .forbidden_zero_bit = 0,
                .nal_ref_idc = 3,
                .nal_unit = .{ .pps = .{
                    .pic_parameter_set_id = 0,
                    .seq_parameter_set_id = 0,
                } },
            } },
            .data = pps[4..],
            .slice = pps,
        },
        try Nalu.parse_h264_annex_b(pps),
    );
}

test "parse_h264_annex_b main 1080p SPS" {
    const sps = "\x00\x00\x00\x01\x67\x4d\x40\x28\x9a\x64\x03\xc0\x11\x3f\x2e\x02\xdc\x14\x34\x14\x08";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h264 = .{
                .forbidden_zero_bit = 0,
                .nal_ref_idc = 3,
                .nal_unit = .{ .sps = .{
                    .profile_idc = .main,
                    .profile_compatibility = .{ .set1 = true },
                    .level_idc = 40,
                    .seq_parameter_set_id = 0,
                    .pic_width_in_mbs_minus1 = 119,
                    .pic_height_in_map_units_minus1 = 67,
                    .frame_mbs_only_flag = true,
                    .frame_cropping = .{
                        .left_offset = 0,
                        .right_offset = 0,
                        .top_offset = 0,
                        .bottom_offset = 4,
                    },
                    .vui = .{ .timing_info = null },
                } },
            } },
            .data = sps[4..],
            .slice = sps,
        },
        try Nalu.parse_h264_annex_b(sps),
    );
}

test "parse_h264_annex_b main 1080p PPS" {
    const pps = "\x00\x00\x00\x01\x68\xee\x38\x80";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h264 = .{
                .forbidden_zero_bit = 0,
                .nal_ref_idc = 3,
                .nal_unit = .{ .pps = .{
                    .pic_parameter_set_id = 0,
                    .seq_parameter_set_id = 0,
                } },
            } },
            .data = pps[4..],
            .slice = pps,
        },
        try Nalu.parse_h264_annex_b(pps),
    );
}

test "parse_h264_annex_b constrained baseline 1080p cropped SPS" {
    const sps = "\x00\x00\x00\x01\x67\x42\xc0\x1e\xda\x01\xe0\x08\x9f\x97\x01\x6a\x02\x02\x02\x80\x00\x00\x03\x00\x80\x00\x00\x1e\x07\x8b\x17\x50";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h264 = .{
                .forbidden_zero_bit = 0,
                .nal_ref_idc = 3,
                .nal_unit = .{ .sps = .{
                    .profile_idc = .baseline,
                    .profile_compatibility = .{
                        .set0 = true,
                        .set1 = true,
                    },
                    .level_idc = 30,
                    .seq_parameter_set_id = 0,
                    .pic_width_in_mbs_minus1 = 119,
                    .pic_height_in_map_units_minus1 = 67,
                    .frame_mbs_only_flag = true,
                    .frame_cropping = .{
                        .left_offset = 0,
                        .right_offset = 0,
                        .top_offset = 0,
                        .bottom_offset = 4,
                    },
                    .vui = .{
                        .timing_info = .{
                            .num_units_in_tick = 1,
                            .time_scale = 60,
                            .fixed_frame_rate_flag = false,
                        },
                    },
                } },
            } },
            .data = sps[4..],
            .slice = sps,
        },
        try Nalu.parse_h264_annex_b(sps),
    );
}

test "parse_h264_annex_b constrained baseline 1080p PPS" {
    const pps = "\x00\x00\x00\x01\x68\xce\x0f\x2c\x80";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h264 = .{
                .forbidden_zero_bit = 0,
                .nal_ref_idc = 3,
                .nal_unit = .{ .pps = .{
                    .pic_parameter_set_id = 0,
                    .seq_parameter_set_id = 0,
                } },
            } },
            .data = pps[4..],
            .slice = pps,
        },
        try Nalu.parse_h264_annex_b(pps),
    );
}

test "parse_h265_annex_b main level 120 VPS" {
    const vps = "\x00\x00\x00\x01\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x78\x95\x98\x09";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h265 = .{
                .forbidden_zero_bit = 0,
                .nal_unit = .{ .vps = .{ .video_parameter_set_id = 0 } },
                .nuh_layer_id = 0,
                .nuh_temporal_id_plus1 = 1,
            } },
            .data = vps[4..],
            .slice = vps,
        },
        try Nalu.parse_h265_annex_b(vps),
    );
}

test "parse_h265_annex_b main level 120 1080p SPS" {
    const sps = "\x00\x00\x00\x01\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x78\xa0\x03\xc0\x80\x10\xe5\x96\x56\x69\x24\xca\xf0\x16\x9c\x20\x00\x00\x03\x00\x20\x00\x00\x03\x03\xc1";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h265 = .{
                .forbidden_zero_bit = 0,
                .nal_unit = .{ .sps = .{
                    .video_parameter_set_id = 0,
                    .max_sub_layers_minus1 = 0,
                    .temporal_id_nesting_flag = true,
                    .profile_space = 0,
                    .profile_tier_flag = false,
                    .profile_idc = .main,
                    .profile_compat_flags = 0x6000_0000,
                    .constraint_indicator_flags = .{ 0x90, 0x00, 0x00, 0x00, 0x00, 0x00 },
                    .level_idc = 120,
                    .seq_parameter_set_id = 0,
                    .chroma_format_idc = 1,
                    .pic_width_in_luma_samples = 1920,
                    .pic_height_in_luma_samples = 1080,
                    .bit_depth_luma_minus8 = 0,
                    .bit_depth_chroma_minus8 = 0,
                    .vui = .{
                        .timing_info = .{
                            .num_units_in_tick = 1,
                            .time_scale = 30,
                        },
                    },
                } },
                .nuh_layer_id = 0,
                .nuh_temporal_id_plus1 = 1,
            } },
            .data = sps[4..],
            .slice = sps,
        },
        try Nalu.parse_h265_annex_b(sps),
    );
}

test "parse_h265_annex_b main PPS" {
    const pps = "\x00\x00\x00\x01\x44\x01\xc1\x72\xb4\x62\x40";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h265 = .{
                .forbidden_zero_bit = 0,
                .nal_unit = .{ .pps = .{
                    .pps_pic_parameter_set_id = 0,
                    .pps_seq_parameter_set_id = 0,
                } },
                .nuh_layer_id = 0,
                .nuh_temporal_id_plus1 = 1,
            } },
            .data = pps[4..],
            .slice = pps,
        },
        try Nalu.parse_h265_annex_b(pps),
    );
}

test "parse_h265_annex_b main level 93 VPS" {
    const vps = "\x00\x00\x00\x01\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5d\x95\x98\x09";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h265 = .{
                .forbidden_zero_bit = 0,
                .nal_unit = .{ .vps = .{ .video_parameter_set_id = 0 } },
                .nuh_layer_id = 0,
                .nuh_temporal_id_plus1 = 1,
            } },
            .data = vps[4..],
            .slice = vps,
        },
        try Nalu.parse_h265_annex_b(vps),
    );
}

test "parse_h265_annex_b main level 93 720p SPS" {
    const sps = "\x00\x00\x00\x01\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5d\xa0\x02\x80\x80\x2d\x16\x59\x59\xa4\x93\x2b\x80\x40\x00\x00\xfa\x40\x00\x17\x70\x02";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h265 = .{
                .forbidden_zero_bit = 0,
                .nal_unit = .{ .sps = .{
                    .video_parameter_set_id = 0,
                    .max_sub_layers_minus1 = 0,
                    .temporal_id_nesting_flag = true,
                    .profile_space = 0,
                    .profile_tier_flag = false,
                    .profile_idc = .main,
                    .profile_compat_flags = 0x6000_0000,
                    .constraint_indicator_flags = .{ 0x90, 0x00, 0x00, 0x00, 0x00, 0x00 },
                    .level_idc = 93,
                    .seq_parameter_set_id = 0,
                    .chroma_format_idc = 1,
                    .pic_width_in_luma_samples = 1280,
                    .pic_height_in_luma_samples = 720,
                    .bit_depth_luma_minus8 = 0,
                    .bit_depth_chroma_minus8 = 0,
                    .vui = .{
                        .timing_info = .{
                            .num_units_in_tick = 1001,
                            .time_scale = 24000,
                        },
                    },
                } },
                .nuh_layer_id = 0,
                .nuh_temporal_id_plus1 = 1,
            } },
            .data = sps[4..],
            .slice = sps,
        },
        try Nalu.parse_h265_annex_b(sps),
    );
}

test "parse_h265_annex_b main 720p PPS" {
    const pps = "\x00\x00\x00\x01\x44\x01\xc1\x72\xb4\x62\x40";
    try std.testing.expectEqualDeep(
        Nalu{
            .header = .{ .h265 = .{
                .forbidden_zero_bit = 0,
                .nal_unit = .{ .pps = .{
                    .pps_pic_parameter_set_id = 0,
                    .pps_seq_parameter_set_id = 0,
                } },
                .nuh_layer_id = 0,
                .nuh_temporal_id_plus1 = 1,
            } },
            .data = pps[4..],
            .slice = pps,
        },
        try Nalu.parse_h265_annex_b(pps),
    );
}

pub const RbspReader = @import("Nalu/RbspReader.zig").RbspReader;

pub const AnnexBIterator = @import("Nalu/AnnexBIterator.zig").AnnexBIterator;

test {
    std.testing.refAllDecls(@This());
}
