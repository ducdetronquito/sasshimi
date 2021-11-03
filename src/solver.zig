const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const std = @import("std");
const tokenizer = @import("tokenizer.zig");

pub const SolverError = error{UndefinedVariable};

fn get_value(name: []const u8, variables: []parser.Variable) ?[]const u8 {
    if (variables.len == 0) {
        return null;
    }

    var i = variables.len - 1;
    while (i >= 0) {
        const variable = variables[i];
        if (std.mem.eql(u8, variable.name, name)) {
            return variable.value;
        }
        i -= 1;
    }
    return null;
}

pub fn solve(allocator: *Allocator, root: parser.Root) SolverError!void {
    _ = allocator;

    try solve_variables(root.style_sheet.variables);

    for (root.style_sheet.style_rules) |style_rule| {
        try solve_style_rule(style_rule);
    }
}

fn solve_style_rule(style_rule: parser.StyleRule) SolverError!void {
    try solve_variables(style_rule.variables);

    for (style_rule.properties) |*property| {
        if (property.value[0] == '$') {
            var target_value = get_value(property.value, style_rule.variables) orelse {
                std.debug.print("Property '{s}' reference an undefined variable '{s}'\n", .{ property.name, property.value });
                return error.UndefinedVariable;
            };
            property.value = target_value;
        }
    }

    for (style_rule.style_rules) |inner_style_rule| {
        try solve_style_rule(inner_style_rule);
    }
}

fn solve_variables(variables: []parser.Variable) SolverError!void {
    for (variables) |*variable, i| {
        if (variable.value[0] == '$') {
            var target_value = get_value(variable.value, variables[0..i]) orelse {
                std.debug.print("Variable '{s}' reference an undefined variable '{s}'\n", .{ variable.name, variable.value });
                return error.UndefinedVariable;
            };
            variable.value = target_value;
        }
    }
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "Variable Reference" {
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

test "Variable Reference - Reference variable from parent scope" {
    const input = "$zig-orange: #f7a41d; .button{ $my-color: $zig-orange; }";
    var tokenization = try tokenizer.Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parser.parse(std.testing.allocator, tokenization);
    defer root.deinit();

    try solve(std.testing.allocator, root);

    try expectEqual(root.style_sheet.variables.len, 1);
    const variables = root.style_sheet.variables;
    try expectEqualStrings(variables[0].name, "$zig-orange");
    try expectEqualStrings(variables[0].value, "#f7a41d");

    const rule = root.style_sheet.style_rules[0];
    try expectEqual(rule.variables.len, 2);
    try expectEqualStrings(rule.variables[0].name, "$zig-orange");
    try expectEqualStrings(rule.variables[0].value, "#f7a41d");
    try expectEqualStrings(rule.variables[1].name, "$my-color");
    try expectEqualStrings(rule.variables[1].value, "#f7a41d");
}

test "Variable Reference - Reference as property value" {
    const input = "$zig-orange: #f7a41d; .button { color: $zig-orange; }";
    var tokenization = try tokenizer.Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parser.parse(std.testing.allocator, tokenization);
    defer root.deinit();

    try solve(std.testing.allocator, root);

    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.properties[0].name, "color");
    try expectEqualStrings(rule.properties[0].value, "#f7a41d");
}

test "Variable Reference - Undefined top level reference" {
    const input = "$zig-orange: $my-color;";
    var tokenization = try tokenizer.Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parser.parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const failure = solve(std.testing.allocator, root);
    try expectError(error.UndefinedVariable, failure);
}

test "Variable Reference - Undefined top level reference due to bad order" {
    const input = "$my-color: $zig-orange; $zig-orange: #f7a41d;";
    var tokenization = try tokenizer.Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parser.parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const failure = solve(std.testing.allocator, root);
    try expectError(error.UndefinedVariable, failure);
}
