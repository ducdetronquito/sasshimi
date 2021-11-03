const std = @import("std");
const compiler = @import("compiler.zig");

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.debug.print("No input provided.\nTry something like: zig build run -- \".button {{ margin: 0}}\"\n", .{});
        return;
    }
    const input = args[1];

    var output = try compiler.compile(allocator, input);
    std.debug.print("{s}", .{output});
}
