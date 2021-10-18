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

    pub fn deinit(self: StyleSheet, allocator: *Allocator) void {
        for (self.style_rules) |style_rule| {
            style_rule.deinit(allocator);
        }
        allocator.free(self.style_rules);
    }
};

pub const StyleRule = struct {
    properties: []Property,
    selector: Selector,
    style_rules: []StyleRule,

    pub fn deinit(self: StyleRule, allocator: *Allocator) void {
        allocator.free(self.properties);
        for (self.style_rules) |style_stule| {
            style_stule.deinit(allocator);
        }
        allocator.free(self.style_rules);
    }
};

const Property = struct {
    name: []const u8,
    value: []const u8,
};

const Selector = []const u8;

const Context = struct {
    allocator: *Allocator,
    current_token: usize = 0,
    root: Root,
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
};

pub const ParserError = error{
    NotImplemented,
    OutOfMemory,
};

pub fn parse(allocator: *Allocator, tokenization: Tokenization) !Root {
    var root = Root{ .allocator = allocator, .style_sheet = undefined };

    var context = Context{ .allocator = allocator, .root = root, .source = tokenization.input, .tokens = tokenization.tokens };

    try parse_style_sheet(&context);
    return context.root;
}

fn parse_style_sheet(context: *Context) !void {
    var style_rules = try parse_style_rules(context);
    context.root.style_sheet = StyleSheet{ .style_rules = style_rules };
}

fn parse_style_rules(context: *Context) ![]StyleRule {
    var rules = ArrayList(StyleRule).init(context.allocator);
    errdefer rules.deinit();

    while (true) {
        const token = context.peek_token();
        if (token.type == .EndOfFile) {
            break;
        }
        var rule = try parse_style_rule(context);
        try rules.append(rule);
    }

    return rules.toOwnedSlice();
}

fn parse_selector(context: *Context) !Selector {
    var token = context.eat_token();
    var value = context.get_token_value(token);

    if (token.type != .Selector) {
        return error.NotImplemented;
    }

    return value;
}

fn parse_style_rule(context: *Context) ParserError!StyleRule {
    var selector = try parse_selector(context);

    var token = context.eat_token();
    assert(token.type == .BlockStart);

    var properties = ArrayList(Property).init(context.allocator);
    errdefer properties.deinit();

    var style_rules = ArrayList(StyleRule).init(context.allocator);
    errdefer style_rules.deinit();

    while (true) {
        token = context.peek_token();
        switch (token.type) {
            .PropertyName => {
                var property = try parse_property(context);
                try properties.append(property);
            },
            .Selector => {
                var style_rule = try parse_style_rule(context);
                try style_rules.append(style_rule);
            },
            .BlockEnd => {
                _ = context.eat_token();
                break;
            },
            else => return error.NotImplemented,
        }
    }

    return StyleRule{ .properties = properties.toOwnedSlice(), .selector = selector, .style_rules = style_rules.toOwnedSlice() };
}

fn parse_property(context: *Context) !Property {
    const property_name = context.eat_token();
    assert(property_name.type == .PropertyName);

    const property_value = context.eat_token();
    assert(property_value.type == .PropertyValue);

    var property = Property{
        .name = context.get_token_value(property_name),
        .value = context.get_token_value(property_value),
    };

    const token = context.eat_token();
    assert(token.type == .EndStatement);

    return property;
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
    try expectEqual(rule.properties.len, 2);
    try expectEqualStrings(rule.properties[0].name, "margin");
    try expectEqualStrings(rule.properties[0].value, "0px");
    try expectEqualStrings(rule.properties[1].name, "padding");
    try expectEqualStrings(rule.properties[1].value, "0px");
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
    try expectEqual(rule.properties.len, 1);
    try expectEqualStrings(rule.properties[0].name, "margin");
    try expectEqualStrings(rule.properties[0].value, "0px");

    try expectEqual(rule.style_rules.len, 1);
    const nested_rule = rule.style_rules[0];
    try expectEqualStrings(nested_rule.selector, "h1");
    try expectEqual(nested_rule.properties.len, 1);
    try expectEqualStrings(nested_rule.properties[0].name, "color");
    try expectEqualStrings(nested_rule.properties[0].value, "red");
}
