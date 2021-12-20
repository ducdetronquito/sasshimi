const Allocator = std.mem.Allocator;
const emitter = @import("emitter.zig");
const parser = @import("parser.zig");
const solver = @import("solver.zig");
const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;

pub fn compile(allocator: Allocator, input: []const u8) ![]u8 {
    var tokenization = try Tokenizer.tokenize(allocator, input);
    defer tokenization.deinit();

    var root = try parser.parse(allocator, tokenization);
    defer root.deinit();

    try solver.solve(allocator, root);

    const css = try emitter.emit(allocator, root);
    defer css.deinit();
    _ = css;

    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    for (css.style_rules) |style_rule, i| {
        if (i != 0) {
            try output.append('\n');
        }

        try output.appendSlice(style_rule.selector);
        try output.appendSlice(" {\n");
        for (style_rule.properties) |property| {
            try output.appendSlice("  ");
            try output.appendSlice(property.name);
            try output.append(':');
            for (property.value) |value_part| {
                try output.append(' ');
                try output.appendSlice(value_part);
            }
            try output.appendSlice(";\n");
        }
        try output.appendSlice("}\n");
    }
    return output.toOwnedSlice();
}

const expectEqualStrings = std.testing.expectEqualStrings;

test "Compile" {
    var output = try compile(std.testing.allocator, ".button{ margin: 0; padding:0; } h1{ color: red; }");
    defer std.testing.allocator.free(output);

    try expectEqualStrings(output,
        \\.button {
        \\  margin: 0;
        \\  padding: 0;
        \\}
        \\
        \\h1 {
        \\  color: red;
        \\}
        \\
    );
}

test "Compile - Nested rules" {
    var output = try compile(std.testing.allocator, ".button{ margin: 0; h1 { color: red; } }");
    defer std.testing.allocator.free(output);

    try expectEqualStrings(output,
        \\.button {
        \\  margin: 0;
        \\}
        \\
        \\.button h1 {
        \\  color: red;
        \\}
        \\
    );
}

test "Compile - Variable reference" {
    var output = try compile(std.testing.allocator, "$zig-orange: #f7a41d; .button { color: $zig-orange; }");
    defer std.testing.allocator.free(output);

    try expectEqualStrings(output,
        \\.button {
        \\  color: #f7a41d;
        \\}
        \\
    );
}

test "Compile - Property value list" {
    var output = try compile(std.testing.allocator, ".button { border: 1px solid; }");
    defer std.testing.allocator.free(output);

    try expectEqualStrings(output,
        \\.button {
        \\  border: 1px solid;
        \\}
        \\
    );
}
