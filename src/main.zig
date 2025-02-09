//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const yazap = @import("yazap");
const vm = @import("nomad-vm");
const proto = @import("nomad-proto");
const root = @import("./root.zig");

const ProtoPacket = proto.PacketDefinition(proto.ProtocolPacket, std.heap.page_allocator);

const stdout = std.io.getStdOut().writer();

fn processConnection(client: *std.net.Server.Connection, swarm: *root.Swarm) void {
    const bytes = client.stream.reader().readAllAlloc(std.heap.page_allocator, @as(usize, ProtoPacket.getSize())) catch return;
    std.log.debug("process: {any}", .{bytes});
    var data = std.mem.zeroes([ProtoPacket.getSize()]u8);
    std.mem.copyForwards(u8, &data, bytes);
    std.log.debug("data: {any}", .{data});
    swarm.process(ProtoPacket.deserialize(&data), &client.stream) catch return;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const allocator = gpa.allocator();
    
    var app = yazap.App.init(std.heap.page_allocator, "swarm", "Nomad Network swarm starter & orchestrator");
    defer app.deinit();

    var cmd = app.rootCommand();
    var start = app.createCommand("start", "Start a nomad swarm");

    try start.addArgs(&[_]yazap.Arg{
        yazap.Arg.init("instances", "Number of instances to spin up"),
        yazap.Arg.singleValueOption("name", 'n', "Name of the swarm"),
        yazap.Arg.singleValueOption("storage", 's', "Storage path for the swarm to use"),
        yazap.Arg.booleanOption("exec", 'e', "Enable program execution on this swarm"),
    });
    try cmd.addSubcommand(start);

    const matches = try app.parseProcess();

    if (!matches.containsArgs()) {
        try app.displayHelp();
        return;
    }

    if (matches.subcommandMatches("start")) |start_matches| {
        var instances: u8 = 8;
        const swarm_name: []const u8 = start_matches.getSingleValue("name") orelse "swarm";
        const swarm_storage: []const u8 = start_matches.getSingleValue("storage") orelse ".nswarm";

        if (start_matches.getSingleValue("instances")) |inst| {
            instances = std.fmt.parseInt(u8, inst, 0) catch 8;
        }

        std.log.debug("inst: {any}, name: {s}, storage: {s}", .{ instances, swarm_name, swarm_storage });
        var address = try std.net.Address.parseIp("127.0.0.1", 9807);
        var server = try address.listen(.{});
    
        var swarm = try root.Swarm.init(swarm_name, swarm_storage, instances);
        try swarm.start();
        std.log.info("Swarm started", .{});
        while (true) {
            std.log.debug("Waiting for connection, {any}", .{server});
            var client = try server.accept();
            std.log.debug("Accepted connection: {any}", .{client.address});
            const th = try std.Thread.spawn(.{ .allocator = allocator }, processConnection, .{ &client, &swarm });
            th.detach();
        }
    }
    return;
}

const Client = struct {
    socket: std.posix.socket_t,
    address: std.net.Address,

    fn handle(self: Client) void {
        defer std.posix.close(self.socket);
        self._handle() catch |err| switch (err) {
            error.Closed => {},
            error.WouldBlock => {}, // read or write timeout
            else => std.debug.print("[{any}] client handle error: {}\n", .{self.address, err}),
        };
    }

    fn _handle(self: Client) !void {
        const socket = self.socket;
        std.debug.print("[{}] connected\n", .{self.address});

        const timeout = std.posix.timeval{ .sec = 2, .usec = 500_000 };
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

        var buf: [1024]u8 = undefined;
        var reader = Reader{ .pos = 0, .buf = &buf, .socket = socket };

        while (true) {
            const msg = try reader.readMessage();
            std.debug.print("[{}] sent: {s}\n", .{self.address, msg});
        }
    }
};

const Reader = struct {
    buf: []u8,
    pos: usize = 0,
    start: usize = 0,
    socket: std.posix.socket_t,

    fn readMessage(self: *Reader) ![]u8 {
        var buf = self.buf;

        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return msg;
            }
            const pos = self.pos;
            const n = try std.posix.read(self.socket, buf[pos..]);
            if (n == 0) {
                return error.Closed;
            }
            self.pos = pos + n;
        }
    }

    fn bufferedMessage(self: *Reader) !?[]u8 {
        const buf = self.buf;
        const pos = self.pos;
        const start = self.start;

        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];
        if (unprocessed.len < 4) {
            self.ensureSpace(4 - unprocessed.len) catch unreachable;
            return null;
        }

        const message_len = std.mem.readInt(u32, unprocessed[0..4], .little);

        // the length of our message + the length of our prefix
        const total_len = message_len + 4;

        if (unprocessed.len < total_len) {
            try self.ensureSpace(total_len);
            return null;
        }

        self.start += total_len;
        return unprocessed[4..total_len];
    }

    fn ensureSpace(self: *Reader, space: usize) error{BufferTooSmall}!void {
        const buf = self.buf;
        if (buf.len < space) {
            return error.BufferTooSmall;
        }

        const start = self.start;
        const spare = buf.len - start;
        if (spare >= space) {
            return;
        }

        const unprocessed = buf[start..self.pos];
        std.mem.copyForwards(u8, buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const global = struct {
        fn testOne(input: []const u8) anyerror!void {
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(global.testOne, .{});
}
