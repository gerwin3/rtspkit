const media = @import("media");
const Nalu = media.Nalu;

const Dimensions = @import("Dimensions.zig");
const Rational = @import("Rational.zig");

pub fn display_dimensions(sps: *const Nalu.Header.H265.SPS) Dimensions {
    var out = Dimensions{
        .width = sps.pic_width_in_luma_samples,
        .height = sps.pic_height_in_luma_samples,
    };
    // The conformance window is akin to frame cropping in AVC.
    if (sps.conformance_window) |conformance_window| {
        const sub_width_c: u32, const sub_height_c: u32 = switch (sps.chroma_format_idc) {
            0 => .{ 1, 1 }, // monochrome
            1 => .{ 2, 2 }, // 4:2:0
            2 => .{ 2, 1 }, // 4:2:2
            3 => .{ 1, 1 }, // 4:4:4
            else => .{ 2, 2 }, // assume 4:2:2
        };
        out.width -|= (conformance_window.left_offset +| conformance_window.right_offset) *| sub_width_c;
        out.height -|= (conformance_window.top_offset +| conformance_window.bottom_offset) *| sub_height_c;
    }
    return out;
}

pub fn frame_rate(sps: *const Nalu.Header.H265.SPS) ?Rational {
    return if (sps.vui) |*vui| if (vui.timing_info) |*timing_info| .{
        .num = timing_info.time_scale,
        .den = timing_info.num_units_in_tick,
    } else null else null;
}
