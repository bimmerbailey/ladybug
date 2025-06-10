const std = @import("std");
const net = std.net;
const mem = std.mem;
const testing = std.testing;

pub const FrameType = enum(u8) {
    DATA = 0x0,
    HEADERS = 0x1,
    PRIORITY = 0x2,
    RST_STREAM = 0x3,
    SETTINGS = 0x4,
    PUSH_PROMISE = 0x5,
    PING = 0x6,
    GOAWAY = 0x7,
    WINDOW_UPDATE = 0x8,
    CONTINUATION = 0x9,
};

pub const FrameFlags = struct {
    pub const END_STREAM: u8 = 0x1;
    pub const ACK: u8 = 0x1;
    pub const END_HEADERS: u8 = 0x4;
    pub const PADDED: u8 = 0x8;
    pub const PRIORITY: u8 = 0x20;
};

pub const ErrorCode = enum(u32) {
    NO_ERROR = 0x0,
    PROTOCOL_ERROR = 0x1,
    INTERNAL_ERROR = 0x2,
    FLOW_CONTROL_ERROR = 0x3,
    SETTINGS_TIMEOUT = 0x4,
    STREAM_CLOSED = 0x5,
    FRAME_SIZE_ERROR = 0x6,
    REFUSED_STREAM = 0x7,
    CANCEL = 0x8,
    COMPRESSION_ERROR = 0x9,
    CONNECT_ERROR = 0xa,
    ENHANCE_YOUR_CALM = 0xb,
    INADEQUATE_SECURITY = 0xc,
    HTTP_1_1_REQUIRED = 0xd,
};

pub const SettingsId = enum(u16) {
    HEADER_TABLE_SIZE = 0x1,
    ENABLE_PUSH = 0x2,
    MAX_CONCURRENT_STREAMS = 0x3,
    INITIAL_WINDOW_SIZE = 0x4,
    MAX_FRAME_SIZE = 0x5,
    MAX_HEADER_LIST_SIZE = 0x6,
};

pub const FrameHeader = struct {
    length: u24,
    frame_type: FrameType,
    flags: u8,
    stream_id: u31,

    pub const SIZE = 9;

    pub fn parse(data: []const u8) !FrameHeader {
        if (data.len < SIZE) return error.InsufficientData;

        const length = (@as(u24, data[0]) << 16) | (@as(u24, data[1]) << 8) | @as(u24, data[2]);
        const frame_type = @as(FrameType, @enumFromInt(data[3]));
        const flags = data[4];
        const stream_id = (@as(u32, data[5]) << 24) | (@as(u32, data[6]) << 16) | (@as(u32, data[7]) << 8) | @as(u32, data[8]);

        // Clear reserved bit
        const clean_stream_id = stream_id & 0x7FFFFFFF;

        return FrameHeader{
            .length = length,
            .frame_type = frame_type,
            .flags = flags,
            .stream_id = @intCast(clean_stream_id),
        };
    }

    pub fn serialize(self: FrameHeader, buffer: []u8) !void {
        if (buffer.len < SIZE) return error.InsufficientSpace;

        buffer[0] = @intCast((self.length >> 16) & 0xFF);
        buffer[1] = @intCast((self.length >> 8) & 0xFF);
        buffer[2] = @intCast(self.length & 0xFF);
        buffer[3] = @intFromEnum(self.frame_type);
        buffer[4] = self.flags;
        buffer[5] = @intCast((self.stream_id >> 24) & 0xFF);
        buffer[6] = @intCast((self.stream_id >> 16) & 0xFF);
        buffer[7] = @intCast((self.stream_id >> 8) & 0xFF);
        buffer[8] = @intCast(self.stream_id & 0xFF);
    }
};

pub const Frame = struct {
    header: FrameHeader,
    payload: []const u8,

    pub fn parse(allocator: mem.Allocator, data: []const u8) !Frame {
        const header = try FrameHeader.parse(data);

        if (data.len < FrameHeader.SIZE + header.length) {
            return error.InsufficientData;
        }

        const payload = data[FrameHeader.SIZE..][0..header.length];
        const owned_payload = try allocator.dupe(u8, payload);

        return Frame{
            .header = header,
            .payload = owned_payload,
        };
    }

    pub fn deinit(self: Frame, allocator: mem.Allocator) void {
        allocator.free(self.payload);
    }

    pub fn serialize(self: Frame, allocator: mem.Allocator) ![]u8 {
        const total_size = FrameHeader.SIZE + self.payload.len;
        var buffer = try allocator.alloc(u8, total_size);

        try self.header.serialize(buffer[0..FrameHeader.SIZE]);
        @memcpy(buffer[FrameHeader.SIZE..], self.payload);

        return buffer;
    }
};

pub const SettingsFrame = struct {
    settings: std.ArrayList(Setting),

    const Setting = struct {
        id: SettingsId,
        value: u32,
    };

    pub fn init(allocator: mem.Allocator) SettingsFrame {
        return SettingsFrame{
            .settings = std.ArrayList(Setting).init(allocator),
        };
    }

    pub fn deinit(self: *SettingsFrame) void {
        self.settings.deinit();
    }

    pub fn addSetting(self: *SettingsFrame, id: SettingsId, value: u32) !void {
        try self.settings.append(Setting{ .id = id, .value = value });
    }

    pub fn parse(allocator: mem.Allocator, payload: []const u8) !SettingsFrame {
        if (payload.len % 6 != 0) return error.InvalidSettingsFrame;

        var settings_frame = SettingsFrame.init(allocator);

        var i: usize = 0;
        while (i < payload.len) : (i += 6) {
            const id_raw = (@as(u16, payload[i]) << 8) | @as(u16, payload[i + 1]);
            const id = @as(SettingsId, @enumFromInt(id_raw));
            const value = (@as(u32, payload[i + 2]) << 24) |
                (@as(u32, payload[i + 3]) << 16) |
                (@as(u32, payload[i + 4]) << 8) |
                @as(u32, payload[i + 5]);

            try settings_frame.addSetting(id, value);
        }

        return settings_frame;
    }

    pub fn serialize(self: SettingsFrame, allocator: mem.Allocator) ![]u8 {
        const payload_size = self.settings.items.len * 6;
        var payload = try allocator.alloc(u8, payload_size);

        for (self.settings.items, 0..) |setting, i| {
            const offset = i * 6;
            const id_val = @intFromEnum(setting.id);

            payload[offset] = @intCast((id_val >> 8) & 0xFF);
            payload[offset + 1] = @intCast(id_val & 0xFF);
            payload[offset + 2] = @intCast((setting.value >> 24) & 0xFF);
            payload[offset + 3] = @intCast((setting.value >> 16) & 0xFF);
            payload[offset + 4] = @intCast((setting.value >> 8) & 0xFF);
            payload[offset + 5] = @intCast(setting.value & 0xFF);
        }

        return payload;
    }

    pub fn toFrame(self: SettingsFrame, allocator: mem.Allocator, flags: u8) !Frame {
        const payload = try self.serialize(allocator);

        return Frame{
            .header = FrameHeader{
                .length = @intCast(payload.len),
                .frame_type = FrameType.SETTINGS,
                .flags = flags,
                .stream_id = 0,
            },
            .payload = payload,
        };
    }
};

pub const DataFrame = struct {
    data: []const u8,
    pad_length: ?u8 = null,

    pub fn parse(allocator: mem.Allocator, frame: Frame) !DataFrame {
        if (frame.header.frame_type != FrameType.DATA) {
            return error.InvalidFrameType;
        }

        var payload = frame.payload;
        var pad_length: ?u8 = null;

        if (frame.header.flags & FrameFlags.PADDED != 0) {
            if (payload.len == 0) return error.InvalidPadding;
            pad_length = payload[0];
            payload = payload[1..];

            if (pad_length.? >= payload.len) return error.InvalidPadding;
            payload = payload[0 .. payload.len - pad_length.?];
        }

        const owned_data = try allocator.dupe(u8, payload);

        return DataFrame{
            .data = owned_data,
            .pad_length = pad_length,
        };
    }

    pub fn deinit(self: DataFrame, allocator: mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn toFrame(self: DataFrame, allocator: mem.Allocator, stream_id: u31, flags: u8) !Frame {
        var payload_size = self.data.len;
        var frame_flags = flags;

        if (self.pad_length) |pad_len| {
            payload_size += 1 + pad_len;
            frame_flags |= FrameFlags.PADDED;
        }

        var payload = try allocator.alloc(u8, payload_size);
        var offset: usize = 0;

        if (self.pad_length) |pad_len| {
            payload[0] = pad_len;
            offset = 1;
            @memcpy(payload[offset .. offset + self.data.len], self.data);
            offset += self.data.len;
            @memset(payload[offset..], 0);
        } else {
            @memcpy(payload, self.data);
        }

        return Frame{
            .header = FrameHeader{
                .length = @intCast(payload.len),
                .frame_type = FrameType.DATA,
                .flags = frame_flags,
                .stream_id = stream_id,
            },
            .payload = payload,
        };
    }
};

pub const WindowUpdateFrame = struct {
    window_size_increment: u31,

    pub fn parse(frame: Frame) !WindowUpdateFrame {
        if (frame.header.frame_type != FrameType.WINDOW_UPDATE) {
            return error.InvalidFrameType;
        }

        if (frame.payload.len != 4) return error.InvalidWindowUpdateFrame;

        const increment = (@as(u32, frame.payload[0]) << 24) |
            (@as(u32, frame.payload[1]) << 16) |
            (@as(u32, frame.payload[2]) << 8) |
            @as(u32, frame.payload[3]);

        const clean_increment = increment & 0x7FFFFFFF;
        if (clean_increment == 0) return error.InvalidWindowUpdateFrame;

        return WindowUpdateFrame{
            .window_size_increment = @intCast(clean_increment),
        };
    }

    pub fn toFrame(self: WindowUpdateFrame, allocator: mem.Allocator, stream_id: u31) !Frame {
        var payload = try allocator.alloc(u8, 4);

        payload[0] = @intCast((self.window_size_increment >> 24) & 0xFF);
        payload[1] = @intCast((self.window_size_increment >> 16) & 0xFF);
        payload[2] = @intCast((self.window_size_increment >> 8) & 0xFF);
        payload[3] = @intCast(self.window_size_increment & 0xFF);

        return Frame{
            .header = FrameHeader{
                .length = 4,
                .frame_type = FrameType.WINDOW_UPDATE,
                .flags = 0,
                .stream_id = stream_id,
            },
            .payload = payload,
        };
    }
};

pub const RstStreamFrame = struct {
    error_code: ErrorCode,

    pub fn parse(frame: Frame) !RstStreamFrame {
        if (frame.header.frame_type != FrameType.RST_STREAM) {
            return error.InvalidFrameType;
        }

        if (frame.payload.len != 4) return error.InvalidRstStreamFrame;

        const error_code_raw = (@as(u32, frame.payload[0]) << 24) |
            (@as(u32, frame.payload[1]) << 16) |
            (@as(u32, frame.payload[2]) << 8) |
            @as(u32, frame.payload[3]);

        return RstStreamFrame{
            .error_code = @enumFromInt(error_code_raw),
        };
    }

    pub fn toFrame(self: RstStreamFrame, allocator: mem.Allocator, stream_id: u31) !Frame {
        var payload = try allocator.alloc(u8, 4);
        const error_code_val = @intFromEnum(self.error_code);

        payload[0] = @intCast((error_code_val >> 24) & 0xFF);
        payload[1] = @intCast((error_code_val >> 16) & 0xFF);
        payload[2] = @intCast((error_code_val >> 8) & 0xFF);
        payload[3] = @intCast(error_code_val & 0xFF);

        return Frame{
            .header = FrameHeader{
                .length = 4,
                .frame_type = FrameType.RST_STREAM,
                .flags = 0,
                .stream_id = stream_id,
            },
            .payload = payload,
        };
    }
};

pub const GoAwayFrame = struct {
    last_stream_id: u31,
    error_code: ErrorCode,
    debug_data: []const u8,

    pub fn parse(allocator: mem.Allocator, frame: Frame) !GoAwayFrame {
        if (frame.header.frame_type != FrameType.GOAWAY) {
            return error.InvalidFrameType;
        }

        if (frame.payload.len < 8) return error.InvalidGoAwayFrame;

        const last_stream_id_raw = (@as(u32, frame.payload[0]) << 24) |
            (@as(u32, frame.payload[1]) << 16) |
            (@as(u32, frame.payload[2]) << 8) |
            @as(u32, frame.payload[3]);

        const error_code_raw = (@as(u32, frame.payload[4]) << 24) |
            (@as(u32, frame.payload[5]) << 16) |
            (@as(u32, frame.payload[6]) << 8) |
            @as(u32, frame.payload[7]);

        const last_stream_id = last_stream_id_raw & 0x7FFFFFFF;
        const debug_data = if (frame.payload.len > 8)
            try allocator.dupe(u8, frame.payload[8..])
        else
            try allocator.alloc(u8, 0);

        return GoAwayFrame{
            .last_stream_id = @intCast(last_stream_id),
            .error_code = @enumFromInt(error_code_raw),
            .debug_data = debug_data,
        };
    }

    pub fn deinit(self: GoAwayFrame, allocator: mem.Allocator) void {
        allocator.free(self.debug_data);
    }

    pub fn toFrame(self: GoAwayFrame, allocator: mem.Allocator) !Frame {
        const payload_size = 8 + self.debug_data.len;
        var payload = try allocator.alloc(u8, payload_size);

        payload[0] = @intCast((self.last_stream_id >> 24) & 0xFF);
        payload[1] = @intCast((self.last_stream_id >> 16) & 0xFF);
        payload[2] = @intCast((self.last_stream_id >> 8) & 0xFF);
        payload[3] = @intCast(self.last_stream_id & 0xFF);

        const error_code_val = @intFromEnum(self.error_code);
        payload[4] = @intCast((error_code_val >> 24) & 0xFF);
        payload[5] = @intCast((error_code_val >> 16) & 0xFF);
        payload[6] = @intCast((error_code_val >> 8) & 0xFF);
        payload[7] = @intCast(error_code_val & 0xFF);

        if (self.debug_data.len > 0) {
            @memcpy(payload[8..], self.debug_data);
        }

        return Frame{
            .header = FrameHeader{
                .length = @intCast(payload.len),
                .frame_type = FrameType.GOAWAY,
                .flags = 0,
                .stream_id = 0,
            },
            .payload = payload,
        };
    }
};

test "FrameHeader parse and serialize" {
    const test_data = [_]u8{ 0x00, 0x00, 0x0C, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const header = try FrameHeader.parse(&test_data);

    try testing.expect(header.length == 12);
    try testing.expect(header.frame_type == FrameType.SETTINGS);
    try testing.expect(header.flags == 0);
    try testing.expect(header.stream_id == 0);

    var buffer: [9]u8 = undefined;
    try header.serialize(&buffer);
    try testing.expectEqualSlices(u8, &test_data, &buffer);
}

test "SettingsFrame parse and serialize" {
    const allocator = testing.allocator;

    const test_payload = [_]u8{ 0x00, 0x03, 0x00, 0x00, 0x00, 0x64, 0x00, 0x04, 0x00, 0x00, 0x40, 0x00 };
    var settings_frame = try SettingsFrame.parse(allocator, &test_payload);
    defer settings_frame.deinit();

    try testing.expect(settings_frame.settings.items.len == 2);
    try testing.expect(settings_frame.settings.items[0].id == SettingsId.MAX_CONCURRENT_STREAMS);
    try testing.expect(settings_frame.settings.items[0].value == 100);
    try testing.expect(settings_frame.settings.items[1].id == SettingsId.INITIAL_WINDOW_SIZE);
    try testing.expect(settings_frame.settings.items[1].value == 16384);

    const serialized = try settings_frame.serialize(allocator);
    defer allocator.free(serialized);
    try testing.expectEqualSlices(u8, &test_payload, serialized);
}

test "DataFrame with padding" {
    const allocator = testing.allocator;

    const payload = [_]u8{ 0x05, 'H', 'e', 'l', 'l', 'o', 0x00, 0x00, 0x00, 0x00, 0x00 };
    const frame = Frame{
        .header = FrameHeader{
            .length = @intCast(payload.len),
            .frame_type = FrameType.DATA,
            .flags = FrameFlags.PADDED,
            .stream_id = 1,
        },
        .payload = &payload,
    };

    var data_frame = try DataFrame.parse(allocator, frame);
    defer data_frame.deinit(allocator);

    try testing.expectEqualSlices(u8, "Hello", data_frame.data);
    try testing.expect(data_frame.pad_length.? == 5);
}
