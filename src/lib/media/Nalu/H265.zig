const std = @import("std");
const stdx = @import("stdx");
const Nalu = @import("../Nalu.zig");
const ParseError = Nalu.ParseError;
const RbspReader = Nalu.RbspReader;

pub const H265 = @This();

forbidden_zero_bit: u1,
nal_unit: union(Type) {
    unspecified,
    slice,
    idr,
    cra,
    sei,
    vps: VPS,
    sps: SPS,
    pps: PPS,
    aud,
},
nuh_layer_id: u6,
nuh_temporal_id_plus1: u3,

pub const Type = enum(u8) {
    unspecified,
    slice,
    idr,
    cra,
    sei,
    vps,
    sps,
    pps,
    aud,
};

pub const Profile = enum(u5) {
    main = 1,
    main10 = 2,
    main_still_picture = 3,
    rext = 4,
    high_throughput = 5,
    multiview_main = 6,
    scalable_main = 7,
    @"3d_main" = 8,
};

pub const VPS = struct {
    video_parameter_set_id: u4,

    pub fn parse(reader: *stdx.BitReader) (ParseError || std.Io.Reader.Error)!VPS {
        return .{ .video_parameter_set_id = try reader.readBits(u4) };
    }
};

pub const SPS = struct {
    video_parameter_set_id: u4,
    max_sub_layers_minus1: u3,
    temporal_id_nesting_flag: bool,
    profile_space: u2,
    profile_tier_flag: bool,
    profile_idc: Profile,
    profile_compat_flags: u32,
    constraint_indicator_flags: [6]u8,
    level_idc: u8,
    seq_parameter_set_id: u32,
    chroma_format_idc: u8,
    pic_width_in_luma_samples: u32,
    pic_height_in_luma_samples: u32,
    conformance_window: ?struct {
        left_offset: u32,
        right_offset: u32,
        top_offset: u32,
        bottom_offset: u32,
    } = null,
    bit_depth_luma_minus8: u8,
    bit_depth_chroma_minus8: u8,
    vui: ?VUI,

    pub const VUI = struct {
        timing_info: ?TimingInfo = null,

        pub const TimingInfo = struct {
            num_units_in_tick: u32,
            time_scale: u32,
        };

        pub fn parse(reader: *stdx.BitReader) std.Io.Reader.Error!VUI {
            const aspect_ratio_present_flag = try reader.readBit() == 1;
            if (aspect_ratio_present_flag) {
                const aspect_ratio_idc = try reader.readByte();
                if (aspect_ratio_idc == 255) try reader.skipBytes(4);
            }

            const overscan_info_present_flag = try reader.readBit() == 1;
            if (overscan_info_present_flag) try reader.skipBit();

            const video_signal_type_present_flag = try reader.readBit() == 1;
            if (video_signal_type_present_flag) {
                try reader.skipBits(4);
                const colour_description_present_flag = try reader.readBit() == 1;
                if (colour_description_present_flag) try reader.skipBytes(3);
            }

            const chroma_loc_info_present_flag = try reader.readBit() == 1;
            if (chroma_loc_info_present_flag) try reader.skipExpGolombs(2);

            try reader.skipBits(3);

            const default_display_window_flag = try reader.readBit() == 1;
            if (default_display_window_flag) try reader.skipExpGolombs(4);

            const timing_info_present_flag = try reader.readBit() == 1;
            const timing_info: ?TimingInfo = if (timing_info_present_flag) .{
                .num_units_in_tick = try reader.readBits(u32),
                .time_scale = try reader.readBits(u32),
            } else null;

            return .{ .timing_info = timing_info };
        }
    };

    pub fn parse(reader: *stdx.BitReader) (ParseError || std.Io.Reader.Error)!SPS {
        const video_parameter_set_id = try reader.readBits(u4);
        const max_sub_layers_minus1 = try reader.readBits(u3);
        const temporal_id_nesting_flag = try reader.readBit() == 1;
        const profile_space = try reader.readBits(u2);
        const profile_tier_flag = try reader.readBit() == 1;
        const profile_idc: Profile = @enumFromInt(try reader.readBits(u5));
        const profile_compat_flags = try reader.readBits(u32);
        const constraint_indicator_flags = try reader.readBytes(6);
        const level_idc = try reader.readByte();

        var sub_layer_profile_present_flags = [_]bool{false} ** 7;
        var sub_layer_level_present_flags = [_]bool{false} ** 7;
        const sub_layer_count: usize = @intCast(max_sub_layers_minus1);
        for (0..sub_layer_count) |sub_layer_index| {
            sub_layer_profile_present_flags[sub_layer_index] = try reader.readBit() == 1;
            sub_layer_level_present_flags[sub_layer_index] = try reader.readBit() == 1;
        }

        if (max_sub_layers_minus1 > 0) for (0..8 - sub_layer_count) |_| try reader.skipBits(2);

        for (0..sub_layer_count) |sub_layer_index| {
            if (sub_layer_profile_present_flags[sub_layer_index]) {
                try reader.skipBits(2);
                try reader.skipBit();
                try reader.skipBits(5);
                try reader.skipBytes(4);
                try reader.skipBytes(6);
            }
            if (sub_layer_level_present_flags[sub_layer_index]) try reader.skipByte();
        }

        const seq_parameter_set_id = try reader.readExpGolomb();
        const chroma_format_idc = std.math.cast(u8, try reader.readExpGolomb()) orelse return ParseError.Malformed;
        if (chroma_format_idc == 3) try reader.skipBit();

        const pic_width_in_luma_samples = try reader.readExpGolomb();
        const pic_height_in_luma_samples = try reader.readExpGolomb();

        const conformance_window: @FieldType(SPS, "conformance_window") =
            if (try reader.readBit() == 1) .{
                .left_offset = try reader.readExpGolomb(),
                .right_offset = try reader.readExpGolomb(),
                .top_offset = try reader.readExpGolomb(),
                .bottom_offset = try reader.readExpGolomb(),
            } else null;

        const bit_depth_luma_minus8 = std.math.cast(u8, try reader.readExpGolomb()) orelse return ParseError.Malformed;
        const bit_depth_chroma_minus8 = std.math.cast(u8, try reader.readExpGolomb()) orelse return ParseError.Malformed;

        const log2_max_pic_order_cnt_lsb_minus4 = try reader.readExpGolomb();

        const sub_layer_ordering_info_present_flag = try reader.readBit() == 1;
        if (sub_layer_ordering_info_present_flag) {
            for (0..sub_layer_count + 1) |_| {
                try reader.skipExpGolombs(3);
            }
        }

        try reader.skipExpGolombs(6);

        const scaling_lists_enabled_flag = try reader.readBit() == 1;
        if (scaling_lists_enabled_flag) try reader.skipBit();

        try reader.skipBits(2);

        const pcm_enabled_flag = try reader.readBit() == 1;
        if (pcm_enabled_flag) {
            try reader.skipBits(8);
            try reader.skipExpGolombs(2);
            try reader.skipBit();
        }

        try reader.skipExpGolomb();

        const long_term_ref_pics_present_flags = try reader.readBit() == 1;
        if (long_term_ref_pics_present_flags) {
            const num_long_term_ref_pics = @min(32, try reader.readExpGolomb());
            for (0..num_long_term_ref_pics) |_| try reader.skipBits(4 +| log2_max_pic_order_cnt_lsb_minus4 +| 1);
        }

        try reader.skipBits(2);

        const vui_present_flag = try reader.readBit() == 1;
        const vui: ?VUI = if (vui_present_flag) try VUI.parse(reader) else null;

        return .{
            .video_parameter_set_id = video_parameter_set_id,
            .max_sub_layers_minus1 = max_sub_layers_minus1,
            .temporal_id_nesting_flag = temporal_id_nesting_flag,
            .profile_space = profile_space,
            .profile_tier_flag = profile_tier_flag,
            .profile_idc = profile_idc,
            .profile_compat_flags = profile_compat_flags,
            .constraint_indicator_flags = constraint_indicator_flags,
            .level_idc = level_idc,
            .seq_parameter_set_id = seq_parameter_set_id,
            .chroma_format_idc = chroma_format_idc,
            .pic_width_in_luma_samples = pic_width_in_luma_samples,
            .pic_height_in_luma_samples = pic_height_in_luma_samples,
            .conformance_window = conformance_window,
            .bit_depth_luma_minus8 = bit_depth_luma_minus8,
            .bit_depth_chroma_minus8 = bit_depth_chroma_minus8,
            .vui = vui,
        };
    }
};

pub const PPS = struct {
    pps_pic_parameter_set_id: u32,
    pps_seq_parameter_set_id: u32,

    pub fn parse(reader: *stdx.BitReader) std.Io.Reader.Error!PPS {
        return .{
            .pps_pic_parameter_set_id = try reader.readExpGolomb(),
            .pps_seq_parameter_set_id = try reader.readExpGolomb(),
        };
    }
};

pub fn parse(slice: []const u8) ParseError!H265 {
    if (slice.len < 2) return ParseError.Malformed;

    var slice_reader = std.Io.Reader.fixed(slice);
    var rbsp_reader = RbspReader.init(&slice_reader);
    var reader = stdx.BitReader{ .reader = &rbsp_reader.interface };

    // reads for next two bytes can't fail because we already checked the slice len
    const forbidden_zero_bit = reader.readBit() catch unreachable;
    if (forbidden_zero_bit == 1) return ParseError.Malformed;
    const nal_unit = reader.readBits(u6) catch unreachable;
    const nuh_layer_id = reader.readBits(u6) catch unreachable;
    const nuh_temporal_id_plus1 = reader.readBits(u3) catch unreachable;
    if (nuh_temporal_id_plus1 == 0) return ParseError.Malformed;

    return .{
        .forbidden_zero_bit = forbidden_zero_bit,
        .nal_unit = switch (nal_unit) {
            0...9 => .slice,
            19, 20 => .idr,
            21 => .cra,
            32 => .{ .vps = VPS.parse(&reader) catch return ParseError.Malformed },
            33 => .{ .sps = SPS.parse(&reader) catch return ParseError.Malformed },
            34 => .{ .pps = PPS.parse(&reader) catch return ParseError.Malformed },
            35 => .aud,
            39, 40 => .sei,
            else => return ParseError.Unsupported,
        },
        .nuh_layer_id = nuh_layer_id,
        .nuh_temporal_id_plus1 = nuh_temporal_id_plus1,
    };
}
