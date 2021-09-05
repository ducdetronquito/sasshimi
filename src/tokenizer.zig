const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const std = @import("std");

pub const TokenType = enum {
    BlockStart, // {
    BlockEnd, // }
    ClassSelector, // .button
    EndStatement, // ;
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
    PropertyNameLookup,
    PropertyName,
    ColonLookup,
    PropertyValueLookup,
    PropertyValue,
    EndStatementLookup,
    Start,
};

pub const Error = error {
    NotImplemented,
    ClassSelectorCanOnlyContainsAlphaChar,
    IdentifierCanOnlyContainsAlphaChar,
    NoCRLFBetweenPropertyValueAndSemicolon,
    OutOfMemory,
    PropertyNameCanOnlyContainsAlphaChar,
    PropertyValueCanOnlyContainsAlphaChar,
    PropertyValueCannotBeEmpty,
    PropertyValueCannotContainCRLF,
    PropertyValueMustEndWithASemicolon,
    UnexpectedCharacter,
    UnexpectedEndOfFile,
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

    pub fn tokenize(allocator: *Allocator, input: []const u8) Error!Tokenization
    {
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

    fn process_char(self: *Tokenizer, char: u8) Error!void {
        var result = switch(self.state) {
            .Start => self.on_start(char),
            .SawDot => self.on_dot(char),
            .Identifier => self.on_identifier(char),
            .SawOpenBracket => self.on_open_bracket(char),
            .PropertyNameLookup => self.on_property_name_lookup(char),
            .PropertyName => self.on_property_name(char),
            .ColonLookup => self.on_colon_lookup(char),
            .PropertyValueLookup => self.on_property_value_lookup(char),
            .PropertyValue => self.on_property_value(char),
            .EndStatementLookup => self.on_end_statement_lookup(char),
            .Done => {},
        };
        if (result) {
            self.pos += 1;
        }
        else |err| {
            std.debug.print("Error={}, State={}, Char: '{}'\n", .{err, self.state, char});
            return err;
        }
    }

    fn on_start(self: *Tokenizer, char: u8) Error!void {
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
            else => error.UnexpectedCharacter,
        };
    }

    fn on_dot(self: *Tokenizer, char: u8) Error!void {
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

    fn on_identifier(self: *Tokenizer, char: u8) Error!void {
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

    fn on_open_bracket(self: *Tokenizer, char: u8) Error!void {
        if (std.ascii.isAlpha(char)) {
            self.state = .PropertyName;
            try self.tokenization.tokens.append(Token { .type = .PropertyName, .start = self.pos });
            return;
        }
        if (std.ascii.isSpace(char)) {
            self.state = .PropertyNameLookup;
            return;
        }
        return switch(char) {
            '}' => {
                self.state = .Start;
                try self.tokenization.tokens.append(Token { .type = .BlockEnd, .start = self.pos, .end = self.pos + 1});
            },
            '\x00' => error.UnexpectedEndOfFile,
            else => error.NotImplemented,
        };
    }

    fn on_property_name_lookup(self: *Tokenizer, char: u8) Error!void {
        if (std.ascii.isSpace(char)) {
            return;
        }
        if (std.ascii.isAlpha(char)) {
            self.state = .PropertyName;
            try self.tokenization.tokens.append(Token { .type = .PropertyName, .start = self.pos });
            return;
        }
        return switch(char) {
            '}' => {
                self.state = .Start;
                try self.tokenization.tokens.append(Token { .type = .BlockEnd, .start = self.pos, .end = self.pos + 1});
            },
            '\x00' => error.UnexpectedEndOfFile,
            else => error.PropertyNameCanOnlyContainsAlphaChar,
        };
    }

    fn on_property_name(self: *Tokenizer, char: u8) Error!void {
        if (std.ascii.isAlpha(char) or char == '-') {
            return;
        }

        if (std.ascii.isSpace(char)) {
            self.state = .ColonLookup;
            try self.set_last_token_end();
            return;
        }

        return switch(char) {
            ':' => {
                self.state = .PropertyValueLookup;
                try self.set_last_token_end();
            },
            '\x00' => error.UnexpectedEndOfFile,
            else => error.PropertyNameCanOnlyContainsAlphaChar,
        };
    }

    fn on_colon_lookup(self: *Tokenizer, char: u8) Error!void {
        return switch(char) {
            ' ', '\t' => {},
            ':' => self.state = .PropertyValueLookup,
            else => error.UnexpectedCharacter,
        };
    }

    fn on_property_value_lookup(self: *Tokenizer, char: u8) Error!void {
        if (std.ascii.isAlNum(char)) {
            self.state = .PropertyValue;
            try self.tokenization.tokens.append(Token { .type = .PropertyValue, .start = self.pos });
            return;
        }

        return switch(char) {
            ' ', '\t' => {},
            ';' => error.PropertyValueCannotBeEmpty,
            else => error.PropertyValueCanOnlyContainsAlphaChar
        };
    }

    fn on_property_value(self: *Tokenizer, char: u8) Error!void {
        if (std.ascii.isAlNum(char)) {
            return;
        }
        return switch(char) {
            ';' => {
                self.state = .PropertyNameLookup;
                try self.set_last_token_end();
                try self.tokenization.tokens.append(Token { .type = .EndStatement, .start = self.pos, .end = self.pos + 1 });
            },
            ' ', '\t' => {
                self.state = .EndStatementLookup;
                try self.set_last_token_end();
            },
            '}' => error.PropertyValueMustEndWithASemicolon,
            '\r', '\n' => error.PropertyValueCannotContainCRLF,
            '\x00' => error.UnexpectedEndOfFile,
            else => error.UnexpectedCharacter,
        };
    }

    fn on_end_statement_lookup(self: *Tokenizer, char: u8) Error!void {
        return switch(char) {
            ' ', '\t' => {},
            ';' => {
                self.state = .PropertyNameLookup;
                try self.tokenization.tokens.append(Token { .type = .EndStatement, .start = self.pos, .end = self.pos + 1 });
            },
            '\r', '\n' => error.NoCRLFBetweenPropertyValueAndSemicolon,
            '\x00' => error.UnexpectedEndOfFile,
            else => error.UnexpectedCharacter,
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

test "Property name and value" {
    const input = ".button{margin:0;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [6]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7},
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 15, .end = 16 },
        Token{ .type = .EndStatement, .start = 16, .end = 17 },
        Token{ .type = .BlockEnd, .start = 17, .end = 18 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Whitespaces between open bracket and property name are skipped" {
    const input = ".button{ \r\n \t margin:0;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [6]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7},
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 14, .end = 20 },
        Token{ .type = .PropertyValue, .start = 21, .end = 22 },
        Token{ .type = .EndStatement, .start = 22, .end = 23 },
        Token{ .type = .BlockEnd, .start = 23, .end = 24 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Space and tabs between property name and colon are skipped" {
    const input = ".button{margin  \t :0;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [6]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7},
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 19, .end = 20 },
        Token{ .type = .EndStatement, .start = 20, .end = 21 },
        Token{ .type = .BlockEnd, .start = 21, .end = 22 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Space and tabs between colon and property value are skipped" {
    const input = ".button{margin: \t  0;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [6]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7},
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 19, .end = 20 },
        Token{ .type = .EndStatement, .start = 20, .end = 21 },
        Token{ .type = .BlockEnd, .start = 21, .end = 22 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Space and tabs between property value and semicolon are skipped" {
    const input = ".button{margin:0 \t  ;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [6]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7},
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 15, .end = 16 },
        Token{ .type = .EndStatement, .start = 20, .end = 21 },
        Token{ .type = .BlockEnd, .start = 21, .end = 22 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "No CRLF accepted between a property value and its semicolon" {
    const input = ".button{margin: 0\r\n;}";
    const failure = Tokenizer.tokenize(std.testing.allocator, input);
    try std.testing.expectError(error.PropertyValueCannotContainCRLF, failure);
}

test "Whitespaces after semicolon are skipped" {
    const input = ".button{margin:0;\r\n\t}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [6]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7},
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 15, .end = 16 },
        Token{ .type = .EndStatement, .start = 16, .end = 17 },
        Token{ .type = .BlockEnd, .start = 20, .end = 21 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Property value must end with a semicolon" {
    const input = ".button{margin: 0}";
    const failure =  Tokenizer.tokenize(std.testing.allocator, input);

    try std.testing.expectError(error.PropertyValueMustEndWithASemicolon, failure);
}

test "Property value cannot be empty only whitespaces" {
    const input = ".button{margin: \t  ;}";
    const failure = Tokenizer.tokenize(std.testing.allocator, input);

    try std.testing.expectError(error.PropertyValueCannotBeEmpty, failure);
}

test "Property value cannot be empty" {
    const input = ".button{margin:;}";
    const failure = Tokenizer.tokenize(std.testing.allocator, input);

    try std.testing.expectError(error.PropertyValueCannotBeEmpty, failure);
}

test "Multiple properties in a block" {
    const input = ".button{margin:0;padding:0;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [9]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7},
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 15, .end = 16 },
        Token{ .type = .EndStatement, .start = 16, .end = 17 },
        Token{ .type = .PropertyName, .start = 17, .end = 24 },
        Token{ .type = .PropertyValue, .start = 25, .end = 26 },
        Token{ .type = .EndStatement, .start = 26, .end = 27 },
        Token{ .type = .BlockEnd, .start = 27, .end = 28 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

fn expectTokenEquals(expected: []Token, actual: []Token) !void {
    try std.testing.expect(actual.len == expected.len);
    _ = expected;
    for (actual) |token, i| {
        try std.testing.expect(token.type == expected[i].type);
        try std.testing.expect(token.start == expected[i].start);
        try std.testing.expect(token.end == expected[i].end);
    }
}
