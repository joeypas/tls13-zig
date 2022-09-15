const std = @import("std");
const io = std.io;
const ArrayList = std.ArrayList;
const Handshake = @import("handshake.zig").Handshake;
const ChangeCipherSpec = @import("change_cipher_spec.zig").ChangeCipherSpec;
const Alert = @import("alert.zig").Alert;
const ApplicationData = @import("application_data.zig").ApplicationData;
const DecodeError = @import("msg.zig").DecodeError;
const crypto = @import("crypto.zig");

pub const ContentType = enum(u8) {
    invalid = 0,
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
};

pub const Content = union(ContentType) {
    invalid: Dummy,
    change_cipher_spec: ChangeCipherSpec,
    alert: Alert,
    handshake: Handshake,
    application_data: ApplicationData,

    const Self = @This();

    const Error = error{
        InvalidLength,
    };

    pub fn decode(reader: anytype, t: ContentType, len: usize, allocator: std.mem.Allocator, hkdf: ?crypto.Hkdf) !Self {
        if (t == .application_data and len == 0) {
            return Error.InvalidLength;
        }
        switch (t) {
            .invalid => unreachable,
            .change_cipher_spec => return Self{ .change_cipher_spec = try ChangeCipherSpec.decode(reader) },
            .alert => return Self{ .alert = try Alert.decode(reader) },
            .handshake => return Self{ .handshake = try Handshake.decode(reader, allocator, hkdf) },
            .application_data => return Self{ .application_data = try ApplicationData.decode(reader, len, allocator) },
        }
    }

    pub fn encode(self: Self, writer: anytype) !usize {
        switch (self) {
            .invalid => unreachable,
            .change_cipher_spec => |e| return try e.encode(writer),
            .alert => |e| return try e.encode(writer),
            .handshake => |e| return try e.encode(writer),
            .application_data => |e| return try e.encode(writer),
        }
    }

    pub fn length(self: Self) usize {
        switch (self) {
            .invalid => unreachable,
            .change_cipher_spec => |e| return e.length(),
            .alert => |e| return e.length(),
            .handshake => |e| return e.length(),
            .application_data => |e| return e.length(),
        }
    }

    pub fn deinit(self: Self) void {
        switch (self) {
            .invalid => unreachable,
            .change_cipher_spec => {},
            .alert => {},
            .handshake => |e| e.deinit(),
            .application_data => |e| e.deinit(),
        }
    }
};

const Dummy = struct {};

pub const TLSPlainText = struct {
    content: Content,

    const Self = @This();

    /// @param (Hash) is the type of hash function. It is used to decode handshake message.
    /// @param (writer) if not null, fragment is written to the writer (used for KeySchedule etc.)
    pub fn decode(reader: anytype, t: ContentType, allocator: std.mem.Allocator, hkdf: ?crypto.Hkdf, writer: anytype) !Self {
        const proto_version = try reader.readIntBig(u16);
        if (proto_version != 0x0303) {
            // TODO: return error
        }

        const len = try reader.readIntBig(u16);

        // read the fragment
        var fragment: []u8 = try allocator.alloc(u8, len);
        defer allocator.free(fragment);

        _ = try reader.readAll(fragment);
        var fragmentStream = io.fixedBufferStream(fragment);

        const cont = try Content.decode(fragmentStream.reader(), t, len, allocator, hkdf);
        errdefer cont.deinit();

        // check the entire of fragment has been decoded
        if ((try fragmentStream.getPos()) != (try fragmentStream.getEndPos())) {
            return DecodeError.NotAllDecoded;
        }

        if (@TypeOf(writer) != @TypeOf(null)) {
            try writer.writeAll(fragment);
        }

        return Self{
            .content = cont,
        };
    }

    pub fn encode(self: Self, writer: anytype) !usize {
        var len: usize = 0;

        try writer.writeIntBig(u8, @enumToInt(self.content));
        len += @sizeOf(u8);

        try writer.writeIntBig(u16, 0x0303);
        len += @sizeOf(u16);

        len += @sizeOf(u16);
        try writer.writeIntBig(u16, @intCast(u16, self.length() - len));

        len += try self.content.encode(writer);

        return len;
    }

    pub fn length(self: Self) usize {
        var len: usize = 0;
        len += @sizeOf(u8); // content_type
        len += @sizeOf(u16); // protocol_version
        len += @sizeOf(u16); // length
        len += self.content.length();

        return len;
    }

    pub fn deinit(self: Self) void {
        self.content.deinit();
    }
};

pub const TLSCipherText = struct {
    record: []u8 = undefined,
    allocator: std.mem.Allocator = undefined,

    const Self = @This();

    const Error = error{
        InvalidContentType,
        InvalidProtocolVersion,
    };

    pub fn init(len: usize, allocator: std.mem.Allocator) !Self {
        return Self{
            .record = try allocator.alloc(u8, len),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.record);
    }

    pub fn decode(reader: anytype, t: ContentType, allocator: std.mem.Allocator) !Self {
        if (t != .application_data) {
            return Error.InvalidContentType;
        }

        const proto_version = try reader.readIntBig(u16);
        if (proto_version != 0x0303) {
            return Error.InvalidProtocolVersion;
        }

        const len = try reader.readIntBig(u16);
        var res = try Self.init(len, allocator);
        errdefer res.deinit();

        try reader.readNoEof(res.record);

        return res;
    }

    pub fn encode(self: Self, writer: anytype) !usize {
        var len: usize = try self.writeHeader(writer);

        try writer.writeAll(self.record);
        len += self.record.len;

        return len;
    }

    pub fn writeHeader(self: Self, writer: anytype) !usize {
        var len: usize = 0;

        try writer.writeIntBig(u8, @enumToInt(ContentType.application_data));
        len += @sizeOf(u8);

        try writer.writeIntBig(u16, 0x0303); //protocol_version
        len += @sizeOf(u16);

        try writer.writeIntBig(u16, @intCast(u16, self.record.len)); //record length
        len += @sizeOf(u16);

        return len;
    }

    pub fn length(self: Self) usize {
        var len: usize = 0;
        len += @sizeOf(u8); // ContentType
        len += @sizeOf(u16); // protocol_version
        len += @sizeOf(u16); // record length
        len += self.record.len; // record

        return len;
    }
};

pub const TLSInnerPlainText = struct {
    content: []u8,
    content_type: ContentType,
    zero_pad_length: usize = 0,

    allocator: std.mem.Allocator,

    const Self = @This();

    const Error = error{
        NoContents,
        InvalidData,
        EncodeFailed,
        DecodeFailed,
    };

    pub fn init(len: usize, content_type: ContentType, allocator: std.mem.Allocator) !Self {
        return Self{
            .content = try allocator.alloc(u8, len),
            .content_type = content_type,
            .allocator = allocator,
        };
    }

    pub fn initWithContent(content: Content, allocator: std.mem.Allocator) !Self {
        var pt = try Self.init(content.length(), content, allocator);
        errdefer pt.deinit();

        pt.content_type = content;

        var stream = io.fixedBufferStream(pt.content);
        const enc_len = try content.encode(stream.writer());
        if (enc_len != pt.content.len) {
            return Error.EncodeFailed;
        }

        return pt;
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.content);
    }

    pub fn decode(m: []const u8, allocator: std.mem.Allocator) !Self {
        // specify the length of zero padding
        var i: usize = m.len - 1;
        while (i > 0) : (i -= 1) {
            if (m[i] != 0x0) {
                break;
            }
            if (i == 0) {
                // if the 'm' does not contains non-zero value(ContentType), it must be invalid data.
                return Error.InvalidData;
            }
        }

        const zero_pad_length = (m.len - 1) - i;
        const content_len = m.len - zero_pad_length - 1;

        const content_type = @intToEnum(ContentType, m[content_len]);
        var res = try Self.init(content_len, content_type, allocator);
        errdefer res.deinit();

        res.zero_pad_length = zero_pad_length;
        std.mem.copy(u8, res.content, m[0..content_len]);

        return res;
    }

    pub fn decodeContent(self: Self, allocator: std.mem.Allocator, hkdf: ?crypto.Hkdf) !Content {
        var stream = io.fixedBufferStream(self.content);
        return try Content.decode(stream.reader(), self.content_type, self.content.len, allocator, hkdf);
    }

    pub fn decodeContents(self: Self, allocator: std.mem.Allocator, hkdf: ?crypto.Hkdf) !ArrayList(Content) {
        var res = ArrayList(Content).init(allocator);
        errdefer res.deinit();

        var stream = io.fixedBufferStream(self.content);
        while ((try stream.getPos() != (try stream.getEndPos()))) {
            const rest_size = (try stream.getEndPos()) - (try stream.getPos());
            const cont = try Content.decode(stream.reader(), self.content_type, rest_size, allocator, hkdf);
            errdefer cont.deinit();
            try res.append(cont);
        }

        if ((try stream.getPos() != (try stream.getEndPos()))) {
            return Error.DecodeFailed;
        }

        return res;
    }

    pub fn encode(self: Self, writer: anytype) !usize {
        var len: usize = 0;

        try writer.writeAll(self.content);
        len += self.content.len;

        try writer.writeByte(@enumToInt(self.content_type));
        len += @sizeOf(u8);

        // TODO: more efficient way to zero filling
        var i: usize = 0;
        while (i < self.zero_pad_length) : (i += 1) {
            try writer.writeByte(0x00);
            len += @sizeOf(u8);
        }

        return len;
    }

    pub fn encodeContents(contents: ArrayList(Content), writer: anytype, allocator: std.mem.Allocator) !usize {
        if (contents.items.len != 0) {
            return Error.NoContents;
        }
        var len: usize = 0;
        for (contents.items) |c| {
            len += c.length();
        }

        var pt = Self.init(len, allocator);
        defer pt.deinit();

        for (contents.items) |c| {
            try c.encode(pt.stream.writer());
        }

        return try pt.encode(writer);
    }

    pub fn length(self: Self) usize {
        var len: usize = 0;
        len += self.content.len;
        len += @sizeOf(u8); // ContentType
        len += self.zero_pad_length;

        return len;
    }
};

const expect = std.testing.expect;
const expectError = std.testing.expectError;

test "TLSPlainText ClientHello decode" {
    const recv_data = [_]u8{ 0x16, 0x03, 0x01, 0x00, 0x94, 0x01, 0x00, 0x00, 0x90, 0x03, 0x03, 0xf0, 0x5d, 0x41, 0x2d, 0x24, 0x35, 0x27, 0xfd, 0x90, 0xb5, 0xb4, 0x24, 0x9d, 0x4a, 0x69, 0xf8, 0x97, 0xb5, 0xcf, 0xfe, 0xe3, 0x8d, 0x4c, 0xec, 0xc7, 0x8f, 0xd0, 0x25, 0xc6, 0xeb, 0xe1, 0x33, 0x20, 0x67, 0x7e, 0xb6, 0x52, 0xad, 0x12, 0x51, 0xda, 0x7a, 0xe4, 0x5d, 0x3f, 0x19, 0x2c, 0xd1, 0xbf, 0xaf, 0xca, 0xa8, 0xc5, 0xfe, 0x59, 0x2f, 0x1b, 0x2f, 0x2a, 0x96, 0x1e, 0x12, 0x83, 0x35, 0xae, 0x00, 0x02, 0x13, 0x02, 0x01, 0x00, 0x00, 0x45, 0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04, 0x00, 0x0a, 0x00, 0x06, 0x00, 0x04, 0x00, 0x1d, 0x00, 0x17, 0x00, 0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20, 0x49, 0x51, 0x50, 0xa9, 0x0a, 0x47, 0x82, 0xfe, 0xa7, 0x47, 0xf5, 0xcb, 0x55, 0x19, 0xdc, 0xf0, 0xce, 0x0d, 0xee, 0x9c, 0xdc, 0x04, 0x93, 0xbd, 0x84, 0x9e, 0xea, 0xf7, 0xd3, 0x93, 0x64, 0x2f, 0x00, 0x0d, 0x00, 0x06, 0x00, 0x04, 0x04, 0x03, 0x08, 0x07 };
    var readStream = io.fixedBufferStream(&recv_data);

    const t = try readStream.reader().readEnum(ContentType, .Big);
    const res = try TLSPlainText.decode(readStream.reader(), t, std.testing.allocator, null, null);
    defer res.deinit();

    try expect(res.content == .handshake);
    try expect(res.content.handshake == .client_hello);
}

test "TLSCipherText decode" {
    const recv_data = [_]u8{ 0x17, 0x03, 0x03, 0x00, 0x13, 0xB5, 0x8F, 0xD6, 0x71, 0x66, 0xEB, 0xF5, 0x99, 0xD2, 0x47, 0x20, 0xCF, 0xBE, 0x7E, 0xFA, 0x7A, 0x88, 0x64, 0xA9 };
    var readStream = io.fixedBufferStream(&recv_data);

    const t = try readStream.reader().readEnum(ContentType, .Big);
    const res = try TLSCipherText.decode(readStream.reader(), t, std.testing.allocator);
    defer res.deinit();

    try expectError(error.EndOfStream, readStream.reader().readByte());

    const record_ans = [_]u8{ 0xB5, 0x8F, 0xD6, 0x71, 0x66, 0xEB, 0xF5, 0x99, 0xD2, 0x47, 0x20, 0xCF, 0xBE, 0x7E, 0xFA, 0x7A, 0x88, 0x64, 0xA9 };
    try expect(std.mem.eql(u8, res.record, &record_ans));
}

test "TLSCipherText encode" {
    const record = [_]u8{ 0xB5, 0x8F, 0xD6, 0x71, 0x66, 0xEB, 0xF5, 0x99, 0xD2, 0x47, 0x20, 0xCF, 0xBE, 0x7E, 0xFA, 0x7A, 0x88, 0x64, 0xA9 };

    var ct = try TLSCipherText.init(record.len, std.testing.allocator);
    defer ct.deinit();
    std.mem.copy(u8, ct.record, &record);

    var send_data: [1000]u8 = undefined;
    var sendStream = io.fixedBufferStream(&send_data);
    const write_len = try ct.encode(sendStream.writer());
    try expect(write_len == try sendStream.getPos());

    const send_data_ans = [_]u8{ 0x17, 0x03, 0x03, 0x00, 0x13, 0xB5, 0x8F, 0xD6, 0x71, 0x66, 0xEB, 0xF5, 0x99, 0xD2, 0x47, 0x20, 0xCF, 0xBE, 0x7E, 0xFA, 0x7A, 0x88, 0x64, 0xA9 };
    try expect(std.mem.eql(u8, send_data[0..write_len], &send_data_ans));
}

test "TLSInnerPlainText decode" {
    const recv_data = [_]u8{ 0x01, 0x00, 0x15, 0x00, 0x00, 0x00 }; // ContentType alert

    var pt = try TLSInnerPlainText.decode(&recv_data, std.testing.allocator);
    defer pt.deinit();
    const content = try pt.decodeContent(std.testing.allocator, null);
    defer content.deinit();

    try expect(content == .alert);
    const alert = content.alert;
    try expect(alert.level == .warning);
    try expect(alert.description == .close_notify);
    try expect(pt.zero_pad_length == 3);
}

test "TLSInnerPlainText encode" {
    const alert = Content{ .alert = Alert{
        .level = .warning,
        .description = .close_notify,
    } };
    var mt = try TLSInnerPlainText.initWithContent(alert, std.testing.allocator);
    defer mt.deinit();
    mt.zero_pad_length = 2;

    var send_data: [1000]u8 = undefined;
    var sendStream = io.fixedBufferStream(&send_data);
    const write_len = try mt.encode(sendStream.writer());
    try expect(write_len == try sendStream.getPos());

    const send_data_ans = [_]u8{ 0x01, 0x00, 0x15, 0x00, 0x00 };
    try expect(std.mem.eql(u8, send_data[0..write_len], &send_data_ans));
}
