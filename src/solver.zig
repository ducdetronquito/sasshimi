const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const parser = @import("parser.zig");
const std = @import("std");
const tokenizer = @import("tokenizer.zig");

pub fn solve(allocator: *Allocator, root: parser.Root) !void {
    _ = allocator;
    var variable_context = StringHashMap([]const u8).init(allocator);
    defer variable_context.deinit();

    for (root.style_sheet.variables) |*variable| {
        if (variable.value[0] == '$') {
            var target_value = variable_context.get(variable.value) orelse {
                std.debug.print("Variable '{s}' reference an undefined variable '{s}'\n", .{ variable.name, variable.value });
                return error.UndefinedVariable;
            };
            variable.value = target_value;
        }
        try variable_context.put(variable.name, variable.value);
    }
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "Top level - Undefined variable" {
    const input = "$zig-orange: $my-color;";
    var tokenization = try tokenizer.Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parser.parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const failure = solve(std.testing.allocator, root);
    try expectError(error.UndefinedVariable, failure);
}

test "Top level - Undefined variable due to bad order" {
    const input = "$my-color: $zig-orange; $zig-orange: #f7a41d;";
    var tokenization = try tokenizer.Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parser.parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const failure = solve(std.testing.allocator, root);
    try expectError(error.UndefinedVariable, failure);
}

test "Solve two top level variables" {
    const input = "$zig-orange: #f7a41d; $my-color: $zig-orange;";
    var tokenization = try tokenizer.Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parser.parse(std.testing.allocator, tokenization);
    defer root.deinit();

    try solve(std.testing.allocator, root);

    try expectEqual(root.style_sheet.style_rules.len, 0);
    try expectEqual(root.style_sheet.variables.len, 2);
    const variables = root.style_sheet.variables;
    try expectEqualStrings(variables[0].name, "$zig-orange");
    try expectEqualStrings(variables[0].value, "#f7a41d");
    try expectEqualStrings(variables[1].name, "$my-color");
    try expectEqualStrings(variables[1].value, "#f7a41d");
}
