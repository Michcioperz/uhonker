const std = @import("std");

const warn = std.debug.warn;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = &arena.allocator;

    var args = std.process.args();
    var _argv0 = try args.next(alloc) orelse error.MissingArgv0;
    var inName = try args.next(alloc) orelse error.MissingInputPath;
    var outName = try args.next(alloc) orelse error.MissingOutputPath;

    const inFile = try std.fs.cwd().openFile(inName, .{});
    var in = std.io.bufferedInStream(inFile.inStream());
    var bits = std.io.bitInStream(.Little, in.inStream());
    const outFile = try std.fs.cwd().createFile(outName, .{});
    var out = BufferedOutStream(16 * 4096, @TypeOf(outFile.outStream())){ .unbuffered_out_stream = outFile.outStream() };
    const outS = out.outStream();
    const print = outS.print;

    var width = try bits.readBitsNoEof(usize, 24);
    var height = try bits.readBitsNoEof(usize, 24);
    try print("P3\n{} {} {}\n", .{ width, height, 255 });
    const pixels = width * height;
    var buf = try alloc.alloc(u8, 3 * pixels);
    var drawn: usize = 0;
    while (drawn < pixels) {
        var action = try bits.readBitsNoEof(u1, 1);
        switch (action) {
            1 => {
                buf[3 * drawn + 0] = try bits.readBitsNoEof(u8, 8);
                buf[3 * drawn + 1] = try bits.readBitsNoEof(u8, 8);
                buf[3 * drawn + 2] = try bits.readBitsNoEof(u8, 8);
                try print("{} {} {}\n", .{ buf[3 * drawn + 0], buf[3 * drawn + 1], buf[3 * drawn + 2] });
                drawn += 1;
            },
            0 => {
                var offset = try bits.readBitsNoEof(usize, 5);
                var count = try bits.readBitsNoEof(usize, 5);
                if (offset >= drawn) {
                    return error.OffsetOutOfBounds;
                }
                while (count > 0 and drawn < pixels) : (count -= 1) {
                    inline for (.{ 0, 1, 2 }) |c| {
                        buf[3 * (drawn) + c] = buf[3 * (drawn - offset - 1) + c];
                    }
                    try print("{} {} {}\n", .{ buf[3 * drawn + 0], buf[3 * drawn + 1], buf[3 * drawn + 2] });
                    drawn += 1;
                }
            },
        }
    }
    try out.flush();
}

pub fn BufferedOutStream(comptime buffer_size: usize, comptime OutStreamType: type) type {
    const io = std.io;
    return struct {
        unbuffered_out_stream: OutStreamType,
        fifo: FifoType = FifoType.init(),

        pub const Error = OutStreamType.Error;
        pub const OutStream = io.OutStream(*Self, Error, write);

        const Self = @This();
        const FifoType = std.fifo.LinearFifo(u8, std.fifo.LinearFifoBufferType{ .Static = buffer_size });

        pub fn flush(self: *Self) !void {
            while (try self.flushOnce()) {}
        }

        fn flushOnce(self: *Self) !bool {
            const slice = self.fifo.readableSlice(0);
            if (slice.len == 0) return false;
            try self.unbuffered_out_stream.writeAll(slice);
            self.fifo.discard(slice.len);
            return true;
        }

        pub fn outStream(self: *Self) OutStream {
            return .{ .context = self };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            const first = self.fifo.writableLength();
            if (first > 0) {
                self.fifo.writeAssumeCapacity(bytes[0..std.math.min(first, bytes.len)]);
            }
            if (bytes.len > first) {
                if (try self.flushOnce()) {
                    return self.write(bytes[first..bytes.len]);
                } else {
                    return self.unbuffered_out_stream.write(bytes[first..bytes.len]);
                }
            } else {
                return bytes.len;
            }
        }
    };
}
