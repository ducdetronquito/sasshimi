const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const std = @import("std");

pub const TokenType = enum {
    BlockStart, // {
    BlockEnd, // }
    ClassSelector, // .button
    PropertyName, // margin
    PropertyValue, // 0px
};

pub const Token = struct {
    type: TokenType,
    start: usize = 0,
    end: usize = 0,
};

pub const Tokenization = struct {
    tokens: ArrayList(Token),

    pub fn init(allocator: *Allocator) Tokenization {
        return .{ .tokens = ArrayList(Token).init(allocator) };
    }

    pub fn deinit(self: *Tokenization) void {
        self.tokens.deinit();
    }
};


pub const TokenizerState = enum {
    Done,
    Identifier,
    SawDot,
    SawOpenBracket,
    Start,
};

pub const Tokenizer = struct {
    state: TokenizerState = .Start,
    pos: usize = 0,
    tokenization: Tokenization,

    fn init(allocator: *Allocator) Tokenizer {
        return .{ .state = .Start, .tokenization = Tokenization.init(allocator)};
    }

    fn deinit(self: *Tokenizer) void {
        self.state = .Start;
        self.tokenization.deinit();
    }

    pub fn tokenize(allocator: *Allocator, input: []const u8) !Tokenization
    {
        _ = input;
        var tokenizer = Tokenizer.init(allocator);
        errdefer tokenizer.deinit();

        for(input) |char|
        {
            try tokenizer.process_char(char);
        }

        if (tokenizer.state != .Done) {
            try tokenizer.process_char('\x00');
        }

        return tokenizer.tokenization;
    }

    fn process_char(self: *Tokenizer, char: u8) !void {
        switch(self.state) {
            .Start => try self.on_start(char),
            .SawDot => try self.on_dot(char),
            .Identifier => try self.on_identifier(char),
            .SawOpenBracket => try self.on_open_bracket(char),
            .Done => {},
        }
        self.pos += 1;
    }

    fn on_start(self: *Tokenizer, char: u8) !void {
        if (std.ascii.isSpace(char)) {
            return;
        }

        return switch(char) {
            '.' => self.state = .SawDot,
            '{' => {
                self.state = .SawOpenBracket;
                try self.tokenization.tokens.append(Token { .type = .BlockStart, .start = self.pos, .end = self.pos + 1});
            },
            '\x00' => self.state = .Done,
            else => {
                std.debug.print("Unexpected char: '{}'\n", .{char});
                return error.UnexpectedCharacter;
            }
        };
    }

    fn on_dot(self: *Tokenizer, char: u8) !void {
        if (std.ascii.isAlpha(char)) {
            try self.tokenization.tokens.append(Token{ .type = .ClassSelector, .start = self.pos });
            self.state = .Identifier;
            return;
        }
        return switch(char) {
            '\x00' => error.UnexpectedEndOfFile,
            else => error.ClassSelectorCanOnlyContainsAlphaChar,
        };
    }

    fn on_identifier(self: *Tokenizer, char: u8) !void {
        if (std.ascii.isAlpha(char)) {
            return;
        }

        if (std.ascii.isSpace(char)) {
            self.state = .Start;
            try self.set_last_token_end();
            return;
        }

        return switch(char) {
            '{' => {
                self.state = .SawOpenBracket;
                try self.set_last_token_end();
                try self.tokenization.tokens.append(Token { .type = .BlockStart, .start = self.pos, .end = self.pos + 1});
            },
            '\x00' => error.UnexpectedEndOfFile,
            else => error.IdentifierCanOnlyContainsAlphaChar,
        };
    }

    fn on_open_bracket(self: *Tokenizer, char: u8) !void {
        return switch(char) {
            '}' => {
                self.state = .Start;
                try self.tokenization.tokens.append(Token { .type = .BlockEnd, .start = self.pos, .end = self.pos + 1});
            },
            '\x00' => error.UnexpectedEndOfFile,
            else => error.BlockTokenizationNotImplementedYet,
        };
    }

    fn set_last_token_end(self: *Tokenizer) !void {
        var token = self.tokenization.tokens.pop();
        token.end = self.pos;
        try self.tokenization.tokens.append(token);
    }
};


test "Class identifier" {
    const input = ".button{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [3]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7},
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .BlockEnd, .start = 8, .end = 9 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Whitespaces between identifier and brackets are skipped" {
    const input = ".button  \t \r\n {}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [3]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7},
        Token{ .type = .BlockStart, .start = 14, .end = 15 },
        Token{ .type = .BlockEnd, .start = 15, .end = 16 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

fn expectTokenEquals(expected: []Token, actual: []Token) !void {
    try std.testing.expect(actual.len == expected.len);
    for (actual) |token, i| {
        try std.testing.expect(token.type == expected[i].type);
        try std.testing.expect(token.start == expected[i].start);
        try std.testing.expect(token.end == expected[i].end);
    }
}
