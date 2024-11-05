//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const yazap = @import("yazap");
const vm = @import("nomad-vm");
const root = @import("./root.zig");

pub fn main() !void {
    var app = yazap.App.init(std.heap.page_allocator, "swarm", "Nomad Network swarm starter & orchestrator");
    defer app.deinit();

    var cmd = app.rootCommand();
    var start = app.createCommand("start", "Start a nomad swarm");

    try start.addArgs(&[_]yazap.Arg{
        yazap.Arg.init("instances", "Number of instances to spin up"),
        yazap.Arg.booleanOption("exec", 'e', "Enable program execution on this swarm"),
    });
    try cmd.addSubcommand(start);
    return;
}

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
