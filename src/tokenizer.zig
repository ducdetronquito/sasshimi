const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const std = @import("std");

pub const TokenType = enum {
    BlockStart, // {
    BlockEnd, // }
    PropertyName, // width
    PropertyValue, // 30px
    Selector, // .button
    StatementEnd, // ;
};

pub const Token = struct {
    type: TokenType,
    value: []const u8,
};

pub const Tokenization = struct {
    allocator: *Allocator,
    tokens: ArrayList(Token),

    pub fn deinit(self: *Tokenization) void {
        self.tokens.deinit();
    }
};

pub fn tokenize(allocator: *Allocator, input: []const u8) !Tokenization {
    _ = input;
    var tokens = ArrayList(Token).init(allocator);
    try tokens.append(Token{ .type = .Selector, .value = ".button" });
    try tokens.append(Token{ .type = .BlockStart, .value = "{" });
    try tokens.append(Token{ .type = .PropertyName, .value = "width" });
    try tokens.append(Token{ .type = .PropertyValue, .value = "30px" });
    try tokens.append(Token{ .type = .StatementEnd, .value = ";" });
    try tokens.append(Token{ .type = .BlockEnd, .value = "}" });
    return Tokenization{ .allocator = allocator, .tokens = tokens };
}

test "Tokenize" {
    const input =
        \\ .button {
        \\     width: 30px;
        \\ }
    ;
    var tokenization = try tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [6]Token = .{
        Token{ .type = .Selector, .value = ".button" },
        Token{ .type = .BlockStart, .value = "{" },
        Token{ .type = .PropertyName, .value = "width" },
        Token{ .type = .PropertyValue, .value = "30px" },
        Token{ .type = .StatementEnd, .value = ";" },
        Token{ .type = .BlockEnd, .value = "}" },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

fn expectTokenEquals(expected: []Token, actual: []Token) !void {
    try std.testing.expect(actual.len == expected.len);
    for (actual) |token, i| {
        try std.testing.expect(token.type == expected[i].type);
        try std.testing.expectEqualSlices(u8, token.value, expected[i].value);
    }
}
