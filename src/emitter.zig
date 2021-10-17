const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const parser = @import("parser.zig");
const std = @import("std");

pub const Css = struct {
    allocator: *Allocator,
    style_rules: []StyleRule,

    pub fn deinit(self: Css) void {
        for (self.style_rules) |style_rule| {
            style_rule.deinit(self.allocator);
        }
        self.allocator.free(self.style_rules);
    }
};

const StyleRule = struct {
    selector: []u8,
    properties: []Property,

    pub fn deinit(self: StyleRule, allocator: *Allocator) void {
        allocator.free(self.selector);
        allocator.free(self.properties);
    }
};

const Property = struct {
    name: []const u8,
    value: []const u8,
};

const Context = struct {
    allocator: *Allocator,
    style_rules: ArrayList(StyleRule),

    pub fn init(allocator: *Allocator) Context {
        return Context{ .allocator = allocator, .style_rules = ArrayList(StyleRule).init(allocator) };
    }

    pub fn deinit(self: Context) void {
        self.style_rules.deinit();
    }
};

const Error = error{OutOfMemory};

pub fn emit(allocator: *Allocator, root: parser.Root) !Css {
    var context = Context.init(allocator);
    errdefer context.deinit();

    for (root.style_sheet.style_rules) |item| {
        try emit_style_rule(&context, item, null);
    }

    return Css{ .allocator = allocator, .style_rules = context.style_rules.toOwnedSlice() };
}

pub fn emit_style_rule(context: *Context, style_rule: parser.StyleRule, parent_selector: ?[]const u8) Error!void {
    var selector: []u8 = undefined;
    if (parent_selector != null) {
        selector = try std.mem.concat(context.allocator, u8, &[_][]const u8{ parent_selector.?, " ", style_rule.selector });
    } else {
        selector = try context.allocator.dupe(u8, style_rule.selector);
    }
    var properties = try emit_properties(context, style_rule);
    try context.style_rules.append(StyleRule{ .selector = selector, .properties = properties });

    for (style_rule.style_rules) |inner_rule| {
        try emit_style_rule(context, inner_rule, selector);
    }
}

pub fn emit_properties(context: *Context, style_rule: parser.StyleRule) Error![]Property {
    var properties = ArrayList(Property).init(context.allocator);
    errdefer properties.deinit();

    for (style_rule.properties) |property| {
        try properties.append(.{ .name = property.name, .value = property.value });
    }

    return properties.toOwnedSlice();
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const parse = @import("parser.zig").parse;
const Tokenizer = @import("tokenizer.zig").Tokenizer;

test "Properties" {
    const input = ".button{ margin: 0px; padding: 0px; }";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    var css = try emit(std.testing.allocator, root);
    defer css.deinit();

    try expectEqual(css.style_rules.len, 1);
    const style_rule = css.style_rules[0];
    try expectEqualStrings(style_rule.selector, ".button");
    try expectEqual(style_rule.properties.len, 2);
    try expectEqualStrings(style_rule.properties[0].name, "margin");
    try expectEqualStrings(style_rule.properties[0].value, "0px");
    try expectEqualStrings(style_rule.properties[1].name, "padding");
    try expectEqualStrings(style_rule.properties[1].value, "0px");
}

test "Nested blocks" {
    const input = ".button{ margin: 0px; h1 { color: red; } }";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var root = try parse(std.testing.allocator, tokenization);
    defer root.deinit();

    var css = try emit(std.testing.allocator, root);
    defer css.deinit();

    try expectEqual(css.style_rules.len, 2);

    var parent_rule = css.style_rules[0];
    try expectEqualStrings(parent_rule.selector, ".button");
    try expectEqual(parent_rule.properties.len, 1);
    try expectEqualStrings(parent_rule.properties[0].name, "margin");
    try expectEqualStrings(parent_rule.properties[0].value, "0px");

    var descendant_rule = css.style_rules[1];
    try expectEqualStrings(descendant_rule.selector, ".button h1");
    try expectEqual(descendant_rule.properties.len, 1);
    try expectEqualStrings(descendant_rule.properties[0].name, "color");
    try expectEqualStrings(descendant_rule.properties[0].value, "red");
}
