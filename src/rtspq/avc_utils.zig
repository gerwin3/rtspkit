const media = @import("media");
const Nalu = media.Nalu;

const Dimensions = @import("Dimensions.zig");
const Rational = @import("Rational.zig");

pub fn display_dimensions(sps: *const Nalu.Header.H264.SPS) Dimensions {
    const frame_mbs_only_flag: u32 = if (sps.frame_mbs_only_flag) 1 else 0;
    // Dimensions need to be multiplied by macroblock size 16.
    // For height we need to convert from map units to macroblocks first.
    var out = Dimensions{
        .width = (sps.pic_width_in_mbs_minus1 +| 1) *| 16,
        .height = (sps.pic_height_in_map_units_minus1 +| 1) *| (2 -| frame_mbs_only_flag) *| 16,
    };
    if (sps.frame_cropping) |frame_cropping| {
        const sub_width_c: u32, const sub_height_c: u32 = switch (sps.chroma_format_idc) {
            0 => .{ 1, 1 }, // monochrome
            1 => .{ 2, 2 }, // 4:2:0
            2 => .{ 2, 1 }, // 4:2:2
            3 => .{ 1, 1 }, // 4:4:4
            else => .{ 2, 2 }, // assume 4:2:2
        };
        out.width -|= (frame_cropping.left_offset +| frame_cropping.right_offset) *| sub_width_c;
        out.height -|= (frame_cropping.top_offset +| frame_cropping.bottom_offset) *| sub_height_c *| (2 -| frame_mbs_only_flag);
    }
    return out;
}

pub fn frame_rate(sps: *const Nalu.Header.H264.SPS) ?Rational {
    return if (sps.vui) |*vui| if (vui.timing_info) |*timing_info| .{
        .num = timing_info.time_scale,
        // For AVC we need to divide num_units_in_tick by 2. I don't know
        // why and did not bother to figure it out. For HEVC this is not
        // necessary.
        .den = timing_info.num_units_in_tick *| 2,
    } else null else null;
}
