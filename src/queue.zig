const std = @import("std");

pub fn Job(comptime T: type) type {
    return struct {
        name: []u8,
        execute: *const fn (context: T) void,
        context: T,
    };
}

pub fn Node(comptime T: type) type {
    return struct {
        job: Job(T),
        next: ?*Node(T) = null,
    };
}

pub fn JobQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const NodeType = Node(T);
        
        head: *?*NodeType, // Points to the head of the queue
        tail: *?*NodeType, // Points to the tail of the queue
        allocator: std.mem.Allocator,
        is_running: std.atomic.Value(bool),
    
        name: []const u8,
  
        pub const Status = enum(u8) {
            done,
            retry,
            failed,
        };

    
        pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
            const dummyNode = allocator.create(?*NodeType) catch unreachable;
            return Self {
                .head = dummyNode,
                .tail = dummyNode,
                .allocator = allocator,
                .is_running = std.atomic.Value(bool).init(true),
                .name = name,
            };
        }
    
        pub fn deinit(self: *Self) void {
            var current = self.head.*;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
        }
    
        pub fn push(self: *Self, job: Job(T)) !void {
            const newNode = try self.allocator.create(NodeType);
            newNode.* = NodeType{ .job = job };
    
            const prevTail = @atomicRmw(?*NodeType, &self.tail.*, .Xchg, newNode, .seq_cst);
            
            if (prevTail) |t| {
                t.*.next = newNode;
            }
        }
    
        pub fn pop(self: *Self) ?Job(T) {
            const oldHead = self.head.*;
            const nextNode = oldHead.?.next;
            if (nextNode == null) {
                return null; // Queue is empty
            }
    
            self.head.* = nextNode;
            if (nextNode) |n| {    
                const job = n.job;
        
                // Free the old head node
               // self.allocator.destroy(oldHead);
        
                return job;
            }
            
            return null;
        }
    
        pub fn stop(self: *Self) void {
            self.is_running.store(false, .seq_cst);
        }
    };
}

pub fn workerThread(comptime T: type, jobQueue: *JobQueue(T)) void {
    while (jobQueue.is_running.load(.seq_cst)) {
        if (jobQueue.pop()) |job| {
            job.execute(job.context);
        } else {
            // Yield to avoid busy-waiting when the queue is empty
            // std.os.yield();
        }
    }
}