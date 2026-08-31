const std = @import("std");
const stdx = @import("stdx");
const Nalu = @import("../Nalu.zig");
const ParseError = Nalu.ParseError;
const RbspReader = Nalu.RbspReader;

pub const H264 = @This();

forbidden_zero_bit: u1,
nal_ref_idc: u2,
nal_unit: union(Type) {
    unspecified,
    slice,
    idr,
    sei,
    sps: SPS,
    pps: PPS,
    aud,
},

pub const Type = enum(u8) {
    unspecified = 0,
    slice = 1,
    idr = 5,
    sei = 6,
    sps = 7,
    pps = 8,
    aud = 9,
    _,
};

pub const Profile = enum(u8) {
    cavlc_4_4_4_intra = 44,
    baseline = 66,
    main = 77,
    scalable_baseline = 83,
    scalable_high = 86,
    extended = 88,
    high = 100,
    high_10 = 110,
    multiview_high = 118,
    high_4_2_2 = 122,
    stereo_high = 128,
    mfc_high = 134,
    mfc_depth_high = 135,
    multiview_depth_high = 138,
    enhanced_multiview_depth_high = 139,
    high_4_4_4_predictive = 244,
    _,

    pub fn is_extended(self: Profile) bool {
        return switch (self) {
            .cavlc_4_4_4_intra,
            .scalable_baseline,
            .scalable_high,
            .high,
            .high_10,
            .multiview_high,
            .high_4_2_2,
            .stereo_high,
            .mfc_high,
            .mfc_depth_high,
            .multiview_depth_high,
            .enhanced_multiview_depth_high,
            .high_4_4_4_predictive,
            => true,
            else => false,
        };
    }
};

pub const PPS = struct {
    pic_parameter_set_id: u32,
    seq_parameter_set_id: u32,

    pub fn parse(reader: *stdx.BitReader) std.Io.Reader.Error!PPS {
        return .{
            .pic_parameter_set_id = try reader.readExpGolomb(),
            .seq_parameter_set_id = try reader.readExpGolomb(),
        };
    }
};

pub const SPS = struct {
    profile_idc: Profile,
    profile_compatibility: packed struct(u8) {
        _padding: u2 = 0,
        set5: bool = false,
        set4: bool = false,
        set3: bool = false,
        set2: bool = false,
        set1: bool = false,
        set0: bool = false,
    },
    level_idc: u8,
    seq_parameter_set_id: u32,
    chroma_format_idc: u8 = 1,
    bit_depth_luma_minus8: u8 = 0,
    bit_depth_chroma_minus8: u8 = 0,
    pic_width_in_mbs_minus1: u32,
    pic_height_in_map_units_minus1: u32,
    frame_mbs_only_flag: bool,
    frame_cropping: ?FrameCropping = null,
    vui: ?VUI,

    pub const FrameCropping = struct {
        left_offset: u32,
        right_offset: u32,
        top_offset: u32,
        bottom_offset: u32,
    };

    pub const VUI = struct {
        timing_info: ?TimingInfo = null,

        pub const TimingInfo = struct {
            num_units_in_tick: u32,
            time_scale: u32,
            fixed_frame_rate_flag: bool,
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
            if (chroma_loc_info_present_flag) {
                try reader.skipExpGolombs(2);
            }

            const timing_info_present_flag = try reader.readBit() == 1;
            const timing_info: ?TimingInfo = if (timing_info_present_flag) .{
                .num_units_in_tick = try reader.readBits(u32),
                .time_scale = try reader.readBits(u32),
                .fixed_frame_rate_flag = try reader.readBit() == 1,
            } else null;

            return .{ .timing_info = timing_info };
        }
    };

    pub fn parse(reader: *stdx.BitReader) (ParseError || std.Io.Reader.Error)!SPS {
        const profile_idc: Profile = @enumFromInt(try reader.readByte());
        const profile_compatibility: @FieldType(SPS, "profile_compatibility") = @bitCast(try reader.readByte());
        const level_idc = try reader.readByte();
        const seq_parameter_set_id = try reader.readExpGolomb();

        var chroma_format_idc: u8 = 1;
        var bit_depth_luma_minus8: u8 = 0;
        var bit_depth_chroma_minus8: u8 = 0;
        if (profile_idc.is_extended()) {
            chroma_format_idc = std.math.cast(u8, try reader.readExpGolomb()) orelse return ParseError.Malformed;
            if (chroma_format_idc > 3) return ParseError.Malformed;
            if (chroma_format_idc == 3) try reader.skipBit();
            bit_depth_luma_minus8 = std.math.cast(u8, try reader.readExpGolomb()) orelse return ParseError.Malformed;
            bit_depth_chroma_minus8 = std.math.cast(u8, try reader.readExpGolomb()) orelse return ParseError.Malformed;
            try reader.skipBit();
            if (try reader.readBit() == 1) try skip_scaling_matrix(reader, chroma_format_idc);
        }

        try reader.skipExpGolomb();

        switch (try reader.readExpGolomb()) {
            0 => try reader.skipExpGolomb(),
            1 => {
                try reader.skipBit();
                try reader.skipExpGolombs(2);

                const offset_count = try reader.readExpGolomb();
                for (0..offset_count) |_| try reader.skipExpGolomb();
            },
            2 => {},
            else => return ParseError.Malformed,
        }

        try reader.skipExpGolomb();
        try reader.skipBit();

        const pic_width_in_mbs_minus1 = try reader.readExpGolomb();
        const pic_height_in_map_units_minus1 = try reader.readExpGolomb();
        const frame_mbs_only_flag = try reader.readBit() == 1;

        if (!frame_mbs_only_flag) try reader.skipBit();
        try reader.skipBit();

        const frame_cropping = if (try reader.readBit() == 1) SPS.FrameCropping{
            .left_offset = try reader.readExpGolomb(),
            .right_offset = try reader.readExpGolomb(),
            .top_offset = try reader.readExpGolomb(),
            .bottom_offset = try reader.readExpGolomb(),
        } else null;

        const vui_present_flag = try reader.readBit() == 1;
        const vui: ?VUI = if (vui_present_flag) try VUI.parse(reader) else null;

        return .{
            .profile_idc = profile_idc,
            .profile_compatibility = profile_compatibility,
            .level_idc = level_idc,
            .seq_parameter_set_id = seq_parameter_set_id,
            .chroma_format_idc = chroma_format_idc,
            .bit_depth_luma_minus8 = bit_depth_luma_minus8,
            .bit_depth_chroma_minus8 = bit_depth_chroma_minus8,
            .pic_width_in_mbs_minus1 = pic_width_in_mbs_minus1,
            .pic_height_in_map_units_minus1 = pic_height_in_map_units_minus1,
            .frame_mbs_only_flag = frame_mbs_only_flag,
            .frame_cropping = frame_cropping,
            .vui = vui,
        };
    }

    fn skip_scaling_matrix(reader: *stdx.BitReader, chroma_format_idc: u8) std.Io.Reader.Error!void {
        const seq_scaling_list_count: usize = if (chroma_format_idc == 3) 12 else 8;
        for (0..seq_scaling_list_count) |i| if (try reader.readBit() == 1) try skip_scaling_list(reader, if (i < 6) 16 else 64);
    }

    fn skip_scaling_list(reader: *stdx.BitReader, size: usize) std.Io.Reader.Error!void {
        var last_scale: i32 = 0;
        var next_scale: i32 = 0;
        for (0..size) |_| {
            if (next_scale != 0) next_scale = (last_scale + try reader.readExpGolombSigned() + 256) & 255;
            if (next_scale != 0) last_scale = next_scale;
        }
    }
};

pub fn parse(slice: []const u8) ParseError!H264 {
    if (slice.len < 1) return ParseError.Malformed;

    var slice_reader = std.Io.Reader.fixed(slice);
    var rbsp_reader = RbspReader.init(&slice_reader);
    var reader = stdx.BitReader{ .reader = &rbsp_reader.interface };

    // reads for next byte can't fail because we already checked the slice len
    const forbidden_zero_bit = reader.readBit() catch unreachable;
    if (forbidden_zero_bit == 1) return ParseError.Malformed;
    const nal_ref_idc = reader.readBits(u2) catch unreachable;
    const nal_unit = reader.readBits(u5) catch unreachable;

    return .{
        .forbidden_zero_bit = forbidden_zero_bit,
        .nal_ref_idc = nal_ref_idc,
        .nal_unit = switch (nal_unit) {
            0 => .unspecified,
            1 => .slice,
            5 => .idr,
            6 => .sei,
            7 => .{ .sps = SPS.parse(&reader) catch return ParseError.Malformed },
            8 => .{ .pps = PPS.parse(&reader) catch return ParseError.Malformed },
            9 => .aud,
            else => return ParseError.Unsupported,
        },
    };
}
