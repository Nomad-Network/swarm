//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const nomad = @import("nomad");
const nomad_proto = @import("nomad-proto");

/// Ensures that a directory exists at the given path.
/// Creates it if it doesn't exist.
/// Returns an error if creation fails or if path exists but is not a directory.
fn ensureDir(path: []const u8, allocator: std.mem.Allocator) !void {
    // Try to make the directory first
    std.fs.cwd().makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Path exists - verify it's a directory
            var dir = try std.fs.cwd().openDir(path, .{});
            defer dir.close();

            // If we can open it as a directory, we're good
            return;
        },
        error.FileNotFound => {
            // Create parent directories if they don't exist
            const parent_path = std.fs.path.dirname(path) orelse return err;
            try ensureDir(parent_path, allocator);

            // Try creating the directory again
            try std.fs.cwd().makeDir(path);
        },
        else => return err,
    };
}

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
                        var rec = db.getRecord(pkt.content.database.data.hash) catch {
                            std.log.info("grdb: {any}", .{pkt.content.database});
                            ctx.connection.?.writeAll(&[_]u8{0}) catch return .failed;
                            ctx.connection.?.close();
                            return .done;
                        };
                        const record_data = rec.serialize() catch return .failed;
                        ctx.connection.?.writeAll(record_data) catch return .failed;
                    },
                    .DELETE => {
                        const ok = db.deleteRecord(pkt.content.database.data.hash) catch return .failed;
                        ctx.connection.?.writeAll(&[1]u8{@intFromBool(ok)}) catch return .failed;
                    },
                    .INSERT => {
                        std.log.debug("dbg: {s}", .{"Link?"});
                        const record = nomad.Record.init(pkt.content.database.owner, pkt.content.database.permissions) catch return .failed;
                        const hash = db.addRecord(record) catch unreachable;
                        ctx.connection.?.writeAll(std.fmt.allocPrint(ctx.instance.?.gpa.allocator(), "{any}", .{hash}) catch unreachable) catch unreachable;
                    },
                }
            },
            .EXECUTION => {
                return .done;
            },
        }

        return .done;
    }
};

const SwarmContext = struct {
    swarm: ?*Swarm = null,
    packet: ?*nomad_proto.ProtocolPacket = null,
    connection: ?*std.net.Stream = null,
};

pub const Swarm = struct {
    pub const SwarmQueue = nomad.Queue(SwarmContext);

    name: []const u8,
    selection_index: u8,
    storage_path: []const u8,
    instances: std.ArrayList(*Instance),
    job_queue: *SwarmQueue,

    gpa: std.heap.GeneralPurposeAllocator(.{}),

    pub fn init(name: []const u8, storage_path: []const u8, num_of_instances: u8) !Swarm {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const queue_allocator = gpa.allocator();
        var queue = SwarmQueue.init(queue_allocator, name);
        var instances = std.ArrayList(*Instance).init(gpa.allocator());

        try ensureDir(storage_path, gpa.allocator());

        for (range(num_of_instances), 0..) |_, i| {
            const id = try std.fmt.allocPrint(gpa.allocator(), "instance-{any}", .{i});
            const id_copy = try gpa.allocator().alloc(u8, id.len);
            std.mem.copyBackwards(u8, id_copy, id);
            const swarm = try std.fmt.allocPrint(gpa.allocator(), "{s}/{s}", .{ storage_path, name });
            std.log.debug("ids: {s}, {s}, {s}", .{ id_copy, id, swarm });
            const inst = try Instance.init(
                swarm,
                id_copy,
            );
            const inst_copy = try gpa.allocator().create(Instance);
            inst_copy.* = inst;
            try instances.append(inst_copy);
        }

        return Swarm{
            .gpa = gpa,
            .name = name,
            .storage_path = storage_path,
            .instances = instances,
            .job_queue = &queue,
            .selection_index = 0,
        };
    }

    pub fn start(self: *Swarm) !void {
        for (self.instances.items) |i| {
            std.log.debug("swarm: {s}", .{i.id});
            try i.start();
        }

        try self.job_queue.start();
        std.log.info("job queue start called", .{});
    }

    pub fn process(self: *Swarm, pkt: *nomad_proto.ProtocolPacket, connection: *std.net.Stream) !void {
        std.log.info("{any}\n{any}", .{ pkt, pkt.content.database });

        try self.job_queue.tasks.enqueue(.{
            .name = try std.fmt.allocPrint(self.gpa.allocator(), "{s}[{s}]", .{ self.name, @tagName(pkt.type) }),
            .method = &Swarm._process,
            .ctx = @constCast(&SwarmContext{
                .packet = pkt,
                .swarm = self,
                .connection = connection,
            }),
        });
        
        std.log.info("Task queued", .{});
    }

    fn pickInstance(self: *Swarm) *Instance {
        const inst = self.instances.items[self.selection_index];
        self.selection_index += 1;

        return inst;
    }

    fn findRecordDatabase(self: *Swarm, hash: u64) ?*Instance {
        for (self.instances.items) |value| {
            if (value.db_handle.lookup_table.hasRecord(hash)) {
                return value;
            }
        }

        return null;
    }

    fn _process(ctx: *SwarmContext) SwarmQueue.Status {
        const pkt = ctx.packet orelse unreachable;
        var swarm = ctx.swarm orelse unreachable;

        switch (pkt.type) {
            .DATABASE => {
                switch (pkt.content.database.type) {
                    .FETCH, .DELETE => {
                        if (swarm.findRecordDatabase(pkt.content.database.data.hash)) |inst| {
                            if (ctx.connection) |conn| {
                                inst.process(pkt, conn) catch unreachable;
                            }
                            // ctx.connection.?.writeAll(bytes: []const u8)
                        }
                    },
                    .INSERT => {
                        if (ctx.connection) |conn| {
                            swarm.pickInstance().process(pkt, conn) catch unreachable;
                        }
                    },
                }
            },
            .EXECUTION => {},
        }

        return .done;
    }
};

fn range(len: usize) []const void {
    return @as([*]void, undefined)[0..len];
}
