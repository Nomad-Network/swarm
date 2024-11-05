//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const nomad = @import("nomad");
const nomad_proto = @import("nomad-proto");

const InstanceContext = struct {
    packet: ?*nomad_proto.ProtocolPacket,
    database: ?*nomad.Database,
    instance: ?*Instance,
    connection: ?*std.net.Stream,
};

pub const Instance = struct {
    id: []const u8,

    allocator: std.mem.Allocator,
    db_handle: *nomad.Database,
    job_queue: *nomad.Queue(InstanceContext),

    db_sleep: *bool,

    pub fn init(allocator: std.mem.Allocator, swarm: []const u8, id: []const u8) !Instance {
        var db_sleep = false;
        var db = try nomad.Database.init(allocator, swarm ++ "-" ++ id);
        var queue = nomad.Queue(InstanceContext).init(allocator, swarm ++ "-" ++ id, .{
            .packet = null,
            .database = &db,
            .instance = null,
            .connection = null,
        });

        return Instance{
            .id = id,
            .db_handle = &db,
            .job_queue = &queue,
            .db_sleep = &db_sleep,
            .allocator = allocator,
        };
    }

    pub fn start(self: *Instance) !void {
        try self.job_queue.start();
        _ = try std.Thread.spawn(.{ .allocator = self.allocator }, &Instance._commitTick, .{ self.db_handle, self.db_sleep });
    }

    pub fn sleep(self: *Instance) void {
        self.db_sleep.* = true;
    }

    pub fn getSize(self: *Instance) usize {
        return self.db_handle.records.items.len;
    }

    pub fn process(self: *Instance, pkt: *nomad_proto.ProtocolPacket, connection: *std.net.Stream) !void {
        self.job_queue.tasks.enqueue(.{
            .name = self.id ++ "[" ++ @tagName(pkt.type) ++ "]",
            .method = &self._process,
            .ctx = &.{
                .packet = pkt,
                .database = self.db_handle,
                .instance = self,
                .connection = connection,
            },
        });
    }

    fn _commitTick(db: *nomad.Database, should_sleep: *bool) void {
        while (!should_sleep.*) {
            db.commit() catch unreachable;
            std.time.sleep(10 * std.time.ns_per_s); // 10s
        }
    }

    fn _process(ctx: *InstanceContext) void {
        const pkt = ctx.packet orelse unreachable;
        var db = ctx.database orelse unreachable;

        switch (pkt.type) {
            .DATABASE => {
                switch (pkt.content.database.type) {
                    .FETCH => {
                        var rec = db.getRecord(pkt.content.database.data.hash) catch return;
                        const record_data = rec.serialize() catch return;
                        ctx.connection.?.writeAll(record_data) catch return;
                    },
                    .DELETE => {
                        const ok = db.deleteRecord(pkt.content.database.data.hash) catch return;
                        ctx.connection.?.writeAll(ok) catch return;
                    },
                    .INSERT => {
                        const record = nomad.Record.init(pkt.content.database.owner, pkt.content.database.permissions) catch return;
                        const hash = db.addRecord(record) catch unreachable;
                        ctx.connection.?.writeAll(hash) catch unreachable;
                    },
                }
            },
            .EXECUTION => {
                return;
            },
        }
    }
};

const SwarmContext = struct {
    swarm: ?*Swarm,
    packet: ?*nomad_proto.ProtocolPacket,
    connection: ?*std.net.Stream,
};

pub const Swarm = struct {
    instances: std.ArrayList(*Instance),
    name: []const u8,
    storage_path: []const u8,
    job_queue: *nomad.Queue(SwarmContext),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, storage_path: []const u8, num_of_instances: u8) !Swarm {
        var queue = nomad.Queue(SwarmContext).init(allocator, name, .{
            .swarm = null,
        });
        const instances = std.ArrayList(*Instance).init(allocator);

        for (range(num_of_instances), 0..) |_, i| {
            var inst = try Instance.init(allocator, name, try std.fmt.allocPrint(allocator, "instance-{any}", .{i}));
            try instances.append(&inst);
        }

        return Swarm{
            .allocator = allocator,
            .name = name,
            .storage_path = storage_path,
            .instances = instances,
            .job_queue = &queue,
        };
    }

    pub fn start(self: *Swarm) void {
        for (self.instances.items) |i| {
            try i.start();
        }

        try self.job_queue.start();
    }

    pub fn process(self: *Swarm, pkt: *nomad_proto.ProtocolPacket, connection: *std.net.Stream) !void {
        self.job_queue.tasks.enqueue(.{
            .name = self.name ++ "[" ++ @tagName(pkt.type) ++ "]",
            .method = &self._process,
            .ctx = &.{
                .packet = pkt,
                .swarm = self,
                .connection = connection,
            },
        });
    }

    fn _process(_: *SwarmContext) void {
        return;
    }
};

fn range(len: usize) []const void {
    return @as([*]void, undefined)[0..len];
}
