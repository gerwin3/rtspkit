const std = @import("std");

const Codec = @import("codec.zig").Codec;
const Nalu = @import("Nalu.zig");

pub const Track = struct {
    /// Timescale expressed as units per second.
    timescale: u32,

    /// Track dimensions.
    dims: struct {
        width: u16 = 0,
        height: u16 = 0,
    },

    /// Track codec information, stored in parameter sets.
    ///
    /// This determines the codec and carries the codec-specific parameter set NALUs.
    /// - For H.264 this carries the SPS and PPS.
    /// - For H.265 this carries the VPS, SPS and PPS.
    codec: union(Codec) {
        /// H.264 Parameter Sets
        h264: struct {
            sps: *const Nalu,
            pps: *const Nalu,
        },

        /// H.265 Parameter Sets
        h265: struct {
            vps: *const Nalu,
            sps: *const Nalu,
            pps: *const Nalu,
        },
    },

    /// Track samples. Each sample contains the NALU and sample duration.
    /// Track samples contains only actual VCL NALUs. Parameter sets are stored in `parameter_sets`.
    samples: []const Nalu,

    /// Duration per sample.
    sample_duration: u32,
};

pub const Options = struct {
    /// The calendar date and time of creation of the file in seconds since
    /// midnight, January 1, 1904, preferably using coordinated universal time
    /// (UTC).
    creation_time: u64 = 0,

    /// The calendar date and time of last modification of the file in seconds
    /// since midnight, January 1, 1904, preferably using coordinated universal
    /// time (UTC).
    modification_time: u64 = 0,
};

pub fn write_mp4(track: *const Track, writer: *std.Io.Writer, options: Options) std.Io.Writer.Error!void {
    var sample_entry: SampleEntry = undefined;

    switch (track.codec) {
        .h264 => |parameter_sets| {
            const sps_info = parameter_sets.sps.header.h264.nal_unit.sps;

            sample_entry = .{
                .avc1 = .{
                    .data_reference_index = 1,
                    .width = track.dims.width,
                    .height = track.dims.height,
                    .horizresolution = 0x0048_0000,
                    .vertresolution = 0x0048_0000,
                    .compressor_name = "VideoHandler",
                    .avcc = .{
                        .configuration_version = 1,
                        .avc_profile_indication = sps_info.profile_idc,
                        .profile_compatibility = @bitCast(sps_info.profile_compatibility),
                        .avc_level_indication = sps_info.level_idc,
                        .chroma_format = sps_info.chroma_format_idc,
                        .bit_depth_luma_minus8 = sps_info.bit_depth_luma_minus8,
                        .bit_depth_chroma_minus8 = sps_info.bit_depth_chroma_minus8,
                        .sequence_parameter_set = parameter_sets.sps.data,
                        .picture_parameter_set = parameter_sets.pps.data,
                    },
                },
            };
        },
        .h265 => |parameter_sets| {
            const sps_info = parameter_sets.sps.header.h265.nal_unit.sps;

            sample_entry = .{ .hvc1 = .{
                .data_reference_index = 1,
                .width = track.dims.width,
                .height = track.dims.height,
                .horizresolution = 0x0048_0000,
                .vertresolution = 0x0048_0000,
                .compressor_name = "VideoHandler",
                .hvcc = .{
                    .configuration_version = 1,
                    .general_profile_space = sps_info.profile_space,
                    .general_tier_flag = sps_info.profile_tier_flag,
                    .general_profile_idc = @intFromEnum(sps_info.profile_idc),
                    .general_profile_compatibility_flags = sps_info.profile_compat_flags,
                    .general_constraint_indicator_flags = sps_info.constraint_indicator_flags,
                    .general_level_idc = sps_info.level_idc,
                    .min_spatial_segmentation_idc = 0,
                    .parallelism_type = 0,
                    .chroma_format = sps_info.chroma_format_idc,
                    .bit_depth_luma_minus8 = sps_info.bit_depth_luma_minus8,
                    .bit_depth_chroma_minus8 = sps_info.bit_depth_chroma_minus8,
                    .avg_frame_rate = 0,
                    .constant_frame_rate = 0,
                    .num_temporal_layers = @as(u8, sps_info.max_sub_layers_minus1) + 1,
                    .temporal_id_nested = sps_info.temporal_id_nesting_flag,
                    .video_parameter_set = parameter_sets.vps.data,
                    .sequence_parameter_set = parameter_sets.sps.data,
                    .picture_parameter_set = parameter_sets.pps.data,
                },
            } };
        },
    }

    var traks = [1]TrakBox{.{
        .tkhd = .{
            .creation_time = options.creation_time,
            .modification_time = options.modification_time,
            .track_id = 1,
            .duration = track.samples.len *| track.sample_duration,
            .width = track.dims.width,
            .height = track.dims.height,
        },
        .mdia = .{
            .mdhd = .{
                .creation_time = options.creation_time,
                .modification_time = options.modification_time,
                .timescale = track.timescale,
                .duration = track.samples.len *| track.sample_duration,
                .language = 0x55c4,
            },
            .hdlr = .video,
            .minf = .{
                .vmhd = .{},
                .dinf = .{},
                .stbl = .{
                    .stsd = .{ .sample_entry = sample_entry },
                    .stts = .{ .entries = .{.{
                        .sample_count = @intCast(track.samples.len),
                        .sample_duration = track.sample_duration,
                    }} },
                    .stsc = .{ .entries = .{.{
                        .first_chunk = 1,
                        .samples_per_chunk = 1,
                        .sample_description_index = 1,
                    }} },
                    .stsz = .{ .samples = track.samples },
                    .stco = .{
                        .chunk_offset = undefined,
                        .samples = track.samples,
                    },
                },
            },
        },
    }};

    var container = Container{
        .ftyp = .{
            .major_brand = .{ 'i', 's', 'o', 'm' },
            .minor_version = 0x200,
            .compatible_brands = switch (track.codec) {
                .h264 => FtypBox.compatible_brands_h264,
                .h265 => FtypBox.compatible_brands_h265,
            },
        },
        .moov = .{
            .mvhd = .{
                .creation_time = options.creation_time,
                .modification_time = options.modification_time,
                .timescale = track.timescale,
                .duration = track.samples.len *| track.sample_duration,
                .next_track_id = 1,
            },
            .traks = &traks,
        },
        .mdat = .{ .samples = track.samples },
    };

    const offset_mdat = FtypBox.size + container.moov.size();
    const offset_chunk = offset_mdat + box_header_size;
    traks[0].mdia.minf.stbl.stco.chunk_offset = offset_chunk;

    const mp4_writer = Writer{ .writer = writer };
    try container.write(mp4_writer);
}

const box_header_size: u32 = @sizeOf(u32) + @sizeOf([4]u8);

pub const Container = struct {
    ftyp: FtypBox,
    moov: MoovBox,
    mdat: MdatBox,

    pub fn write(self: *const Container, writer: Writer) std.Io.Writer.Error!void {
        try self.ftyp.write(writer);
        try self.moov.write(writer);
        try self.mdat.write(writer);
    }
};

pub const FtypBox = struct {
    major_brand: [4]u8,
    minor_version: u32,
    compatible_brands: [4][4]u8,

    const compatible_brands_h264 = [4][4]u8{ .{ 'i', 's', 'o', 'm' }, .{ 'i', 's', 'o', '2' }, .{ 'a', 'v', 'c', '1' }, .{ 'm', 'p', '4', '1' } };
    const compatible_brands_h265 = [4][4]u8{ .{ 'i', 's', 'o', 'm' }, .{ 'i', 's', 'o', '6' }, .{ 'h', 'v', 'c', '1' }, .{ 'm', 'p', '4', '1' } };

    pub const size: u32 = box_header_size + box_size_fields(FtypBox, .{});

    pub fn write(self: *const FtypBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
    }

    inline fn write_header(self: *const FtypBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_box_header(FtypBox.size, "ftyp");
    }

    inline fn write_fields(self: *const FtypBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_fourcc(self.major_brand);
        try writer.write_u32(self.minor_version);
        inline for (self.compatible_brands) |compatible_brand| try writer.write_fourcc(compatible_brand);
    }
};

pub const MoovBox = struct {
    mvhd: MvhdBox,
    traks: []const TrakBox,

    pub fn size(self: *const MoovBox) u32 {
        var size_out = box_header_size + MvhdBox.size;
        for (self.traks) |*trak| size_out += trak.size();
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const MoovBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_boxes(writer);
    }

    inline fn write_header(self: *const MoovBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "moov");
    }

    inline fn write_boxes(self: *const MoovBox, writer: Writer) std.Io.Writer.Error!void {
        try self.mvhd.write(writer);
        for (self.traks) |*trak| try trak.write(writer);
    }
};

pub const MvhdBox = struct {
    creation_time: u64,
    modification_time: u64,
    timescale: u32,
    duration: u64,
    next_track_id: u32,

    pub const size: u32 = box_header_size + box_size_fields(MvhdBox, .{});

    pub fn write(self: *const MvhdBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_headers(writer);
        try self.write_fields(writer);
    }

    inline fn write_headers(self: *const MvhdBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_box_header(MvhdBox.size, "mvhd");
    }

    inline fn write_fields(self: *const MvhdBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_u8(1);
        try writer.write_u24(0);
        try writer.write_u64(self.creation_time);
        try writer.write_u64(self.modification_time);
        try writer.write_u32(self.timescale);
        try writer.write_u64(self.duration);
        try writer.write_fixed_16_16(1, 0);
        try writer.write_fixed_8_8(0, 0);
        try writer.write_u16(0);
        try writer.write_u32(0);
        try writer.write_u32(0);
        try writer.write_unity_matrix();
        inline for (0..6) |_| try writer.write_u32(0);
        try writer.write_u32(self.next_track_id);
    }
};

pub const TrakBox = struct {
    tkhd: TkhdBox,
    mdia: MdiaBox,

    pub fn size(self: *const TrakBox) u32 {
        const size_out = box_header_size + TkhdBox.size + self.mdia.size();
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const TrakBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_boxes(writer);
    }

    inline fn write_header(self: *const TrakBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "trak");
    }

    inline fn write_boxes(self: *const TrakBox, writer: Writer) std.Io.Writer.Error!void {
        try self.tkhd.write(writer);
        try self.mdia.write(writer);
    }
};

pub const TkhdBox = struct {
    creation_time: u64,
    modification_time: u64,
    track_id: u32,
    duration: u64,
    width: u16,
    height: u16,

    pub const size: u32 = box_header_size + box_size_fields(TkhdBox, .{});

    pub fn write(self: *const TkhdBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
    }

    inline fn write_header(self: *const TkhdBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_box_header(TkhdBox.size, "tkhd");
    }

    inline fn write_fields(self: *const TkhdBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_u8(1);
        try writer.write_u24(0x000007);
        try writer.write_u64(self.creation_time);
        try writer.write_u64(self.modification_time);
        try writer.write_u32(self.track_id);
        try writer.write_u32(0);
        try writer.write_u64(self.duration);
        try writer.write_u32(0);
        try writer.write_u32(0);
        try writer.write_u16(0);
        try writer.write_u16(0);
        try writer.write_fixed_8_8(0, 0);
        try writer.write_u16(0);
        try writer.write_unity_matrix();
        try writer.write_u32(@as(u32, self.width) << 16);
        try writer.write_u32(@as(u32, self.height) << 16);
    }
};

pub const MdiaBox = struct {
    mdhd: MdhdBox,
    hdlr: HdlrBox,
    minf: MinfBox,

    pub fn size(self: *const MdiaBox) u32 {
        const size_out = box_header_size + MdhdBox.size + self.hdlr.size() + self.minf.size();
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const MdiaBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_boxes(writer);
    }

    inline fn write_header(self: *const MdiaBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "mdia");
    }

    inline fn write_boxes(self: *const MdiaBox, writer: Writer) std.Io.Writer.Error!void {
        try self.mdhd.write(writer);
        try self.hdlr.write(writer);
        try self.minf.write(writer);
    }
};

pub const MdhdBox = struct {
    creation_time: u64,
    modification_time: u64,
    timescale: u32,
    duration: u64,
    language: u16,

    pub const size: u32 = box_header_size + box_size_fields(MdhdBox, .{});

    pub fn write(self: *const MdhdBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
    }

    inline fn write_header(self: *const MdhdBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_box_header(MdhdBox.size, "mdhd");
    }

    inline fn write_fields(self: *const MdhdBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_u8(1);
        try writer.write_u24(0);
        try writer.write_u64(self.creation_time);
        try writer.write_u64(self.modification_time);
        try writer.write_u32(self.timescale);
        try writer.write_u64(self.duration);
        try writer.write_u16(self.language);
        try writer.write_u16(0);
    }
};

pub const HdlrBox = struct {
    handler_type: [4]u8,
    name: []const u8,

    pub const video = HdlrBox{
        .handler_type = .{ 'v', 'i', 'd', 'e' },
        .name = "VideoHandler",
    };

    pub fn size(self: *const HdlrBox) u32 {
        const size_fields = comptime box_size_fields(HdlrBox, .{ .name = "" });
        const size_out = box_header_size + size_fields + self.name.len;
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const HdlrBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
    }

    inline fn write_header(self: *const HdlrBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "hdlr");
    }

    inline fn write_fields(self: *const HdlrBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_u8(0);
        try writer.write_u24(0);
        try writer.write_u32(0);
        try writer.write_fourcc(self.handler_type);
        try writer.write_u32(0);
        try writer.write_u32(0);
        try writer.write_u32(0);
        try writer.write(self.name);
        try writer.write_u8(0);
    }
};

pub const MinfBox = struct {
    vmhd: VmhdBox,
    dinf: DinfBox,
    stbl: StblBox,

    pub fn size(self: *const MinfBox) u32 {
        const size_out = box_header_size + VmhdBox.size + DinfBox.size + self.stbl.size();
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const MinfBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_boxes(writer);
    }

    inline fn write_header(self: *const MinfBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "minf");
    }

    inline fn write_boxes(self: *const MinfBox, writer: Writer) std.Io.Writer.Error!void {
        try self.vmhd.write(writer);
        try self.dinf.write(writer);
        try self.stbl.write(writer);
    }
};

pub const VmhdBox = struct {
    pub const size: u32 = box_header_size + box_size_fields(VmhdBox, .{});

    pub fn write(self: *const VmhdBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
    }

    inline fn write_header(self: *const VmhdBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_box_header(VmhdBox.size, "vmhd");
    }

    inline fn write_fields(self: *const VmhdBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_u8(0);
        try writer.write_u24(1);
        try writer.write_u16(0);
        try writer.write_u16(0);
        try writer.write_u16(0);
        try writer.write_u16(0);
    }
};

pub const DinfBox = struct {
    dref: DrefBox = .{},

    pub const size: u32 = box_header_size + DrefBox.size;

    pub fn write(self: *const DinfBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_boxes(writer);
    }

    inline fn write_header(self: *const DinfBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_box_header(DinfBox.size, "dinf");
    }

    inline fn write_boxes(self: *const DinfBox, writer: Writer) std.Io.Writer.Error!void {
        try self.dref.write(writer);
    }
};

pub const DrefBox = struct {
    entry: DataEntryBox = .{ .url = .self_contained },

    pub const size: u32 = box_header_size + box_size_fields(DrefBox, .{}) + DataEntryBox.size;

    pub fn write(self: *const DrefBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
        try self.write_boxes(writer);
    }

    inline fn write_header(self: *const DrefBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_box_header(DrefBox.size, "dref");
    }

    inline fn write_fields(self: *const DrefBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_u8(0);
        try writer.write_u24(0);
        try writer.write_u32(1);
    }

    inline fn write_boxes(self: *const DrefBox, writer: Writer) std.Io.Writer.Error!void {
        try self.entry.write(writer);
    }
};

pub const DataEntryBox = union(enum) {
    url: UrlBox,

    pub const size: u32 = UrlBox.size;

    pub fn write(self: *const DataEntryBox, writer: Writer) std.Io.Writer.Error!void {
        switch (self.*) {
            .url => |url| try url.write(writer),
        }
    }
};

pub const UrlBox = enum {
    self_contained,

    pub const size: u32 = box_header_size + 4;

    pub fn write(self: UrlBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
    }

    inline fn write_header(self: UrlBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_box_header(UrlBox.size, "url ");
    }

    inline fn write_fields(self: UrlBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_u8(0);
        try writer.write_u24(1);
    }
};

pub const StblBox = struct {
    stsd: StsdBox,
    stts: SttsBox,
    stsc: StscBox,
    stsz: StszBox,
    stco: StcoBox,

    pub fn size(self: *const StblBox) u32 {
        const size_out = box_header_size + self.stsd.size() + SttsBox.size + StscBox.size + self.stsz.size() + self.stco.size();
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const StblBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_boxes(writer);
    }

    inline fn write_header(self: *const StblBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "stbl");
    }

    inline fn write_boxes(self: *const StblBox, writer: Writer) std.Io.Writer.Error!void {
        try self.stsd.write(writer);
        try self.stts.write(writer);
        try self.stsc.write(writer);
        try self.stsz.write(writer);
        try self.stco.write(writer);
    }
};

pub const StsdBox = struct {
    sample_entry: SampleEntry,

    pub fn size(self: *const StsdBox) u32 {
        const size_fields = comptime box_size_fields(StsdBox, .{ .sample_entry = SampleEntry{ .avc1 = std.mem.zeroInit(Avc1SampleEntry, .{}) } });
        const size_out = box_header_size + size_fields + self.sample_entry.size();
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const StsdBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
        try self.write_boxes(writer);
    }

    inline fn write_header(self: *const StsdBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "stsd");
    }

    inline fn write_fields(self: *const StsdBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_u8(0);
        try writer.write_u24(0);
        try writer.write_u32(1);
    }

    inline fn write_boxes(self: *const StsdBox, writer: Writer) std.Io.Writer.Error!void {
        try self.sample_entry.write(writer);
    }
};

pub const SampleEntry = union(enum) {
    avc1: Avc1SampleEntry,
    hvc1: Hvc1SampleEntry,

    pub fn size(self: *const SampleEntry) u32 {
        return switch (self.*) {
            .avc1 => |avc1| avc1.size(),
            .hvc1 => |hvc1| hvc1.size(),
        };
    }

    pub fn write(self: *const SampleEntry, writer: Writer) std.Io.Writer.Error!void {
        switch (self.*) {
            .avc1 => |avc1| try avc1.write(writer),
            .hvc1 => |hvc1| try hvc1.write(writer),
        }
    }
};

pub const Avc1SampleEntry = struct {
    data_reference_index: u16,
    width: u16,
    height: u16,
    horizresolution: u32,
    vertresolution: u32,
    compressor_name: []const u8,
    avcc: AvcCBox,

    pub fn size(self: *const Avc1SampleEntry) u32 {
        const size_fields = comptime box_size_fields(Avc1SampleEntry, .{});
        const size_out = box_header_size + size_fields + self.avcc.size();
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const Avc1SampleEntry, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
        try self.write_boxes(writer);
    }

    inline fn write_header(self: *const Avc1SampleEntry, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "avc1");
    }

    inline fn write_fields(self: *const Avc1SampleEntry, writer: Writer) std.Io.Writer.Error!void {
        inline for (0..6) |_| try writer.write_u8(0);
        try writer.write_u16(self.data_reference_index);
        try writer.write_u16(0);
        try writer.write_u16(0);
        try writer.write_u32(0);
        try writer.write_u32(0);
        try writer.write_u32(0);
        try writer.write_u16(self.width);
        try writer.write_u16(self.height);
        try writer.write_u32(self.horizresolution);
        try writer.write_u32(self.vertresolution);
        try writer.write_u32(0);
        try writer.write_u16(1);
        try writer.write_pascal_string_32(self.compressor_name);
        try writer.write_u16(0x0018);
        try writer.write_i16(-1);
    }

    inline fn write_boxes(self: *const Avc1SampleEntry, writer: Writer) std.Io.Writer.Error!void {
        try self.avcc.write(writer);
    }
};

pub const AvcCBox = struct {
    configuration_version: u8,
    avc_profile_indication: Nalu.Header.H264.Profile,
    profile_compatibility: u8,
    avc_level_indication: u8,
    chroma_format: u8 = 1,
    bit_depth_luma_minus8: u8 = 0,
    bit_depth_chroma_minus8: u8 = 0,
    sequence_parameter_set: []const u8,
    picture_parameter_set: []const u8,

    pub fn size(self: *const AvcCBox) u32 {
        const size_fields = comptime box_size_fields(AvcCBox, .{});
        const size_fields_extra: u32 = if (self.avc_profile_indication.is_extended()) 4 else 0;
        const size_out = box_header_size + size_fields + size_fields_extra + self.sequence_parameter_set.len + self.picture_parameter_set.len;
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const AvcCBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
    }

    inline fn write_header(self: *const AvcCBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "avcC");
    }

    inline fn write_fields(self: *const AvcCBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_u8(self.configuration_version);
        try writer.write_u8(@intFromEnum(self.avc_profile_indication));
        try writer.write_u8(self.profile_compatibility);
        try writer.write_u8(self.avc_level_indication);
        try writer.write_u8(3 | 0b1111_1100);
        try write_acc_array(writer, 0b1110_0000 | 1, self.sequence_parameter_set);
        try write_acc_array(writer, 1, self.picture_parameter_set);
        if (self.avc_profile_indication.is_extended()) {
            try writer.write_u8(0xFC | (self.chroma_format & 0x03));
            try writer.write_u8(0xF8 | (self.bit_depth_luma_minus8 & 0x07));
            try writer.write_u8(0xF8 | (self.bit_depth_chroma_minus8 & 0x07));
            try writer.write_u8(0);
        }
    }

    inline fn write_acc_array(writer: Writer, nal_unit_type: u8, nal_unit: []const u8) std.Io.Writer.Error!void {
        try writer.write_u8(nal_unit_type);
        try writer.write_u16(@intCast(nal_unit.len));
        try writer.write(nal_unit);
    }
};

pub const Hvc1SampleEntry = struct {
    data_reference_index: u16,
    width: u16,
    height: u16,
    horizresolution: u32,
    vertresolution: u32,
    compressor_name: []const u8,
    hvcc: HvcCBox,

    pub fn size(self: *const Hvc1SampleEntry) u32 {
        const size_fields = comptime box_size_fields(Hvc1SampleEntry, .{});
        const size_out = box_header_size + size_fields + self.hvcc.size();
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const Hvc1SampleEntry, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
        try self.write_boxes(writer);
    }

    inline fn write_header(self: *const Hvc1SampleEntry, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "hvc1");
    }

    inline fn write_fields(self: *const Hvc1SampleEntry, writer: Writer) std.Io.Writer.Error!void {
        inline for (0..6) |_| try writer.write_u8(0);
        try writer.write_u16(self.data_reference_index);
        try writer.write_u16(0);
        try writer.write_u16(0);
        try writer.write_u32(0);
        try writer.write_u32(0);
        try writer.write_u32(0);
        try writer.write_u16(self.width);
        try writer.write_u16(self.height);
        try writer.write_u32(self.horizresolution);
        try writer.write_u32(self.vertresolution);
        try writer.write_u32(0);
        try writer.write_u16(1);
        try writer.write_pascal_string_32(self.compressor_name);
        try writer.write_u16(0x0018);
        try writer.write_i16(-1);
    }

    inline fn write_boxes(self: *const Hvc1SampleEntry, writer: Writer) std.Io.Writer.Error!void {
        try self.hvcc.write(writer);
    }
};

pub const HvcCBox = struct {
    configuration_version: u8,
    general_profile_space: u8,
    general_tier_flag: bool,
    general_profile_idc: u8,
    general_profile_compatibility_flags: u32,
    general_constraint_indicator_flags: [6]u8,
    general_level_idc: u8,
    min_spatial_segmentation_idc: u16,
    parallelism_type: u8,
    chroma_format: u8,
    bit_depth_luma_minus8: u8,
    bit_depth_chroma_minus8: u8,
    avg_frame_rate: u16,
    constant_frame_rate: u8,
    num_temporal_layers: u8,
    temporal_id_nested: bool,
    video_parameter_set: []const u8,
    sequence_parameter_set: []const u8,
    picture_parameter_set: []const u8,

    pub fn size(self: *const HvcCBox) u32 {
        const size_fields = comptime box_size_fields(HvcCBox, .{});
        const size_out = box_header_size + size_fields + self.video_parameter_set.len + self.sequence_parameter_set.len + self.picture_parameter_set.len;
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const HvcCBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
    }

    inline fn write_header(self: *const HvcCBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "hvcC");
    }

    inline fn write_fields(self: *const HvcCBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_u8(self.configuration_version);
        try writer.write_u8(((self.general_profile_space & 0x03) << 6) | (@as(u8, @intFromBool(self.general_tier_flag)) << 5) | (self.general_profile_idc & 0x1f));
        try writer.write_u32(self.general_profile_compatibility_flags);
        try writer.write(self.general_constraint_indicator_flags[0..4]);
        try writer.write(self.general_constraint_indicator_flags[4..6]);
        try writer.write_u8(self.general_level_idc);
        try writer.write_u16(0xF000 | (self.min_spatial_segmentation_idc & 0x0FFF));
        try writer.write_u8(0xFC | (self.parallelism_type & 0x03));
        try writer.write_u8(0xFC | (self.chroma_format & 0x03));
        try writer.write_u8(0xF8 | (self.bit_depth_luma_minus8 & 0x07));
        try writer.write_u8(0xF8 | (self.bit_depth_chroma_minus8 & 0x07));
        try writer.write_u16(self.avg_frame_rate);
        try writer.write_u8(((self.constant_frame_rate & 0x03) << 6) | ((self.num_temporal_layers & 0x07) << 3) | (@as(u8, @intFromBool(self.temporal_id_nested)) << 2) | (3 & 0x03));
        try writer.write_u8(3);
        try write_hvcc_array(writer, 32, self.video_parameter_set);
        try write_hvcc_array(writer, 33, self.sequence_parameter_set);
        try write_hvcc_array(writer, 34, self.picture_parameter_set);
    }

    inline fn write_hvcc_array(writer: Writer, nal_unit_type: u8, nal_unit: []const u8) std.Io.Writer.Error!void {
        try writer.write_u8(nal_unit_type & 0x3f);
        try writer.write_u16(1);
        try writer.write_u16(@intCast(nal_unit.len));
        try writer.write(nal_unit);
    }
};

pub const SttsBox = struct {
    entries: [1]Entry,

    pub const Entry = struct {
        sample_count: u32,
        sample_duration: u32,
    };

    pub const size: u32 = box_header_size + box_size_fields(SttsBox, .{});

    pub fn write(self: *const SttsBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
    }

    inline fn write_header(self: *const SttsBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_box_header(SttsBox.size, "stts");
    }

    inline fn write_fields(self: *const SttsBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_u8(0);
        try writer.write_u24(0);
        try writer.write_u32(self.entries.len);
        // SttsBox currently support only a single entry.
        try writer.write_u32(@intCast(self.entries[0].sample_count));
        try writer.write_u32(@intCast(self.entries[0].sample_duration));
    }
};

pub const StscBox = struct {
    entries: [1]Entry,

    pub const Entry = struct {
        first_chunk: u32,
        samples_per_chunk: u32,
        sample_description_index: u32,
    };

    pub const size: u32 = box_header_size + box_size_fields(StscBox, .{});

    pub fn write(self: *const StscBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
    }

    inline fn write_header(self: *const StscBox, writer: Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.write_box_header(StscBox.size, "stsc");
    }

    inline fn write_fields(self: *const StscBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_u8(0);
        try writer.write_u24(0);
        try writer.write_u32(self.entries.len);
        // StscBox currently supports only a single entry.
        try writer.write_u32(self.entries[0].first_chunk);
        try writer.write_u32(self.entries[0].samples_per_chunk);
        try writer.write_u32(self.entries[0].sample_description_index);
    }
};

pub const StszBox = struct {
    samples: []const Nalu,

    pub fn size(self: *const StszBox) u32 {
        const size_fields = comptime box_size_fields(StszBox, .{});
        const size_out = box_header_size + size_fields + (self.samples.len * @sizeOf(u32));
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const StszBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
        try self.write_data(writer);
    }

    inline fn write_header(self: *const StszBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "stsz");
    }

    inline fn write_fields(self: *const StszBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_u8(0);
        try writer.write_u24(0);
        try writer.write_u32(0);
        try writer.write_u32(@intCast(self.samples.len));
    }

    inline fn write_data(self: *const StszBox, writer: Writer) std.Io.Writer.Error!void {
        for (self.samples) |*sample| try writer.write_u32(@intCast(@sizeOf(u32) + sample.data.len));
    }
};

pub const StcoBox = struct {
    /// Offset to first sample.
    chunk_offset: u64,
    samples: []const Nalu,

    pub fn size(self: *const StcoBox) u32 {
        const size_fields = comptime box_size_fields(StcoBox, .{});
        const size_out = box_header_size + size_fields + (self.samples.len * @sizeOf(u32));
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return @intCast(size_out);
    }

    pub fn write(self: *const StcoBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_fields(writer);
        try self.write_data(writer);
    }

    inline fn write_header(self: *const StcoBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "stco");
    }

    inline fn write_fields(self: *const StcoBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_u8(0);
        try writer.write_u24(0);
        try writer.write_u32(@intCast(self.samples.len));
    }

    inline fn write_data(self: *const StcoBox, writer: Writer) std.Io.Writer.Error!void {
        var chunk_offset = self.chunk_offset;
        for (self.samples) |*sample| {
            try writer.write_u32(@intCast(chunk_offset));
            chunk_offset += @intCast(@sizeOf(u32) + sample.data.len);
        }
    }
};

pub const MdatBox = struct {
    samples: []const Nalu,

    pub fn size(self: *const MdatBox) u32 {
        var size_out: u32 = box_header_size;
        for (self.samples) |*sample| size_out += @intCast(@sizeOf(u32) + sample.data.len);
        std.debug.assert(size_out <= std.math.maxInt(u32));
        return size_out;
    }

    pub fn write(self: *const MdatBox, writer: Writer) std.Io.Writer.Error!void {
        try self.write_header(writer);
        try self.write_data(writer);
    }

    inline fn write_header(self: *const MdatBox, writer: Writer) std.Io.Writer.Error!void {
        try writer.write_box_header(self.size(), "mdat");
    }

    inline fn write_data(self: *const MdatBox, writer: Writer) std.Io.Writer.Error!void {
        for (self.samples) |*sample| {
            try writer.write_u32(@intCast(sample.data.len));
            try writer.write(sample.data);
        }
    }
};

const Writer = struct {
    writer: *std.Io.Writer,

    pub inline fn write(self: Writer, slice: []const u8) std.Io.Writer.Error!void {
        try self.writer.writeAll(slice);
    }

    pub inline fn write_box_header(self: Writer, size: u32, comptime fourcc: []const u8) std.Io.Writer.Error!void {
        comptime std.debug.assert(fourcc.len == 4);
        try self.write_u32(@intCast(size));
        try self.write_fourcc(fourcc[0..4].*);
    }

    pub inline fn write_fourcc(self: Writer, fourcc: [4]u8) std.Io.Writer.Error!void {
        try self.write(&fourcc);
    }

    pub inline fn write_u8(self: Writer, value: u8) std.Io.Writer.Error!void {
        try self.writer.writeByte(value);
    }

    pub inline fn write_u16(self: Writer, value: u16) std.Io.Writer.Error!void {
        try self.writer.writeInt(u16, value, .big);
    }

    pub inline fn write_u24(self: Writer, value: u32) std.Io.Writer.Error!void {
        try self.writer.writeInt(u24, value, .big);
    }

    pub inline fn write_u32(self: Writer, value: u32) std.Io.Writer.Error!void {
        try self.writer.writeInt(u32, value, .big);
    }

    pub inline fn write_u64(self: Writer, value: u64) std.Io.Writer.Error!void {
        try self.writer.writeInt(u64, value, .big);
    }

    pub inline fn write_i16(self: Writer, value: i16) std.Io.Writer.Error!void {
        try self.writer.writeInt(i16, value, .big);
    }

    pub inline fn write_i32(self: Writer, value: i32) std.Io.Writer.Error!void {
        try self.writer.writeInt(i32, value, .big);
    }

    pub inline fn write_fixed_16_16(self: Writer, integer: u16, fraction: u16) std.Io.Writer.Error!void {
        try self.write_u16(integer);
        try self.write_u16(fraction);
    }

    pub inline fn write_fixed_8_8(self: Writer, integer: u8, fraction: u8) std.Io.Writer.Error!void {
        try self.write_u8(integer);
        try self.write_u8(fraction);
    }

    pub inline fn write_pascal_string_32(self: Writer, string: []const u8) std.Io.Writer.Error!void {
        var bytes = [_]u8{0} ** 32;
        if (string.len > 0) {
            const string_len = @min(string.len, 31);
            bytes[0] = @intCast(string_len);
            @memcpy(bytes[1 .. 1 + string_len], string[0..string_len]);
        }
        try self.write(&bytes);
    }

    pub inline fn write_unity_matrix(self: Writer) std.Io.Writer.Error!void {
        try self.write_u32(0x0001_0000);
        try self.write_u32(0);
        try self.write_u32(0);
        try self.write_u32(0);
        try self.write_u32(0x0001_0000);
        try self.write_u32(0);
        try self.write_u32(0);
        try self.write_u32(0);
        try self.write_u32(0x4000_0000);
    }
};

inline fn box_size_fields(Box: type, init: anytype) u32 {
    var buffer: [1024]u8 = undefined;
    var discarding_writer = std.Io.Writer.Discarding.init(&buffer);
    const writer = Writer{ .writer = &discarding_writer.writer };
    std.mem.zeroInit(Box, init).write_fields(writer) catch unreachable;
    return @intCast(discarding_writer.fullCount());
}

test "FtypBox writes H264 brands" {
    try expect_write(
        "\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2avc1mp41",
        &FtypBox{
            .major_brand = .{ 'i', 's', 'o', 'm' },
            .minor_version = 0x200,
            .compatible_brands = .{ .{ 'i', 's', 'o', 'm' }, .{ 'i', 's', 'o', '2' }, .{ 'a', 'v', 'c', '1' }, .{ 'm', 'p', '4', '1' } },
        },
    );
}

test "FtypBox writes isom iso2 avc1 mp41 brands" {
    try expect_write(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x69\x73\x6f\x6d\x00\x00\x02\x00\x69\x73\x6f\x6d\x69\x73\x6f\x32\x61\x76\x63\x31\x6d\x70\x34\x31",
        &FtypBox{
            .major_brand = .{ 'i', 's', 'o', 'm' },
            .minor_version = 0x200,
            .compatible_brands = .{
                .{ 'i', 's', 'o', 'm' },
                .{ 'i', 's', 'o', '2' },
                .{ 'a', 'v', 'c', '1' },
                .{ 'm', 'p', '4', '1' },
            },
        },
    );
}

test "FtypBox writes mp42 mp41 isom avc1 brands" {
    try expect_write(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x6d\x70\x34\x32\x00\x00\x00\x00\x6d\x70\x34\x32\x6d\x70\x34\x31\x69\x73\x6f\x6d\x61\x76\x63\x31",
        &FtypBox{
            .major_brand = .{ 'm', 'p', '4', '2' },
            .minor_version = 0,
            .compatible_brands = .{
                .{ 'm', 'p', '4', '2' },
                .{ 'm', 'p', '4', '1' },
                .{ 'i', 's', 'o', 'm' },
                .{ 'a', 'v', 'c', '1' },
            },
        },
    );
}

test "HdlrBox.video writes vide handler name" {
    try expect_write(
        "\x00\x00\x00\x2d\x68\x64\x6c\x72\x00\x00\x00\x00\x00\x00\x00\x00\x76\x69\x64\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x56\x69\x64\x65\x6f\x48\x61\x6e\x64\x6c\x65\x72\x00",
        HdlrBox.video,
    );
}

test "VmhdBox writes default graphics mode" {
    try expect_write(
        "\x00\x00\x00\x14\x76\x6d\x68\x64\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00",
        &VmhdBox{},
    );
}

test "UrlBox self contained writes self-contained flag" {
    try expect_write(
        "\x00\x00\x00\x0c\x75\x72\x6c\x20\x00\x00\x00\x01",
        UrlBox.self_contained,
    );
}

test "DrefBox default entry writes one self-contained url" {
    try expect_write(
        "\x00\x00\x00\x1c\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0c\x75\x72\x6c\x20\x00\x00\x00\x01",
        &DrefBox{},
    );
}

test "DinfBox default entry writes one self-contained url" {
    try expect_write(
        "\x00\x00\x00\x24\x64\x69\x6e\x66\x00\x00\x00\x1c\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0c\x75\x72\x6c\x20\x00\x00\x00\x01",
        &DinfBox{},
    );
}

test "SttsBox writes single constant-duration entry" {
    try expect_write(
        "\x00\x00\x00\x18\x73\x74\x74\x73\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x01\x24\x00\x00\x0e\xa6",
        &SttsBox{
            .entries = .{.{
                .sample_count = 292,
                .sample_duration = 3750,
            }},
        },
    );
}

test "AvcCBox writes main profile level 3.2 payload" {
    try expect_write(
        "\x00\x00\x00\x35\x61\x76\x63\x43\x01\x4d\x40\x32\xff\xe1\x00\x1e\x67\x4d\x40\x32\x8d\x8d\x40\x15\x00\x5f\xfc\xb8\x0b\x70\x10\x10\x14\x00\x00\x0f\xa0\x00\x02\xee\x02\x76\x82\x21\x1a\x80\x01\x00\x04\x68\xee\x38\x80",
        &AvcCBox{
            .configuration_version = 1,
            .avc_profile_indication = .main,
            .profile_compatibility = 0x40,
            .avc_level_indication = 0x32,
            .sequence_parameter_set = "\x67\x4d\x40\x32\x8d\x8d\x40\x15\x00\x5f\xfc\xb8\x0b\x70\x10\x10\x14\x00\x00\x0f\xa0\x00\x02\xee\x02\x76\x82\x21\x1a\x80",
            .picture_parameter_set = "\x68\xee\x38\x80",
        },
    );
}

test "AvcCBox writes constrained baseline profile level 3.0 payload" {
    try expect_write(
        "\x00\x00\x00\x34\x61\x76\x63\x43\x01\x42\xc0\x1e\xff\xe1\x00\x1c\x67\x42\xc0\x1e\xda\x01\xe0\x08\x9f\x97\x01\x6a\x12\x24\x12\x80\x00\x00\x03\x00\x80\x00\x00\x1e\x07\x8b\x17\x50\x01\x00\x05\x68\xce\x0f\x2c\x80",
        &AvcCBox{
            .configuration_version = 1,
            .avc_profile_indication = .baseline,
            .profile_compatibility = 0xc0,
            .avc_level_indication = 0x1e,
            .sequence_parameter_set = "\x67\x42\xc0\x1e\xda\x01\xe0\x08\x9f\x97\x01\x6a\x12\x24\x12\x80\x00\x00\x03\x00\x80\x00\x00\x1e\x07\x8b\x17\x50",
            .picture_parameter_set = "\x68\xce\x0f\x2c\x80",
        },
    );
}

test "AvcCBox writes high profile level 5.2 extension bytes" {
    try expect_write(
        "\x00\x00\x00\x38\x61\x76\x63\x43\x01\x64\x00\x34\xff\xe1\x00\x1c\x67\x64\x00\x34\xac\xd9\x80\x3c\x00\x43\xe9\xa8\x08\x08\x0a\x00\x00\x03\x00\x02\x00\x01\xd4\xc0\x1e\x30\x63\x34\x01\x00\x05\x68\xe9\x7b\x2c\x8b\xfd\xf8\xf8\x00",
        &AvcCBox{
            .configuration_version = 1,
            .avc_profile_indication = .high,
            .profile_compatibility = 0x00,
            .avc_level_indication = 0x34,
            .sequence_parameter_set = "\x67\x64\x00\x34\xac\xd9\x80\x3c\x00\x43\xe9\xa8\x08\x08\x0a\x00\x00\x03\x00\x02\x00\x01\xd4\xc0\x1e\x30\x63\x34",
            .picture_parameter_set = "\x68\xe9\x7b\x2c\x8b",
        },
    );
}

test "HvcCBox writes main profile 8-bit 4:2:0 level 93 payload" {
    try expect_write(
        "\x00\x00\x00\x74\x68\x76\x63\x43\x01\x01\x60\x00\x00\x00\x90\x00\x00\x00\x00\x00\x5d\xf0\x00\xfc\xfd\xf8\xf8\x00\x00\x0f\x03\x20\x00\x01\x00\x18\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5d\x95\x98\x09\x21\x00\x01\x00\x27\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5d\xa0\x02\x80\x80\x2d\x16\x59\x59\xa4\x93\x2b\x80\x40\x00\x00\xfa\x40\x00\x17\x70\x02\x22\x00\x01\x00\x07\x44\x01\xc1\x72\xb4\x62\x40",
        &HvcCBox{
            .configuration_version = 1,
            .general_profile_space = 0,
            .general_tier_flag = false,
            .general_profile_idc = 1,
            .general_profile_compatibility_flags = 0x6000_0000,
            .general_constraint_indicator_flags = .{ 0x90, 0x00, 0x00, 0x00, 0x00, 0x00 },
            .general_level_idc = 0x5d,
            .min_spatial_segmentation_idc = 0,
            .parallelism_type = 0,
            .chroma_format = 1,
            .bit_depth_luma_minus8 = 0,
            .bit_depth_chroma_minus8 = 0,
            .avg_frame_rate = 0,
            .constant_frame_rate = 0,
            .num_temporal_layers = 1,
            .temporal_id_nested = true,
            .video_parameter_set = "\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5d\x95\x98\x09",
            .sequence_parameter_set = "\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5d\xa0\x02\x80\x80\x2d\x16\x59\x59\xa4\x93\x2b\x80\x40\x00\x00\xfa\x40\x00\x17\x70\x02",
            .picture_parameter_set = "\x44\x01\xc1\x72\xb4\x62\x40",
        },
    );
}

test "StscBox writes single-chunk 25-sample table" {
    try expect_write(
        "\x00\x00\x00\x1c\x73\x74\x73\x63\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x19\x00\x00\x00\x01",
        &StscBox{
            .entries = .{.{
                .first_chunk = 1,
                .samples_per_chunk = 25,
                .sample_description_index = 1,
            }},
        },
    );
}

test "MvhdBox writes version 1 timescale 50 duration 10" {
    try expect_write(
        "\x00\x00\x00\x78\x6d\x76\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x32\x00\x00\x00\x00\x00\x00\x00\x0a\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01",
        &MvhdBox{
            .creation_time = 0,
            .modification_time = 0,
            .timescale = 50,
            .duration = 10,
            .next_track_id = 1,
        },
    );
}

test "TkhdBox writes version 1 320x240 duration 10" {
    try expect_write(
        "\x00\x00\x00\x68\x74\x6b\x68\x64\x01\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x01\x40\x00\x00\x00\xf0\x00\x00",
        &TkhdBox{
            .creation_time = 0,
            .modification_time = 0,
            .track_id = 1,
            .duration = 10,
            .width = 320,
            .height = 240,
        },
    );
}

test "MdhdBox writes version 1 timescale 50 duration 10" {
    try expect_write(
        "\x00\x00\x00\x2c\x6d\x64\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x32\x00\x00\x00\x00\x00\x00\x00\x0a\x55\xc4\x00\x00",
        &MdhdBox{
            .creation_time = 0,
            .modification_time = 0,
            .timescale = 50,
            .duration = 10,
            .language = 0x55c4,
        },
    );
}

test "StszBox writes 5 h264 sample sizes" {
    try expect_write(
        "\x00\x00\x00\x28\x73\x74\x73\x7a\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x08\x00\x00\x00\x11\x00\x00\x00\x0e\x00\x00\x00\x0e\x00\x00\x00\x0e",
        &StszBox{
            .samples = &.{
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 3, .nal_unit = .idr } },
                    .data = "\x65\xaa\xbb\xcc",
                    .slice = "\x65\xaa\xbb\xcc",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 2, .nal_unit = .slice } },
                    .data = "\x41\x9a\x24\x6c\x43\xbf\xfe\xa9\x96\x00\x00\x6f\xc0",
                    .slice = "\x41\x9a\x24\x6c\x43\xbf\xfe\xa9\x96\x00\x00\x6f\xc0",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 2, .nal_unit = .slice } },
                    .data = "\x41\x9e\x42\x78\x85\xff\x00\x00\x83\x81",
                    .slice = "\x41\x9e\x42\x78\x85\xff\x00\x00\x83\x81",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 0, .nal_unit = .slice } },
                    .data = "\x01\x9e\x61\x74\x42\xbf\x00\x00\xb6\x80",
                    .slice = "\x01\x9e\x61\x74\x42\xbf\x00\x00\xb6\x80",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 0, .nal_unit = .slice } },
                    .data = "\x01\x9e\x63\x6a\x42\xbf\x00\x00\xb6\x81",
                    .slice = "\x01\x9e\x63\x6a\x42\xbf\x00\x00\xb6\x81",
                },
            },
        },
    );
}

test "StcoBox writes 5 h264 chunk offsets" {
    try expect_write(
        "\x00\x00\x00\x24\x73\x74\x63\x6f\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x02\xdd\x00\x00\x02\xe5\x00\x00\x02\xf6\x00\x00\x03\x04\x00\x00\x03\x12",
        &StcoBox{
            .chunk_offset = 0x2dd,
            .samples = &.{
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 3, .nal_unit = .idr } },
                    .data = "\x65\xaa\xbb\xcc",
                    .slice = "\x65\xaa\xbb\xcc",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 2, .nal_unit = .slice } },
                    .data = "\x41\x9a\x24\x6c\x43\xbf\xfe\xa9\x96\x00\x00\x6f\xc0",
                    .slice = "\x41\x9a\x24\x6c\x43\xbf\xfe\xa9\x96\x00\x00\x6f\xc0",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 2, .nal_unit = .slice } },
                    .data = "\x41\x9e\x42\x78\x85\xff\x00\x00\x83\x81",
                    .slice = "\x41\x9e\x42\x78\x85\xff\x00\x00\x83\x81",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 0, .nal_unit = .slice } },
                    .data = "\x01\x9e\x61\x74\x42\xbf\x00\x00\xb6\x80",
                    .slice = "\x01\x9e\x61\x74\x42\xbf\x00\x00\xb6\x80",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 0, .nal_unit = .slice } },
                    .data = "\x01\x9e\x63\x6a\x42\xbf\x00\x00\xb6\x81",
                    .slice = "\x01\x9e\x63\x6a\x42\xbf\x00\x00\xb6\x81",
                },
            },
        },
    );
}

test "MdatBox writes 5 h264 samples" {
    try expect_write(
        "\x00\x00\x00\x4b\x6d\x64\x61\x74\x00\x00\x00\x04\x65\xaa\xbb\xcc\x00\x00\x00\x0d\x41\x9a\x24\x6c\x43\xbf\xfe\xa9\x96\x00\x00\x6f\xc0\x00\x00\x00\x0a\x41\x9e\x42\x78\x85\xff\x00\x00\x83\x81\x00\x00\x00\x0a\x01\x9e\x61\x74\x42\xbf\x00\x00\xb6\x80\x00\x00\x00\x0a\x01\x9e\x63\x6a\x42\xbf\x00\x00\xb6\x81",
        &MdatBox{
            .samples = &.{
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 3, .nal_unit = .idr } },
                    .data = "\x65\xaa\xbb\xcc",
                    .slice = "\x65\xaa\xbb\xcc",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 2, .nal_unit = .slice } },
                    .data = "\x41\x9a\x24\x6c\x43\xbf\xfe\xa9\x96\x00\x00\x6f\xc0",
                    .slice = "\x41\x9a\x24\x6c\x43\xbf\xfe\xa9\x96\x00\x00\x6f\xc0",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 2, .nal_unit = .slice } },
                    .data = "\x41\x9e\x42\x78\x85\xff\x00\x00\x83\x81",
                    .slice = "\x41\x9e\x42\x78\x85\xff\x00\x00\x83\x81",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 0, .nal_unit = .slice } },
                    .data = "\x01\x9e\x61\x74\x42\xbf\x00\x00\xb6\x80",
                    .slice = "\x01\x9e\x61\x74\x42\xbf\x00\x00\xb6\x80",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 0, .nal_unit = .slice } },
                    .data = "\x01\x9e\x63\x6a\x42\xbf\x00\x00\xb6\x81",
                    .slice = "\x01\x9e\x63\x6a\x42\xbf\x00\x00\xb6\x81",
                },
            },
        },
    );
}

test "write_mp4 writes 320x240 h264 high profile 25 fps subset" {
    try expect_write_mp4(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x69\x73\x6F\x6D\x00\x00\x02\x00\x69\x73\x6F\x6D\x69\x73\x6F\x32\x61\x76\x63\x31\x6D\x70\x34\x31\x00\x00\x02\xB5\x6D\x6F\x6F\x76\x00\x00\x00\x78\x6D\x76\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x32\x00\x00\x00\x00\x00\x00\x00\x0A\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x02\x35\x74\x72\x61\x6B\x00\x00\x00\x68\x74\x6B\x68\x64\x01\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x01\x40\x00\x00\x00\xF0\x00\x00\x00\x00\x01\xC5\x6D\x64\x69\x61\x00\x00\x00\x2C\x6D\x64\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x32\x00\x00\x00\x00\x00\x00\x00\x0A\x00\x55\xC4\x00\x00\x00\x00\x00\x2D\x68\x64\x6C\x72\x00\x00\x00\x00\x00\x00\x00\x00\x76\x69\x64\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x01\x64\x6D\x69\x6E\x66\x00\x00\x00\x14\x76\x6D\x68\x64\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x24\x64\x69\x6E\x66\x00\x00\x00\x1C\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0C\x75\x72\x6C\x20\x00\x00\x00\x01\x00\x00\x01\x24\x73\x74\x62\x6C\x00\x00\x00\x9C\x73\x74\x73\x64\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x8C\x61\x76\x63\x31\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x40\x00\xF0\x00\x48\x00\x00\x00\x48\x00\x00\x00\x00\x00\x00\x00\x01\x0C\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x18\xFF\xFF\x00\x00\x00\x36\x61\x76\x63\x43\x01\x64\x00\x0D\xFF\xE1\x00\x19\x67\x64\x00\x0D\xAC\xD9\x41\x41\xFB\x01\x10\x00\x00\x03\x00\x10\x00\x00\x03\x03\x20\xF1\x42\x99\x60\x01\x00\x06\x68\xEB\xE3\xCB\x22\xC0\xFD\xF8\xF8\x00\x00\x00\x00\x18\x73\x74\x74\x73\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x05\x00\x00\x02\x00\x00\x00\x00\x1C\x73\x74\x73\x63\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x28\x73\x74\x73\x7A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x08\x00\x00\x00\x11\x00\x00\x00\x0E\x00\x00\x00\x0E\x00\x00\x00\x0E\x00\x00\x00\x24\x73\x74\x63\x6F\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x02\xDD\x00\x00\x02\xE5\x00\x00\x02\xF6\x00\x00\x03\x04\x00\x00\x03\x12\x00\x00\x00\x4B\x6D\x64\x61\x74\x00\x00\x00\x04\x65\xAA\xBB\xCC\x00\x00\x00\x0D\x41\x9A\x24\x6C\x43\xBF\xFE\xA9\x96\x00\x00\x6F\xC0\x00\x00\x00\x0A\x41\x9E\x42\x78\x85\xFF\x00\x00\x83\x81\x00\x00\x00\x0A\x01\x9E\x61\x74\x42\xBF\x00\x00\xB6\x80\x00\x00\x00\x0A\x01\x9E\x63\x6A\x42\xBF\x00\x00\xB6\x81",
        &Track{
            .timescale = 12800,
            .dims = .{ .width = 320, .height = 240 },
            .codec = .{ .h264 = .{
                .sps = &Nalu{
                    .header = .{ .h264 = .{
                        .forbidden_zero_bit = 0,
                        .nal_ref_idc = 3,
                        .nal_unit = .{ .sps = .{
                            .profile_idc = .high,
                            .profile_compatibility = @bitCast(@as(u8, 0x00)),
                            .level_idc = 0x0d,
                            .seq_parameter_set_id = 0,
                            .chroma_format_idc = 1,
                            .bit_depth_luma_minus8 = 0,
                            .bit_depth_chroma_minus8 = 0,
                            .pic_width_in_mbs_minus1 = 19,
                            .pic_height_in_map_units_minus1 = 14,
                            .frame_mbs_only_flag = false,
                            .vui = null,
                        } },
                    } },
                    .data = "\x67\x64\x00\x0D\xAC\xD9\x41\x41\xFB\x01\x10\x00\x00\x03\x00\x10\x00\x00\x03\x03\x20\xF1\x42\x99\x60",
                    .slice = "\x67\x64\x00\x0D\xAC\xD9\x41\x41\xFB\x01\x10\x00\x00\x03\x00\x10\x00\x00\x03\x03\x20\xF1\x42\x99\x60",
                },
                .pps = &Nalu{
                    .header = .{ .h264 = .{
                        .forbidden_zero_bit = 0,
                        .nal_ref_idc = 3,
                        .nal_unit = .{ .pps = .{ .pic_parameter_set_id = 0, .seq_parameter_set_id = 0 } },
                    } },
                    .data = "\x68\xEB\xE3\xCB\x22\xC0",
                    .slice = "\x68\xEB\xE3\xCB\x22\xC0",
                },
            } },
            .samples = &.{
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 3, .nal_unit = .idr } },
                    .data = "\x65\xAA\xBB\xCC",
                    .slice = "\x65\xAA\xBB\xCC",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 2, .nal_unit = .slice } },
                    .data = "\x41\x9A\x24\x6C\x43\xBF\xFE\xA9\x96\x00\x00\x6F\xC0",
                    .slice = "\x41\x9A\x24\x6C\x43\xBF\xFE\xA9\x96\x00\x00\x6F\xC0",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 2, .nal_unit = .slice } },
                    .data = "\x41\x9E\x42\x78\x85\xFF\x00\x00\x83\x81",
                    .slice = "\x41\x9E\x42\x78\x85\xFF\x00\x00\x83\x81",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 0, .nal_unit = .slice } },
                    .data = "\x01\x9E\x61\x74\x42\xBF\x00\x00\xB6\x80",
                    .slice = "\x01\x9E\x61\x74\x42\xBF\x00\x00\xB6\x80",
                },
                Nalu{
                    .header = .{ .h264 = .{ .forbidden_zero_bit = 0, .nal_ref_idc = 0, .nal_unit = .slice } },
                    .data = "\x01\x9E\x63\x6A\x42\xBF\x00\x00\xB6\x81",
                    .slice = "\x01\x9E\x63\x6A\x42\xBF\x00\x00\xB6\x81",
                },
            },
            .sample_duration = 512,
        },
        .{},
    );
}

test "write_mp4 writes 1280x720 hevc main 8-bit 4:2:0 30000/1001 subset" {
    try expect_write_mp4(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x69\x73\x6F\x6D\x00\x00\x02\x00\x69\x73\x6F\x6D\x69\x73\x6F\x36\x68\x76\x63\x31\x6D\x70\x34\x31\x00\x00\x02\xD5\x6D\x6F\x6F\x76\x00\x00\x00\x78\x6D\x76\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x75\x30\x00\x00\x00\x00\x00\x00\x03\xE9\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x02\x55\x74\x72\x61\x6B\x00\x00\x00\x68\x74\x6B\x68\x64\x01\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\xE9\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x05\x00\x00\x00\x02\xD0\x00\x00\x00\x00\x01\xE5\x6D\x64\x69\x61\x00\x00\x00\x2C\x6D\x64\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x75\x30\x00\x00\x00\x00\x00\x00\x03\xE9\x55\xC4\x00\x00\x00\x00\x00\x2D\x68\x64\x6C\x72\x00\x00\x00\x00\x00\x00\x00\x00\x76\x69\x64\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x01\x84\x6D\x69\x6E\x66\x00\x00\x00\x14\x76\x6D\x68\x64\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x24\x64\x69\x6E\x66\x00\x00\x00\x1C\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0C\x75\x72\x6C\x20\x00\x00\x00\x01\x00\x00\x01\x44\x73\x74\x62\x6C\x00\x00\x00\xDC\x73\x74\x73\x64\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\xCC\x68\x76\x63\x31\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x02\xD0\x00\x48\x00\x00\x00\x48\x00\x00\x00\x00\x00\x00\x00\x01\x0C\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x18\xFF\xFF\x00\x00\x00\x76\x68\x76\x63\x43\x01\x01\x60\x00\x00\x00\x90\x00\x00\x00\x00\x00\x5D\xF0\x00\xFC\xFD\xF8\xF8\x00\x00\x0F\x03\x20\x00\x01\x00\x18\x40\x01\x0C\x01\xFF\xFF\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5D\x95\x98\x09\x21\x00\x01\x00\x29\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5D\xA0\x02\x80\x80\x2D\x16\x59\x59\xA4\x93\x2B\xC0\x5A\x70\x80\x00\x01\xF4\x80\x00\x3A\x98\x04\x22\x00\x01\x00\x07\x44\x01\xC1\x72\xB4\x62\x40\x00\x00\x00\x18\x73\x74\x74\x73\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x03\xE9\x00\x00\x00\x1C\x73\x74\x73\x63\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x18\x73\x74\x73\x7A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x08\x00\x00\x00\x14\x73\x74\x63\x6F\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x02\xFD\x00\x00\x00\x10\x6D\x64\x61\x74\x00\x00\x00\x04\x28\x01\xAA\xBB",
        &Track{
            .timescale = 30000,
            .dims = .{ .width = 1280, .height = 720 },
            .codec = .{ .h265 = .{
                .vps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .vps = .{ .video_parameter_set_id = 0 } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x40\x01\x0C\x01\xFF\xFF\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5D\x95\x98\x09",
                    .slice = "\x40\x01\x0C\x01\xFF\xFF\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5D\x95\x98\x09",
                },
                .sps = &Nalu{
                    .header = .{ .h265 = .{ .forbidden_zero_bit = 0, .nal_unit = .{ .sps = .{
                        .video_parameter_set_id = 0,
                        .max_sub_layers_minus1 = 0,
                        .temporal_id_nesting_flag = true,
                        .profile_space = 0,
                        .profile_tier_flag = false,
                        .profile_idc = .main,
                        .profile_compat_flags = 0x6000_0000,
                        .constraint_indicator_flags = .{ 0x90, 0x00, 0x00, 0x00, 0x00, 0x00 },
                        .level_idc = 0x5d,
                        .seq_parameter_set_id = 0,
                        .chroma_format_idc = 1,
                        .pic_width_in_luma_samples = 1280,
                        .pic_height_in_luma_samples = 720,
                        .bit_depth_luma_minus8 = 0,
                        .bit_depth_chroma_minus8 = 0,
                        .vui = null,
                    } }, .nuh_layer_id = 0, .nuh_temporal_id_plus1 = 1 } },
                    .data = "\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5D\xA0\x02\x80\x80\x2D\x16\x59\x59\xA4\x93\x2B\xC0\x5A\x70\x80\x00\x01\xF4\x80\x00\x3A\x98\x04",
                    .slice = "\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x5D\xA0\x02\x80\x80\x2D\x16\x59\x59\xA4\x93\x2B\xC0\x5A\x70\x80\x00\x01\xF4\x80\x00\x3A\x98\x04",
                },
                .pps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .pps = .{ .pps_pic_parameter_set_id = 0, .pps_seq_parameter_set_id = 0 } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x44\x01\xC1\x72\xB4\x62\x40",
                    .slice = "\x44\x01\xC1\x72\xB4\x62\x40",
                },
            } },
            .samples = &.{
                Nalu{
                    .header = .{ .h265 = .{ .forbidden_zero_bit = 0, .nal_unit = .idr, .nuh_layer_id = 0, .nuh_temporal_id_plus1 = 1 } },
                    .data = "\x28\x01\xAA\xBB",
                    .slice = "\x28\x01\xAA\xBB",
                },
            },
            .sample_duration = 1001,
        },
        .{},
    );
}

test "write_mp4 writes 1280x720 hevc rext 10-bit 4:2:0 single-sample" {
    try expect_write_mp4(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x69\x73\x6F\x6D\x00\x00\x02\x00\x69\x73\x6F\x6D\x69\x73\x6F\x36\x68\x76\x63\x31\x6D\x70\x34\x31\x00\x00\x02\xD8\x6D\x6F\x6F\x76\x00\x00\x00\x78\x6D\x76\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x02\x58\x74\x72\x61\x6B\x00\x00\x00\x68\x74\x6B\x68\x64\x01\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x05\x00\x00\x00\x02\xD0\x00\x00\x00\x00\x01\xE8\x6D\x64\x69\x61\x00\x00\x00\x2C\x6D\x64\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x55\xC4\x00\x00\x00\x00\x00\x2D\x68\x64\x6C\x72\x00\x00\x00\x00\x00\x00\x00\x00\x76\x69\x64\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x01\x87\x6D\x69\x6E\x66\x00\x00\x00\x14\x76\x6D\x68\x64\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x24\x64\x69\x6E\x66\x00\x00\x00\x1C\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0C\x75\x72\x6C\x20\x00\x00\x00\x01\x00\x00\x01\x47\x73\x74\x62\x6C\x00\x00\x00\xDF\x73\x74\x73\x64\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\xCF\x68\x76\x63\x31\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x02\xD0\x00\x48\x00\x00\x00\x48\x00\x00\x00\x00\x00\x00\x00\x01\x0C\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x18\xFF\xFF\x00\x00\x00\x79\x68\x76\x63\x43\x01\x04\x08\x00\x00\x00\x9D\xA8\x00\x00\x00\x00\x5D\xF0\x00\xFC\xFD\xFA\xFA\x00\x00\x0F\x03\x20\x00\x01\x00\x17\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9D\xA8\x00\x00\x03\x00\x00\x5D\xBA\x02\x40\x21\x00\x01\x00\x2D\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9D\xA8\x00\x00\x03\x00\x00\x5D\xA0\x02\x80\x80\x2D\x13\x65\xBA\x92\x4C\xAF\x01\x6A\x02\x1A\x02\x08\x00\x00\x03\x00\x08\x00\x00\x03\x00\x08\x40\x22\x00\x01\x00\x07\x44\x01\xC1\x72\xB0\x62\x40\x00\x00\x00\x18\x73\x74\x74\x73\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x40\x00\x00\x00\x00\x1C\x73\x74\x73\x63\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x18\x73\x74\x73\x7A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x08\x00\x00\x00\x14\x73\x74\x63\x6F\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x03\x00\x00\x00\x00\x10\x6D\x64\x61\x74\x00\x00\x00\x04\x28\x01\xAA\xBB",
        &Track{
            .timescale = 16384,
            .dims = .{ .width = 1280, .height = 720 },
            .codec = .{ .h265 = .{
                .vps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .vps = .{ .video_parameter_set_id = 0 } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9D\xA8\x00\x00\x03\x00\x00\x5D\xBA\x02\x40",
                    .slice = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9D\xA8\x00\x00\x03\x00\x00\x5D\xBA\x02\x40",
                },
                .sps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .sps = .{
                            .video_parameter_set_id = 0,
                            .max_sub_layers_minus1 = 0,
                            .temporal_id_nesting_flag = true,
                            .profile_space = 0,
                            .profile_tier_flag = false,
                            .profile_idc = .rext,
                            .profile_compat_flags = 0x0800_0000,
                            .constraint_indicator_flags = .{ 0x9d, 0xa8, 0x00, 0x00, 0x00, 0x00 },
                            .level_idc = 0x5d,
                            .seq_parameter_set_id = 0,
                            .chroma_format_idc = 1,
                            .pic_width_in_luma_samples = 1280,
                            .pic_height_in_luma_samples = 720,
                            .bit_depth_luma_minus8 = 2,
                            .bit_depth_chroma_minus8 = 2,
                            .vui = null,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9D\xA8\x00\x00\x03\x00\x00\x5D\xA0\x02\x80\x80\x2D\x13\x65\xBA\x92\x4C\xAF\x01\x6A\x02\x1A\x02\x08\x00\x00\x03\x00\x08\x00\x00\x03\x00\x08\x40",
                    .slice = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9D\xA8\x00\x00\x03\x00\x00\x5D\xA0\x02\x80\x80\x2D\x13\x65\xBA\x92\x4C\xAF\x01\x6A\x02\x1A\x02\x08\x00\x00\x03\x00\x08\x00\x00\x03\x00\x08\x40",
                },
                .pps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .pps = .{ .pps_pic_parameter_set_id = 0, .pps_seq_parameter_set_id = 0 } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x44\x01\xC1\x72\xB0\x62\x40",
                    .slice = "\x44\x01\xC1\x72\xB0\x62\x40",
                },
            } },
            .samples = &.{
                Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .idr,
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x28\x01\xAA\xBB",
                    .slice = "\x28\x01\xAA\xBB",
                },
            },
            .sample_duration = 16384,
        },
        .{},
    );
}

test "write_mp4 writes 1280x720 hevc rext 10-bit 4:2:2 single-sample" {
    try expect_write_mp4(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x69\x73\x6F\x6D\x00\x00\x02\x00\x69\x73\x6F\x6D\x69\x73\x6F\x36\x68\x76\x63\x31\x6D\x70\x34\x31\x00\x00\x02\xD8\x6D\x6F\x6F\x76\x00\x00\x00\x78\x6D\x76\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x02\x58\x74\x72\x61\x6B\x00\x00\x00\x68\x74\x6B\x68\x64\x01\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x05\x00\x00\x00\x02\xD0\x00\x00\x00\x00\x01\xE8\x6D\x64\x69\x61\x00\x00\x00\x2C\x6D\x64\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x55\xC4\x00\x00\x00\x00\x00\x2D\x68\x64\x6C\x72\x00\x00\x00\x00\x00\x00\x00\x00\x76\x69\x64\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x01\x87\x6D\x69\x6E\x66\x00\x00\x00\x14\x76\x6D\x68\x64\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x24\x64\x69\x6E\x66\x00\x00\x00\x1C\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0C\x75\x72\x6C\x20\x00\x00\x00\x01\x00\x00\x01\x47\x73\x74\x62\x6C\x00\x00\x00\xDF\x73\x74\x73\x64\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\xCF\x68\x76\x63\x31\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x02\xD0\x00\x48\x00\x00\x00\x48\x00\x00\x00\x00\x00\x00\x00\x01\x0C\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x18\xFF\xFF\x00\x00\x00\x79\x68\x76\x63\x43\x01\x04\x08\x00\x00\x00\x9D\x08\x00\x00\x00\x00\x5D\xF0\x00\xFC\xFE\xFA\xFA\x00\x00\x0F\x03\x20\x00\x01\x00\x17\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9D\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09\x21\x00\x01\x00\x2D\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9D\x08\x00\x00\x03\x00\x00\x5D\xB0\x02\x80\x80\x2D\x13\x65\x95\x9A\x49\x32\xBC\x05\xA8\x08\x68\x08\x20\x00\x00\x03\x00\x20\x00\x00\x03\x00\x21\x22\x00\x01\x00\x07\x44\x01\xC1\x72\xB4\x62\x40\x00\x00\x00\x18\x73\x74\x74\x73\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x40\x00\x00\x00\x00\x1C\x73\x74\x73\x63\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x18\x73\x74\x73\x7A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x08\x00\x00\x00\x14\x73\x74\x63\x6F\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x03\x00\x00\x00\x00\x10\x6D\x64\x61\x74\x00\x00\x00\x04\x28\x01\xAA\xBB",
        &Track{
            .timescale = 16384,
            .dims = .{ .width = 1280, .height = 720 },
            .codec = .{ .h265 = .{
                .vps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .vps = .{ .video_parameter_set_id = 0 } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9D\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                    .slice = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9D\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                },
                .sps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .sps = .{
                            .video_parameter_set_id = 0,
                            .max_sub_layers_minus1 = 0,
                            .temporal_id_nesting_flag = true,
                            .profile_space = 0,
                            .profile_tier_flag = false,
                            .profile_idc = .rext,
                            .profile_compat_flags = 0x0800_0000,
                            .constraint_indicator_flags = .{ 0x9d, 0x08, 0x00, 0x00, 0x00, 0x00 },
                            .level_idc = 0x5d,
                            .seq_parameter_set_id = 0,
                            .chroma_format_idc = 2,
                            .pic_width_in_luma_samples = 1280,
                            .pic_height_in_luma_samples = 720,
                            .bit_depth_luma_minus8 = 2,
                            .bit_depth_chroma_minus8 = 2,
                            .vui = null,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9D\x08\x00\x00\x03\x00\x00\x5D\xB0\x02\x80\x80\x2D\x13\x65\x95\x9A\x49\x32\xBC\x05\xA8\x08\x68\x08\x20\x00\x00\x03\x00\x20\x00\x00\x03\x00\x21",
                    .slice = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9D\x08\x00\x00\x03\x00\x00\x5D\xB0\x02\x80\x80\x2D\x13\x65\x95\x9A\x49\x32\xBC\x05\xA8\x08\x68\x08\x20\x00\x00\x03\x00\x20\x00\x00\x03\x00\x21",
                },
                .pps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .pps = .{ .pps_pic_parameter_set_id = 0, .pps_seq_parameter_set_id = 0 } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x44\x01\xC1\x72\xB4\x62\x40",
                    .slice = "\x44\x01\xC1\x72\xB4\x62\x40",
                },
            } },
            .samples = &.{
                Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .idr,
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x28\x01\xAA\xBB",
                    .slice = "\x28\x01\xAA\xBB",
                },
            },
            .sample_duration = 16384,
        },
        .{},
    );
}

test "write_mp4 writes 1280x720 hevc rext 10-bit 4:4:4 single-sample" {
    try expect_write_mp4(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x69\x73\x6F\x6D\x00\x00\x02\x00\x69\x73\x6F\x6D\x69\x73\x6F\x36\x68\x76\x63\x31\x6D\x70\x34\x31\x00\x00\x02\xDA\x6D\x6F\x6F\x76\x00\x00\x00\x78\x6D\x76\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x02\x5A\x74\x72\x61\x6B\x00\x00\x00\x68\x74\x6B\x68\x64\x01\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x05\x00\x00\x00\x02\xD0\x00\x00\x00\x00\x01\xEA\x6D\x64\x69\x61\x00\x00\x00\x2C\x6D\x64\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x55\xC4\x00\x00\x00\x00\x00\x2D\x68\x64\x6C\x72\x00\x00\x00\x00\x00\x00\x00\x00\x76\x69\x64\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x01\x89\x6D\x69\x6E\x66\x00\x00\x00\x14\x76\x6D\x68\x64\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x24\x64\x69\x6E\x66\x00\x00\x00\x1C\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0C\x75\x72\x6C\x20\x00\x00\x00\x01\x00\x00\x01\x49\x73\x74\x62\x6C\x00\x00\x00\xE1\x73\x74\x73\x64\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\xD1\x68\x76\x63\x31\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x02\xD0\x00\x48\x00\x00\x00\x48\x00\x00\x00\x00\x00\x00\x00\x01\x0C\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x18\xFF\xFF\x00\x00\x00\x7B\x68\x76\x63\x43\x01\x04\x08\x00\x00\x00\x9C\x08\x00\x00\x00\x00\x5D\xF0\x00\xFC\xFF\xFA\xFA\x00\x00\x0F\x03\x20\x00\x01\x00\x17\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9C\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09\x21\x00\x01\x00\x2E\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9C\x08\x00\x00\x03\x00\x00\x5D\x90\x00\x50\x10\x05\xA2\x6C\xB2\xB3\x49\x26\x57\x80\xB5\x01\x0D\x01\x04\x00\x00\x03\x00\x04\x00\x00\x03\x00\x04\x20\x22\x00\x01\x00\x08\x44\x01\xC1\x72\x86\x0C\x46\x24\x00\x00\x00\x18\x73\x74\x74\x73\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x40\x00\x00\x00\x00\x1C\x73\x74\x73\x63\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x18\x73\x74\x73\x7A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x08\x00\x00\x00\x14\x73\x74\x63\x6F\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x03\x02\x00\x00\x00\x10\x6D\x64\x61\x74\x00\x00\x00\x04\x28\x01\xAA\xBB",
        &Track{
            .timescale = 16384,
            .dims = .{ .width = 1280, .height = 720 },
            .codec = .{ .h265 = .{
                .vps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .vps = .{ .video_parameter_set_id = 0 } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9C\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                    .slice = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9C\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                },
                .sps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .sps = .{
                            .video_parameter_set_id = 0,
                            .max_sub_layers_minus1 = 0,
                            .temporal_id_nesting_flag = true,
                            .profile_space = 0,
                            .profile_tier_flag = false,
                            .profile_idc = .rext,
                            .profile_compat_flags = 0x0800_0000,
                            .constraint_indicator_flags = .{ 0x9c, 0x08, 0x00, 0x00, 0x00, 0x00 },
                            .level_idc = 0x5d,
                            .seq_parameter_set_id = 0,
                            .chroma_format_idc = 3,
                            .pic_width_in_luma_samples = 1280,
                            .pic_height_in_luma_samples = 720,
                            .bit_depth_luma_minus8 = 2,
                            .bit_depth_chroma_minus8 = 2,
                            .vui = null,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9C\x08\x00\x00\x03\x00\x00\x5D\x90\x00\x50\x10\x05\xA2\x6C\xB2\xB3\x49\x26\x57\x80\xB5\x01\x0D\x01\x04\x00\x00\x03\x00\x04\x00\x00\x03\x00\x04\x20",
                    .slice = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9C\x08\x00\x00\x03\x00\x00\x5D\x90\x00\x50\x10\x05\xA2\x6C\xB2\xB3\x49\x26\x57\x80\xB5\x01\x0D\x01\x04\x00\x00\x03\x00\x04\x00\x00\x03\x00\x04\x20",
                },
                .pps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .pps = .{ .pps_pic_parameter_set_id = 0, .pps_seq_parameter_set_id = 0 } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x44\x01\xC1\x72\x86\x0C\x46\x24",
                    .slice = "\x44\x01\xC1\x72\x86\x0C\x46\x24",
                },
            } },
            .samples = &.{
                Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .idr,
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x28\x01\xAA\xBB",
                    .slice = "\x28\x01\xAA\xBB",
                },
            },
            .sample_duration = 16384,
        },
        .{},
    );
}

test "write_mp4 writes 1280x720 hevc rext 12-bit 4:2:0 single-sample" {
    try expect_write_mp4(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x69\x73\x6F\x6D\x00\x00\x02\x00\x69\x73\x6F\x6D\x69\x73\x6F\x36\x68\x76\x63\x31\x6D\x70\x34\x31\x00\x00\x02\xD9\x6D\x6F\x6F\x76\x00\x00\x00\x78\x6D\x76\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x02\x59\x74\x72\x61\x6B\x00\x00\x00\x68\x74\x6B\x68\x64\x01\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x05\x00\x00\x00\x02\xD0\x00\x00\x00\x00\x01\xE9\x6D\x64\x69\x61\x00\x00\x00\x2C\x6D\x64\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x55\xC4\x00\x00\x00\x00\x00\x2D\x68\x64\x6C\x72\x00\x00\x00\x00\x00\x00\x00\x00\x76\x69\x64\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x01\x88\x6D\x69\x6E\x66\x00\x00\x00\x14\x76\x6D\x68\x64\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x24\x64\x69\x6E\x66\x00\x00\x00\x1C\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0C\x75\x72\x6C\x20\x00\x00\x00\x01\x00\x00\x01\x48\x73\x74\x62\x6C\x00\x00\x00\xE0\x73\x74\x73\x64\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\xD0\x68\x76\x63\x31\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x02\xD0\x00\x48\x00\x00\x00\x48\x00\x00\x00\x00\x00\x00\x00\x01\x0C\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x18\xFF\xFF\x00\x00\x00\x7A\x68\x76\x63\x43\x01\x04\x08\x00\x00\x00\x99\x88\x00\x00\x00\x00\x5D\xF0\x00\xFC\xFD\xFC\xFC\x00\x00\x0F\x03\x20\x00\x01\x00\x17\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x99\x88\x00\x00\x03\x00\x00\x5D\x95\x98\x09\x21\x00\x01\x00\x2E\x42\x01\x01\x04\x08\x00\x00\x03\x00\x99\x88\x00\x00\x03\x00\x00\x5D\xA0\x02\x80\x80\x2D\x11\x4A\x59\x59\xA4\x93\x2B\xC0\x5A\x80\x86\x80\x82\x00\x00\x03\x00\x02\x00\x00\x03\x00\x02\x10\x22\x00\x01\x00\x07\x44\x01\xC1\x72\xB4\x62\x40\x00\x00\x00\x18\x73\x74\x74\x73\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x40\x00\x00\x00\x00\x1C\x73\x74\x73\x63\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x18\x73\x74\x73\x7A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x08\x00\x00\x00\x14\x73\x74\x63\x6F\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x03\x01\x00\x00\x00\x10\x6D\x64\x61\x74\x00\x00\x00\x04\x28\x01\xAA\xBB",
        &Track{
            .timescale = 16384,
            .dims = .{ .width = 1280, .height = 720 },
            .codec = .{ .h265 = .{
                .vps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .vps = .{
                            .video_parameter_set_id = 0,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x99\x88\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                    .slice = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x99\x88\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                },
                .sps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .sps = .{
                            .video_parameter_set_id = 0,
                            .max_sub_layers_minus1 = 0,
                            .temporal_id_nesting_flag = true,
                            .profile_space = 0,
                            .profile_tier_flag = false,
                            .profile_idc = .rext,
                            .profile_compat_flags = 0x0800_0000,
                            .constraint_indicator_flags = .{ 0x99, 0x88, 0x00, 0x00, 0x00, 0x00 },
                            .level_idc = 0x5d,
                            .seq_parameter_set_id = 0,
                            .chroma_format_idc = 1,
                            .pic_width_in_luma_samples = 1280,
                            .pic_height_in_luma_samples = 720,
                            .bit_depth_luma_minus8 = 4,
                            .bit_depth_chroma_minus8 = 4,
                            .vui = null,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x99\x88\x00\x00\x03\x00\x00\x5D\xA0\x02\x80\x80\x2D\x11\x4A\x59\x59\xA4\x93\x2B\xC0\x5A\x80\x86\x80\x82\x00\x00\x03\x00\x02\x00\x00\x03\x00\x02\x10",
                    .slice = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x99\x88\x00\x00\x03\x00\x00\x5D\xA0\x02\x80\x80\x2D\x11\x4A\x59\x59\xA4\x93\x2B\xC0\x5A\x80\x86\x80\x82\x00\x00\x03\x00\x02\x00\x00\x03\x00\x02\x10",
                },
                .pps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .pps = .{
                            .pps_pic_parameter_set_id = 0,
                            .pps_seq_parameter_set_id = 0,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x44\x01\xC1\x72\xB4\x62\x40",
                    .slice = "\x44\x01\xC1\x72\xB4\x62\x40",
                },
            } },
            .samples = &.{
                Nalu{
                    .header = .{ .h265 = .{ .forbidden_zero_bit = 0, .nal_unit = .idr, .nuh_layer_id = 0, .nuh_temporal_id_plus1 = 1 } },
                    .data = "\x28\x01\xAA\xBB",
                    .slice = "\x28\x01\xAA\xBB",
                },
            },
            .sample_duration = 16384,
        },
        .{},
    );
}

test "write_mp4 writes 1280x720 hevc rext 12-bit 4:2:2 single-sample" {
    try expect_write_mp4(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x69\x73\x6F\x6D\x00\x00\x02\x00\x69\x73\x6F\x6D\x69\x73\x6F\x36\x68\x76\x63\x31\x6D\x70\x34\x31\x00\x00\x02\xD9\x6D\x6F\x6F\x76\x00\x00\x00\x78\x6D\x76\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x02\x59\x74\x72\x61\x6B\x00\x00\x00\x68\x74\x6B\x68\x64\x01\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x05\x00\x00\x00\x02\xD0\x00\x00\x00\x00\x01\xE9\x6D\x64\x69\x61\x00\x00\x00\x2C\x6D\x64\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x55\xC4\x00\x00\x00\x00\x00\x2D\x68\x64\x6C\x72\x00\x00\x00\x00\x00\x00\x00\x00\x76\x69\x64\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x01\x88\x6D\x69\x6E\x66\x00\x00\x00\x14\x76\x6D\x68\x64\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x24\x64\x69\x6E\x66\x00\x00\x00\x1C\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0C\x75\x72\x6C\x20\x00\x00\x00\x01\x00\x00\x01\x48\x73\x74\x62\x6C\x00\x00\x00\xE0\x73\x74\x73\x64\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\xD0\x68\x76\x63\x31\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x02\xD0\x00\x48\x00\x00\x00\x48\x00\x00\x00\x00\x00\x00\x00\x01\x0C\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x18\xFF\xFF\x00\x00\x00\x7A\x68\x76\x63\x43\x01\x04\x08\x00\x00\x00\x99\x08\x00\x00\x00\x00\x5D\xF0\x00\xFC\xFE\xFC\xFC\x00\x00\x0F\x03\x20\x00\x01\x00\x17\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x99\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09\x21\x00\x01\x00\x2E\x42\x01\x01\x04\x08\x00\x00\x03\x00\x99\x08\x00\x00\x03\x00\x00\x5D\xB0\x02\x80\x80\x2D\x11\x4A\x59\x59\xA4\x93\x2B\xC0\x5A\x80\x86\x80\x82\x00\x00\x03\x00\x02\x00\x00\x03\x00\x02\x10\x22\x00\x01\x00\x07\x44\x01\xC1\x72\xB4\x62\x40\x00\x00\x00\x18\x73\x74\x74\x73\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x40\x00\x00\x00\x00\x1C\x73\x74\x73\x63\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x18\x73\x74\x73\x7A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x08\x00\x00\x00\x14\x73\x74\x63\x6F\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x03\x01\x00\x00\x00\x10\x6D\x64\x61\x74\x00\x00\x00\x04\x28\x01\xAA\xBB",
        &Track{
            .timescale = 16384,
            .dims = .{ .width = 1280, .height = 720 },
            .codec = .{ .h265 = .{
                .vps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .vps = .{
                            .video_parameter_set_id = 0,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x99\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                    .slice = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x99\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                },
                .sps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .sps = .{
                            .video_parameter_set_id = 0,
                            .max_sub_layers_minus1 = 0,
                            .temporal_id_nesting_flag = true,
                            .profile_space = 0,
                            .profile_tier_flag = false,
                            .profile_idc = .rext,
                            .profile_compat_flags = 0x0800_0000,
                            .constraint_indicator_flags = .{ 0x99, 0x08, 0x00, 0x00, 0x00, 0x00 },
                            .level_idc = 0x5d,
                            .seq_parameter_set_id = 0,
                            .chroma_format_idc = 2,
                            .pic_width_in_luma_samples = 1280,
                            .pic_height_in_luma_samples = 720,
                            .bit_depth_luma_minus8 = 4,
                            .bit_depth_chroma_minus8 = 4,
                            .vui = null,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x99\x08\x00\x00\x03\x00\x00\x5D\xB0\x02\x80\x80\x2D\x11\x4A\x59\x59\xA4\x93\x2B\xC0\x5A\x80\x86\x80\x82\x00\x00\x03\x00\x02\x00\x00\x03\x00\x02\x10",
                    .slice = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x99\x08\x00\x00\x03\x00\x00\x5D\xB0\x02\x80\x80\x2D\x11\x4A\x59\x59\xA4\x93\x2B\xC0\x5A\x80\x86\x80\x82\x00\x00\x03\x00\x02\x00\x00\x03\x00\x02\x10",
                },
                .pps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .pps = .{
                            .pps_pic_parameter_set_id = 0,
                            .pps_seq_parameter_set_id = 0,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x44\x01\xC1\x72\xB4\x62\x40",
                    .slice = "\x44\x01\xC1\x72\xB4\x62\x40",
                },
            } },
            .samples = &.{
                Nalu{
                    .header = .{ .h265 = .{ .forbidden_zero_bit = 0, .nal_unit = .idr, .nuh_layer_id = 0, .nuh_temporal_id_plus1 = 1 } },
                    .data = "\x28\x01\xAA\xBB",
                    .slice = "\x28\x01\xAA\xBB",
                },
            },
            .sample_duration = 16384,
        },
        .{},
    );
}

test "write_mp4 writes 1280x720 hevc rext 12-bit 4:4:4 single-sample" {
    try expect_write_mp4(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x69\x73\x6F\x6D\x00\x00\x02\x00\x69\x73\x6F\x6D\x69\x73\x6F\x36\x68\x76\x63\x31\x6D\x70\x34\x31\x00\x00\x02\xDA\x6D\x6F\x6F\x76\x00\x00\x00\x78\x6D\x76\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x02\x5A\x74\x72\x61\x6B\x00\x00\x00\x68\x74\x6B\x68\x64\x01\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x05\x00\x00\x00\x02\xD0\x00\x00\x00\x00\x01\xEA\x6D\x64\x69\x61\x00\x00\x00\x2C\x6D\x64\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x55\xC4\x00\x00\x00\x00\x00\x2D\x68\x64\x6C\x72\x00\x00\x00\x00\x00\x00\x00\x00\x76\x69\x64\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x01\x89\x6D\x69\x6E\x66\x00\x00\x00\x14\x76\x6D\x68\x64\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x24\x64\x69\x6E\x66\x00\x00\x00\x1C\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0C\x75\x72\x6C\x20\x00\x00\x00\x01\x00\x00\x01\x49\x73\x74\x62\x6C\x00\x00\x00\xE1\x73\x74\x73\x64\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\xD1\x68\x76\x63\x31\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x02\xD0\x00\x48\x00\x00\x00\x48\x00\x00\x00\x00\x00\x00\x00\x01\x0C\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x18\xFF\xFF\x00\x00\x00\x7B\x68\x76\x63\x43\x01\x04\x08\x00\x00\x00\x98\x08\x00\x00\x00\x00\x5D\xF0\x00\xFC\xFF\xFC\xFC\x00\x00\x0F\x03\x20\x00\x01\x00\x17\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x98\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09\x21\x00\x01\x00\x2E\x42\x01\x01\x04\x08\x00\x00\x03\x00\x98\x08\x00\x00\x03\x00\x00\x5D\x90\x00\x50\x10\x05\xA2\x29\x4B\x2B\x34\x92\x65\x78\x0B\x50\x10\xD0\x10\x40\x00\x00\x03\x00\x40\x00\x00\x03\x00\x42\x22\x00\x01\x00\x08\x44\x01\xC1\x72\x86\x0C\x46\x24\x00\x00\x00\x18\x73\x74\x74\x73\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x40\x00\x00\x00\x00\x1C\x73\x74\x73\x63\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x18\x73\x74\x73\x7A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x08\x00\x00\x00\x14\x73\x74\x63\x6F\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x03\x02\x00\x00\x00\x10\x6D\x64\x61\x74\x00\x00\x00\x04\x28\x01\xAA\xBB",
        &Track{
            .timescale = 16384,
            .dims = .{ .width = 1280, .height = 720 },
            .codec = .{ .h265 = .{
                .vps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .vps = .{
                            .video_parameter_set_id = 0,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x98\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                    .slice = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x98\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                },
                .sps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .sps = .{
                            .video_parameter_set_id = 0,
                            .max_sub_layers_minus1 = 0,
                            .temporal_id_nesting_flag = true,
                            .profile_space = 0,
                            .profile_tier_flag = false,
                            .profile_idc = .rext,
                            .profile_compat_flags = 0x0800_0000,
                            .constraint_indicator_flags = .{ 0x98, 0x08, 0x00, 0x00, 0x00, 0x00 },
                            .level_idc = 0x5d,
                            .seq_parameter_set_id = 0,
                            .chroma_format_idc = 3,
                            .pic_width_in_luma_samples = 1280,
                            .pic_height_in_luma_samples = 720,
                            .bit_depth_luma_minus8 = 4,
                            .bit_depth_chroma_minus8 = 4,
                            .vui = null,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x98\x08\x00\x00\x03\x00\x00\x5D\x90\x00\x50\x10\x05\xA2\x29\x4B\x2B\x34\x92\x65\x78\x0B\x50\x10\xD0\x10\x40\x00\x00\x03\x00\x40\x00\x00\x03\x00\x42",
                    .slice = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x98\x08\x00\x00\x03\x00\x00\x5D\x90\x00\x50\x10\x05\xA2\x29\x4B\x2B\x34\x92\x65\x78\x0B\x50\x10\xD0\x10\x40\x00\x00\x03\x00\x40\x00\x00\x03\x00\x42",
                },
                .pps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .pps = .{
                            .pps_pic_parameter_set_id = 0,
                            .pps_seq_parameter_set_id = 0,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x44\x01\xC1\x72\x86\x0C\x46\x24",
                    .slice = "\x44\x01\xC1\x72\x86\x0C\x46\x24",
                },
            } },
            .samples = &.{
                Nalu{
                    .header = .{ .h265 = .{ .forbidden_zero_bit = 0, .nal_unit = .idr, .nuh_layer_id = 0, .nuh_temporal_id_plus1 = 1 } },
                    .data = "\x28\x01\xAA\xBB",
                    .slice = "\x28\x01\xAA\xBB",
                },
            },
            .sample_duration = 16384,
        },
        .{},
    );
}

test "write_mp4 writes 1280x720 hevc rext 8-bit 4:4:4 single-sample" {
    try expect_write_mp4(
        "\x00\x00\x00\x20\x66\x74\x79\x70\x69\x73\x6F\x6D\x00\x00\x02\x00\x69\x73\x6F\x6D\x69\x73\x6F\x36\x68\x76\x63\x31\x6D\x70\x34\x31\x00\x00\x02\xD9\x6D\x6F\x6F\x76\x00\x00\x00\x78\x6D\x76\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x02\x59\x74\x72\x61\x6B\x00\x00\x00\x68\x74\x6B\x68\x64\x01\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x05\x00\x00\x00\x02\xD0\x00\x00\x00\x00\x01\xE9\x6D\x64\x69\x61\x00\x00\x00\x2C\x6D\x64\x68\x64\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x40\x00\x55\xC4\x00\x00\x00\x00\x00\x2D\x68\x64\x6C\x72\x00\x00\x00\x00\x00\x00\x00\x00\x76\x69\x64\x65\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x01\x88\x6D\x69\x6E\x66\x00\x00\x00\x14\x76\x6D\x68\x64\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x24\x64\x69\x6E\x66\x00\x00\x00\x1C\x64\x72\x65\x66\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0C\x75\x72\x6C\x20\x00\x00\x00\x01\x00\x00\x01\x48\x73\x74\x62\x6C\x00\x00\x00\xE0\x73\x74\x73\x64\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\xD0\x68\x76\x63\x31\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x02\xD0\x00\x48\x00\x00\x00\x48\x00\x00\x00\x00\x00\x00\x00\x01\x0C\x56\x69\x64\x65\x6F\x48\x61\x6E\x64\x6C\x65\x72\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x18\xFF\xFF\x00\x00\x00\x7A\x68\x76\x63\x43\x01\x04\x08\x00\x00\x00\x9E\x08\x00\x00\x00\x00\x5D\xF0\x00\xFC\xFF\xF8\xF8\x00\x00\x0F\x03\x20\x00\x01\x00\x17\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9E\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09\x21\x00\x01\x00\x2D\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9E\x08\x00\x00\x03\x00\x00\x5D\x90\x00\x50\x10\x05\xA2\xCB\x2B\x34\x92\x65\x78\x0B\x50\x10\xD0\x10\x40\x00\x00\x03\x00\x40\x00\x00\x03\x00\x42\x22\x00\x01\x00\x08\x44\x01\xC1\x72\x86\x0C\x46\x24\x00\x00\x00\x18\x73\x74\x74\x73\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x40\x00\x00\x00\x00\x1C\x73\x74\x73\x63\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x18\x73\x74\x73\x7A\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x08\x00\x00\x00\x14\x73\x74\x63\x6F\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x03\x01\x00\x00\x00\x10\x6D\x64\x61\x74\x00\x00\x00\x04\x28\x01\xAA\xBB",
        &Track{
            .timescale = 16384,
            .dims = .{ .width = 1280, .height = 720 },
            .codec = .{ .h265 = .{
                .vps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .vps = .{
                            .video_parameter_set_id = 0,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9E\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                    .slice = "\x40\x01\x0C\x01\xFF\xFF\x04\x08\x00\x00\x03\x00\x9E\x08\x00\x00\x03\x00\x00\x5D\x95\x98\x09",
                },
                .sps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .sps = .{
                            .video_parameter_set_id = 0,
                            .max_sub_layers_minus1 = 0,
                            .temporal_id_nesting_flag = true,
                            .profile_space = 0,
                            .profile_tier_flag = false,
                            .profile_idc = .rext,
                            .profile_compat_flags = 0x0800_0000,
                            .constraint_indicator_flags = .{ 0x9e, 0x08, 0x00, 0x00, 0x00, 0x00 },
                            .level_idc = 0x5d,
                            .seq_parameter_set_id = 0,
                            .chroma_format_idc = 3,
                            .pic_width_in_luma_samples = 1280,
                            .pic_height_in_luma_samples = 720,
                            .bit_depth_luma_minus8 = 0,
                            .bit_depth_chroma_minus8 = 0,
                            .vui = null,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9E\x08\x00\x00\x03\x00\x00\x5D\x90\x00\x50\x10\x05\xA2\xCB\x2B\x34\x92\x65\x78\x0B\x50\x10\xD0\x10\x40\x00\x00\x03\x00\x40\x00\x00\x03\x00\x42",
                    .slice = "\x42\x01\x01\x04\x08\x00\x00\x03\x00\x9E\x08\x00\x00\x03\x00\x00\x5D\x90\x00\x50\x10\x05\xA2\xCB\x2B\x34\x92\x65\x78\x0B\x50\x10\xD0\x10\x40\x00\x00\x03\x00\x40\x00\x00\x03\x00\x42",
                },
                .pps = &Nalu{
                    .header = .{ .h265 = .{
                        .forbidden_zero_bit = 0,
                        .nal_unit = .{ .pps = .{
                            .pps_pic_parameter_set_id = 0,
                            .pps_seq_parameter_set_id = 0,
                        } },
                        .nuh_layer_id = 0,
                        .nuh_temporal_id_plus1 = 1,
                    } },
                    .data = "\x44\x01\xC1\x72\x86\x0C\x46\x24",
                    .slice = "\x44\x01\xC1\x72\x86\x0C\x46\x24",
                },
            } },
            .samples = &.{
                Nalu{
                    .header = .{ .h265 = .{ .forbidden_zero_bit = 0, .nal_unit = .idr, .nuh_layer_id = 0, .nuh_temporal_id_plus1 = 1 } },
                    .data = "\x28\x01\xAA\xBB",
                    .slice = "\x28\x01\xAA\xBB",
                },
            },
            .sample_duration = 16384,
        },
        .{},
    );
}

fn expect_write_mp4(expected: []const u8, track: *const Track, options: Options) !void {
    var allocating_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating_writer.deinit();
    try write_mp4(track, &allocating_writer.writer, options);
    try std.testing.expectEqualSlices(u8, expected, allocating_writer.written());
}

fn expect_write(expected: []const u8, box: anytype) !void {
    var allocating_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating_writer.deinit();
    const writer = Writer{ .writer = &allocating_writer.writer };
    try box.write(writer);
    try std.testing.expectEqualSlices(u8, expected, allocating_writer.written());
}
