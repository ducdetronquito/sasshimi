const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const Tokenization = tokenizer.Tokenization;
const Tokenizer = tokenizer.Tokenizer;

pub const Root = struct {
    allocator: *Allocator,
    style_sheet: StyleSheet,

    pub fn deinit(self: Root) void {
        self.style_sheet.deinit(self.allocator);
    }
};

const StyleSheet = struct {
    style_rules: []StyleRule,
    variables: []Variable,

    pub fn deinit(self: StyleSheet, allocator: *Allocator) void {
        for (self.style_rules) |style_rule| {
            style_rule.deinit(allocator);
        }
        allocator.free(self.style_rules);
        allocator.free(self.variables);
    }
};

pub const StyleRule = struct {
    properties: []Property,
    selector: Selector,
    style_rules: []StyleRule,
    variables: []Variable,

    pub fn deinit(self: StyleRule, allocator: *Allocator) void {
        for (self.properties) |property| {
            property.deinit(allocator);
        }
        allocator.free(self.properties);
        for (self.style_rules) |style_stule| {
            style_stule.deinit(allocator);
        }
        allocator.free(self.style_rules);
        allocator.free(self.variables);
    }
};

const ValueType = enum { String, Reference };

pub const Value = union(ValueType) {
    String: []const u8,
    Reference: []const u8,
};

const Property = struct {
    name: []const u8,
    value: []Value,

    pub fn deinit(self: Property, allocator: *Allocator) void {
        allocator.free(self.value);
    }
};

const Selector = []const u8;

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
};

const Context = struct {
    allocator: *Allocator,
    current_token: usize = 0,
    source: []const u8,
    tokens: []Token,

    pub inline fn eat_token(self: *Context) Token {
        var token = self.peek_token();
        self.current_token += 1;
        return token;
    }

    pub inline fn peek_token(self: *Context) Token {
        return self.tokens[self.current_token];
    }

    pub inline fn get_token_value(self: *Context, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }

    pub fn copy(self: *Context) Context {
        return Context{
            .allocator = self.allocator,
            .current_token = self.current_token,
            .source = self.source,
            .tokens = self.tokens,
        };
    }
};

pub const ParserError = error{ NotImplemented, OutOfMemory, PropertyValueCannotBeEmpty };

pub fn parse(allocator: *Allocator, tokenization: Tokenization) !Root {
    var context = Context{ .allocator = allocator, .source = tokenization.input, .tokens = tokenization.tokens };

    var style_sheet = try parse_style_sheet(&context);
    return Root{ .allocator = allocator, .style_sheet = style_sheet };
}

fn parse_style_sheet(context: *Context) !StyleSheet {
    var rules = ArrayList(StyleRule).init(context.allocator);
    errdefer rules.deinit();

    var variables = ArrayList(Variable).init(context.allocator);
    errdefer variables.deinit();

    while (true) {
        const token = context.peek_token();
        switch (token.type) {
            .VariableName => {
                var variable = try parse_variable(context);
                try variables.append(variable);
            },
            .Selector => {
                var nested_context = context.copy();
                var rule = try parse_style_rule(&nested_context, variables.items);
                context.current_token = nested_context.current_token;
                try rules.append(rule);
            },
            .EndOfFile => break,
            else => return error.NotImplemented,
        }
    }

    return StyleSheet{ .style_rules = rules.toOwnedSlice(), .variables = variables.toOwnedSlice() };
}

fn parse_variable(context: *Context) !Variable {
    var token = context.eat_token();
    assert(token.type == .VariableName);
    const name = context.get_token_value(token);

    token = context.eat_token();
    assert(token.type == .Value);
    const value = context.get_token_value(token);

    token = context.eat_token();
    assert(token.type == .EndStatement);

    return Variable{ .name = name, .value = value };
}

fn parse_selector(context: *Context) !Selector {
    var token = context.eat_token();
    var value = context.get_token_value(token);

    if (token.type != .Selector) {
        return error.NotImplemented;
    }

    return value;
}

fn parse_style_rule(context: *Context, parent_variables: []Variable) ParserError!StyleRule {
    var selector = try parse_selector(context);

    var token = context.eat_token();
    assert(token.type == .BlockStart);

    var properties = ArrayList(Property).init(context.allocator);
    errdefer properties.deinit();

    var style_rules = ArrayList(StyleRule).init(context.allocator);
    errdefer style_rules.deinit();

    var variables = ArrayList(Variable).init(context.allocator);
    errdefer variables.deinit();
    try variables.appendSlice(parent_variables);

    while (true) {
        token = context.peek_token();
        switch (token.type) {
            .VariableName => {
                var variable = try parse_variable(context);
                try variables.append(variable);
            },
            .PropertyName => {
                var property = try parse_property(context);
                try properties.append(property);
            },
            .Selector => {
                var nested_context = context.copy();
                var style_rule = try parse_style_rule(&nested_context, variables.items);
                context.current_token = nested_context.current_token;
                try style_rules.append(style_rule);
            },
            .BlockEnd => {
                _ = context.eat_token();
                break;
            },
            else => return error.NotImplemented,
        }
    }

    return StyleRule{ .properties = properties.toOwnedSlice(), .selector = selector, .style_rules = style_rules.toOwnedSlice(), .variables = variables.toOwnedSlice() };
}

fn parse_property(context: *Context) ParserError!Property {
    const property_name = context.eat_token();
    assert(property_name.type == .PropertyName);

    const property_value = context.peek_token();
    if (property_value.type == .EndStatement) {
        return error.PropertyValueCannotBeEmpty;
    }

    var value = ArrayList(Value).init(context.allocator);
    errdefer value.deinit();

    while (true) {
        var token = context.eat_token();
        switch (token.type) {
            .Value => {
                var content = context.get_token_value(token);
                if (content[0] == '$') {
                    try value.append(.{ .Reference = content });
                } else {
                    try value.append(.{ .String = content });
                }
            },
            .EndStatement => {
                return Property{
                    .name = context.get_token_value(property_name),
                    .value = value.toOwnedSlice(),
                };
            },
            else => unreachable, // Presence of at least an EndStatement token is ensured by the tokenizer.
        }
    }
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "Class selector" {
    const input = ".button{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    try expectEqual(root.style_sheet.style_rules.len, 1);
    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector, ".button");
    try expectEqual(rule.properties.len, 0);
    try expectEqual(rule.variables.len, 0);
}

test "Id selector" {
    const input = "#name{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    try expectEqual(root.style_sheet.style_rules.len, 1);
    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector, "#name");
    try expectEqual(rule.properties.len, 0);
    try expectEqual(rule.variables.len, 0);
}

test "Type selector" {
    const input = "h1{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    try expectEqual(root.style_sheet.style_rules.len, 1);
    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector, "h1");
    try expectEqual(rule.properties.len, 0);
    try expectEqual(rule.variables.len, 0);
}

test "Style rule with properties" {
    const input = ".button{ margin: 0px; padding: 0px; }";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    try expectEqual(root.style_sheet.style_rules.len, 1);
    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector, ".button");
    try expectEqual(rule.variables.len, 0);
    try expectEqual(rule.properties.len, 2);
    try expectEqualStrings(rule.properties[0].name, "margin");
    try expectEqualStrings(rule.properties[0].value[0].String, "0px");
    try expectEqualStrings(rule.properties[1].name, "padding");
    try expectEqualStrings(rule.properties[1].value[0].String, "0px");
}

test "Nested style rules" {
    const input = ".button{ margin: 0px; h1 { color: red; } }";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    try expectEqual(root.style_sheet.style_rules.len, 1);
    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector, ".button");
    try expectEqual(rule.variables.len, 0);
    try expectEqual(rule.properties.len, 1);
    try expectEqualStrings(rule.properties[0].name, "margin");
    //try expectEqualStrings(rule.properties[0].value[0], "0px");
    try expectEqualStrings(rule.properties[0].value[0].String, "0px");

    try expectEqual(rule.style_rules.len, 1);
    const nested_rule = rule.style_rules[0];
    try expectEqualStrings(nested_rule.selector, "h1");
    try expectEqual(nested_rule.variables.len, 0);
    try expectEqual(nested_rule.properties.len, 1);
    try expectEqualStrings(nested_rule.properties[0].name, "color");
    try expectEqualStrings(nested_rule.properties[0].value[0].String, "red");
}

test "Variables - Top level" {
    const input = "$zig-orange: #f7a41d;";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const variables = root.style_sheet.variables;
    try expectEqual(variables.len, 1);
    try expectEqualStrings(variables[0].name, "$zig-orange");
    try expectEqualStrings(variables[0].value, "#f7a41d");
}

test "Variables - Within style rule" {
    const input = ".button{ $zig-orange: #f7a41d; }";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector, ".button");
    try expectEqual(rule.variables.len, 1);
    try expectEqualStrings(rule.variables[0].name, "$zig-orange");
    try expectEqualStrings(rule.variables[0].value, "#f7a41d");
}

test "Variables - New scope inherits parent variables" {
    const input = "$zig-orange: #f7a41d; .button{ $my-color: $zig-orange; }";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector, ".button");
    try expectEqual(rule.variables.len, 2);
    try expectEqualStrings(rule.variables[0].name, "$zig-orange");
    try expectEqualStrings(rule.variables[0].value, "#f7a41d");
    try expectEqualStrings(rule.variables[1].name, "$my-color");
    try expectEqualStrings(rule.variables[1].value, "$zig-orange");
}

test "Variables - Shadowing in a child scope" {
    const input = "$zig-orange: #f7a41d; .button{ $zig-orange: #000000; }";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector, ".button");
    try expectEqual(rule.variables.len, 2);
    try expectEqualStrings(rule.variables[0].name, "$zig-orange");
    try expectEqualStrings(rule.variables[0].value, "#f7a41d");
    try expectEqualStrings(rule.variables[1].name, "$zig-orange");
    try expectEqualStrings(rule.variables[1].value, "#000000");
}

test "Variables - Don't go out of scope" {
    const input =
        \\$zig-orange: #f7a41d;
        \\.button{ $zig-orange: #000000; }
        \\$zig-blue: blue;
        \\h1 {}
    ;
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const top_level_variables = root.style_sheet.variables;
    try expectEqual(top_level_variables.len, 2);
    try expectEqualStrings(top_level_variables[0].name, "$zig-orange");
    try expectEqualStrings(top_level_variables[0].value, "#f7a41d");
    try expectEqualStrings(top_level_variables[1].name, "$zig-blue");
    try expectEqualStrings(top_level_variables[1].value, "blue");

    var first_scope_variables = root.style_sheet.style_rules[0].variables;
    try expectEqual(first_scope_variables.len, 2);
    try expectEqualStrings(first_scope_variables[0].name, "$zig-orange");
    try expectEqualStrings(first_scope_variables[0].value, "#f7a41d");
    try expectEqualStrings(first_scope_variables[1].name, "$zig-orange");
    try expectEqualStrings(first_scope_variables[1].value, "#000000");

    var second_scope_variables = root.style_sheet.style_rules[1].variables;
    try expectEqual(second_scope_variables.len, 2);
    try expectEqualStrings(second_scope_variables[0].name, "$zig-orange");
    try expectEqualStrings(second_scope_variables[0].value, "#f7a41d");
    try expectEqualStrings(second_scope_variables[1].name, "$zig-blue");
    try expectEqualStrings(second_scope_variables[1].value, "blue");
}

test "Property - Value cannot be only whitespaces" {
    const input = ".button{margin: \t  ;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    const failure = parse(std.testing.allocator, tokenization);
    try std.testing.expectError(error.PropertyValueCannotBeEmpty, failure);
}

test "Property - Value cannot be empty" {
    const input = ".button{margin:;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    const failure = parse(std.testing.allocator, tokenization);
    try std.testing.expectError(error.PropertyValueCannotBeEmpty, failure);
}

test "Property - Value list" {
    const input = ".button{border: 1px solid;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const property = root.style_sheet.style_rules[0].properties[0];
    try expectEqualStrings(property.name, "border");
    try expectEqualStrings(property.value[0].String, "1px");
    try expectEqualStrings(property.value[1].String, "solid");
}

test "Property - Value list" {
    const input = ".button{border: 1px solid;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    const property = root.style_sheet.style_rules[0].properties[0];
    try expectEqualStrings(property.name, "border");
    try expectEqualStrings(property.value[0].String, "1px");
    try expectEqualStrings(property.value[1].String, "solid");
}
