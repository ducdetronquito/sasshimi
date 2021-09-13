const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const Tokenizer = tokenizer.Tokenizer;

pub const Root = struct {
    style_sheet: StyleSheet,
};

pub const StyleSheet = struct {
    style_rules: []StyleRule,
};

pub const StyleRule = struct {
    properties: []Property,
    selector: Selector,
};

pub const Property = struct {
    name: []const u8,
    value: []const u8,
};

pub const SelectorType = enum {
    ClassSelector,
    IdSelector,
    TypeSelector,
};

pub const Selector = union(SelectorType) {
    ClassSelector: []const u8,
    IdSelector: []const u8,
    TypeSelector: []const u8,
};

const Context = struct {
    allocator: *Allocator,
    current_token: usize = 0,
    root: Root,
    source: []const u8,
    tokens: []Token,

    pub fn eat_token(self: *Context) Token {
        var token = self.tokens[self.current_token];
        self.current_token += 1;
        return token;
    }

    pub fn get_token_value(self: *Context, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }
};

pub fn parse(allocator: *Allocator, input: []const u8) !Root {
    var tokenization = try Tokenizer.tokenize(allocator, input);

    var root = Root{ .style_sheet = undefined };

    var context = Context{ .allocator = allocator, .root = root, .source = input, .tokens = tokenization.tokens.toOwnedSlice() };
    defer allocator.free(context.tokens);

    try parse_style_sheet(&context);
    return context.root;
}

fn parse_style_sheet(context: *Context) !void {
    var style_rules = try parse_style_rules(context);
    context.root.style_sheet = StyleSheet{ .style_rules = style_rules };
}

fn parse_style_rules(context: *Context) ![]StyleRule {
    var rules = ArrayList(StyleRule).init(context.allocator);
    var rule = try parse_style_rule(context);
    try rules.append(rule);
    return rules.toOwnedSlice();
}

fn parse_style_rule(context: *Context) !StyleRule {
    var token = context.eat_token();
    var selector: Selector = switch (token.type) {
        .ClassSelector => .{ .ClassSelector = context.get_token_value(token) },
        .IdSelector => .{ .IdSelector = context.get_token_value(token) },
        .TypeSelector => .{ .TypeSelector = context.get_token_value(token) },
        else => return error.NotImplemented,
    };

    var properties = try parse_properties(context);
    return StyleRule{ .properties = properties, .selector = selector };
}

fn parse_properties(context: *Context) ![]Property {
    var token = context.eat_token();
    assert(token.type == .BlockStart);

    var properties = ArrayList(Property).init(context.allocator);
    while (true) {
        token = context.eat_token();
        if (token.type == .BlockEnd) {
            break;
        }

        const property_value = context.eat_token();
        try properties.append(.{
            .name = context.get_token_value(token),
            .value = context.get_token_value(property_value),
        });

        const end_statement = context.eat_token();
        _ = end_statement;
    }
    return properties.toOwnedSlice();
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "Class selector" {
    const input = ".button{}";
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root = try parse(&arena.allocator, input);

    try expectEqual(root.style_sheet.style_rules.len, 1);
    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector.ClassSelector, "button");
    try expectEqual(rule.properties.len, 0);
}

test "Id selector" {
    const input = "#name{}";
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root = try parse(&arena.allocator, input);

    try expectEqual(root.style_sheet.style_rules.len, 1);
    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector.IdSelector, "name");
    try expectEqual(rule.properties.len, 0);
}

test "Type selector" {
    const input = "h1{}";
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root = try parse(&arena.allocator, input);

    try expectEqual(root.style_sheet.style_rules.len, 1);
    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector.TypeSelector, "h1");
    try expectEqual(rule.properties.len, 0);
}

test "Style rule with properties" {
    const input = ".button{ margin: 0px; padding: 0px; }";
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root = try parse(&arena.allocator, input);

    try expectEqual(root.style_sheet.style_rules.len, 1);
    const rule = root.style_sheet.style_rules[0];
    try expectEqualStrings(rule.selector.ClassSelector, "button");
    try expectEqual(rule.properties.len, 2);
    try expectEqualStrings(rule.properties[0].name, "margin");
    try expectEqualStrings(rule.properties[0].value, "0px");
    try expectEqualStrings(rule.properties[1].name, "padding");
    try expectEqualStrings(rule.properties[1].value, "0px");
}
