const std = @import("std");
const mem = std.mem;

const STATIC_TABLE = [_]HeaderField{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

pub const HeaderField = struct {
    name: []const u8,
    value: []const u8,

    pub fn size(self: HeaderField) usize {
        return self.name.len + self.value.len + 32;
    }
};

pub const DynamicTable = struct {
    entries: std.ArrayList(HeaderField),
    max_size: usize,
    current_size: usize,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, max_size: usize) DynamicTable {
        return DynamicTable{
            .entries = std.ArrayList(HeaderField).init(allocator),
            .max_size = max_size,
            .current_size = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DynamicTable) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.entries.deinit();
    }

    pub fn add(self: *DynamicTable, name: []const u8, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        const owned_value = try self.allocator.dupe(u8, value);

        const entry = HeaderField{
            .name = owned_name,
            .value = owned_value,
        };

        const entry_size = entry.size();

        if (entry_size > self.max_size) {
            self.allocator.free(owned_name);
            self.allocator.free(owned_value);
            self.clear();
            return;
        }

        self.evictToFit(entry_size);

        try self.entries.insert(0, entry);
        self.current_size += entry_size;
    }

    pub fn get(self: *const DynamicTable, index: usize) ?HeaderField {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    pub fn setMaxSize(self: *DynamicTable, new_max_size: usize) void {
        self.max_size = new_max_size;
        self.evictToFit(0);
    }

    fn evictToFit(self: *DynamicTable, new_entry_size: usize) void {
        while (self.current_size + new_entry_size > self.max_size and self.entries.items.len > 0) {
            if (self.entries.pop()) |last_entry| {
                const entry_size = last_entry.size();
                self.current_size -= entry_size;
                self.allocator.free(last_entry.name);
                self.allocator.free(last_entry.value);
            } else {
                break;
            }
        }
    }

    fn clear(self: *DynamicTable) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.entries.clearAndFree();
        self.current_size = 0;
    }
};

pub const HpackDecoder = struct {
    dynamic_table: DynamicTable,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, max_table_size: usize) HpackDecoder {
        return HpackDecoder{
            .dynamic_table = DynamicTable.init(allocator, max_table_size),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HpackDecoder) void {
        self.dynamic_table.deinit();
    }

    pub fn decode(self: *HpackDecoder, data: []const u8) !std.ArrayList(HeaderField) {
        var headers = std.ArrayList(HeaderField).init(self.allocator);
        var pos: usize = 0;

        while (pos < data.len) {
            if (data[pos] & 0x80 != 0) {
                // Indexed Header Field
                const index = try self.decodeInteger(data, &pos, 7);
                const header = try self.getHeaderField(index);
                try headers.append(header);
            } else if (data[pos] & 0x40 != 0) {
                // Literal Header Field with Incremental Indexing
                const index = try self.decodeInteger(data, &pos, 6);
                const header = try self.decodeLiteralHeader(data, &pos, index, true);
                try headers.append(header);
            } else if (data[pos] & 0x20 != 0) {
                // Dynamic Table Size Update
                const new_size = try self.decodeInteger(data, &pos, 5);
                self.dynamic_table.setMaxSize(new_size);
            } else if (data[pos] & 0x10 != 0) {
                // Literal Header Field Never Indexed
                const index = try self.decodeInteger(data, &pos, 4);
                const header = try self.decodeLiteralHeader(data, &pos, index, false);
                try headers.append(header);
            } else {
                // Literal Header Field without Indexing
                const index = try self.decodeInteger(data, &pos, 4);
                const header = try self.decodeLiteralHeader(data, &pos, index, false);
                try headers.append(header);
            }
        }

        return headers;
    }

    pub fn decodeInteger(self: *HpackDecoder, data: []const u8, pos: *usize, prefix_bits: u3) !usize {
        _ = self;
        if (pos.* >= data.len) return error.InvalidInteger;

        const mask = (@as(u8, 1) << prefix_bits) - 1;
        var value = @as(usize, data[pos.*] & mask);
        pos.* += 1;

        if (value < mask) return value;

        var m: u6 = 0;
        while (pos.* < data.len) {
            const b = data[pos.*];
            pos.* += 1;

            value += (@as(usize, b & 0x7F) << m);
            m += 7;

            if (b & 0x80 == 0) break;
        }

        return value;
    }

    fn decodeString(self: *HpackDecoder, data: []const u8, pos: *usize) ![]u8 {
        if (pos.* >= data.len) return error.InvalidString;

        const huffman_encoded = (data[pos.*] & 0x80) != 0;
        const length = try self.decodeInteger(data, pos, 7);

        if (pos.* + length > data.len) return error.InvalidString;

        const string_data = data[pos.* .. pos.* + length];
        pos.* += length;

        if (huffman_encoded) {
            return try self.decodeHuffman(string_data);
        } else {
            return try self.allocator.dupe(u8, string_data);
        }
    }

    fn decodeHuffman(self: *HpackDecoder, data: []const u8) ![]u8 {
        // Simplified Huffman decoding - in a real implementation,
        // this would use the HPACK Huffman table
        return try self.allocator.dupe(u8, data);
    }

    pub fn getHeaderField(self: *HpackDecoder, index: usize) !HeaderField {
        if (index == 0) return error.InvalidIndex;

        if (index <= STATIC_TABLE.len) {
            const static_entry = STATIC_TABLE[index - 1];
            return HeaderField{
                .name = try self.allocator.dupe(u8, static_entry.name),
                .value = try self.allocator.dupe(u8, static_entry.value),
            };
        } else {
            const dynamic_index = index - STATIC_TABLE.len - 1;
            const dynamic_entry = self.dynamic_table.get(dynamic_index) orelse return error.InvalidIndex;
            return HeaderField{
                .name = try self.allocator.dupe(u8, dynamic_entry.name),
                .value = try self.allocator.dupe(u8, dynamic_entry.value),
            };
        }
    }

    fn decodeLiteralHeader(self: *HpackDecoder, data: []const u8, pos: *usize, name_index: usize, add_to_table: bool) !HeaderField {
        const name = if (name_index == 0)
            try self.decodeString(data, pos)
        else blk: {
            const header = try self.getHeaderField(name_index);
            defer self.allocator.free(header.value);
            defer self.allocator.free(header.name);
            break :blk try self.allocator.dupe(u8, header.name);
        };

        const value = try self.decodeString(data, pos);

        if (add_to_table) {
            try self.dynamic_table.add(name, value);
        }

        return HeaderField{
            .name = name,
            .value = value,
        };
    }
};

pub const HpackEncoder = struct {
    dynamic_table: DynamicTable,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, max_table_size: usize) HpackEncoder {
        return HpackEncoder{
            .dynamic_table = DynamicTable.init(allocator, max_table_size),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HpackEncoder) void {
        self.dynamic_table.deinit();
    }

    pub fn encode(self: *HpackEncoder, headers: []const HeaderField) ![]u8 {
        var encoded = std.ArrayList(u8).init(self.allocator);
        defer encoded.deinit();

        for (headers) |header| {
            const index = self.findIndex(header);

            if (index) |idx| {
                if (self.isExactMatch(header, idx)) {
                    // Indexed Header Field
                    try self.encodeInteger(&encoded, idx, 7, 0x80);
                } else {
                    // Literal Header Field with Incremental Indexing
                    try self.encodeInteger(&encoded, idx, 6, 0x40);
                    try self.encodeString(&encoded, header.value);
                    try self.dynamic_table.add(header.name, header.value);
                }
            } else {
                // Literal Header Field with Incremental Indexing (new name)
                try encoded.append(0x40);
                try self.encodeString(&encoded, header.name);
                try self.encodeString(&encoded, header.value);
                try self.dynamic_table.add(header.name, header.value);
            }
        }

        return try encoded.toOwnedSlice();
    }

    fn findIndex(self: *const HpackEncoder, header: HeaderField) ?usize {
        // Search static table
        for (STATIC_TABLE, 0..) |entry, i| {
            if (mem.eql(u8, entry.name, header.name)) {
                return i + 1;
            }
        }

        // Search dynamic table
        for (self.dynamic_table.entries.items, 0..) |entry, i| {
            if (mem.eql(u8, entry.name, header.name)) {
                return STATIC_TABLE.len + i + 1;
            }
        }

        return null;
    }

    fn isExactMatch(self: *const HpackEncoder, header: HeaderField, index: usize) bool {
        if (index <= STATIC_TABLE.len) {
            const static_entry = STATIC_TABLE[index - 1];
            return mem.eql(u8, static_entry.name, header.name) and
                mem.eql(u8, static_entry.value, header.value);
        } else {
            const dynamic_index = index - STATIC_TABLE.len - 1;
            if (self.dynamic_table.get(dynamic_index)) |entry| {
                return mem.eql(u8, entry.name, header.name) and
                    mem.eql(u8, entry.value, header.value);
            }
        }
        return false;
    }

    pub fn encodeInteger(self: *HpackEncoder, output: *std.ArrayList(u8), value: usize, prefix_bits: u3, pattern: u8) !void {
        _ = self;
        const max_prefix = (@as(usize, 1) << prefix_bits) - 1;

        if (value < max_prefix) {
            try output.append(pattern | @as(u8, @intCast(value)));
        } else {
            try output.append(pattern | @as(u8, @intCast(max_prefix)));

            var remaining = value - max_prefix;
            while (remaining >= 128) {
                try output.append(@as(u8, @intCast((remaining % 128) + 128)));
                remaining /= 128;
            }
            try output.append(@as(u8, @intCast(remaining)));
        }
    }

    fn encodeString(self: *HpackEncoder, output: *std.ArrayList(u8), string: []const u8) !void {
        // Simple string encoding without Huffman compression
        try self.encodeInteger(output, string.len, 7, 0);
        try output.appendSlice(string);
    }
};
