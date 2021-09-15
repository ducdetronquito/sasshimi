const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const std = @import("std");

pub const TokenType = enum {
    BlockStart, // {
    BlockEnd, // }
    ClassSelector, // .button
    EndStatement, // ;
    IdSelector, // #name
    PropertyName, // margin
    PropertyValue, // 0px
    TypeSelector, // h1
    VariableName, // zig-orange
    VariableValue, // #f7a41d
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
    PropertyColonLookup,
    PropertyName,
    PropertySemicolonLookup,
    PropertyValue,
    PropertyValueLookup,
    SawDot,
    StartBlock,
    SawSharp,
    Selector,
    SelectorLookup,
    Start,
};

pub const Error = error{
    NotImplemented,
    ClassSelectorCanOnlyContainsAlphaChar,
    IdentifierCanOnlyContainsAlphaChar,
    IdSelectorCanOnlyContainsAlphaChar,
    NoCRLFBetweenPropertyValueAndSemicolon,
    OutOfMemory,
    PropertyNameCanOnlyContainsAlphaChar,
    PropertyValueCanOnlyContainsAlphaChar,
    PropertyValueCannotBeEmpty,
    PropertyValueCannotContainCRLF,
    PropertyValueMustEndWithASemicolon,
    UnexpectedCharacter,
    UnexpectedEndOfFile,
    VariableNameCanOnlyContainsAlphaChar,
    VariableNameCannotContainCRLF,
    VariableValueCannotContainCRLF,
};

pub const Tokenizer = struct {
    current_char: u8 = '\x00',
    input: []const u8,
    pos: usize = 0,
    state: TokenizerState = .Start,
    tokenization: Tokenization,

    fn init(allocator: *Allocator, input: []const u8) Tokenizer {
        return .{ .input = input, .state = .Start, .tokenization = Tokenization.init(allocator) };
    }

    fn deinit(self: *Tokenizer) void {
        self.state = .Start;
        self.current_char = '\x00';
        self.tokenization.deinit();
    }

    pub fn tokenize(allocator: *Allocator, input: []const u8) Error!Tokenization {
        var tokenizer = Tokenizer.init(allocator, input);
        errdefer tokenizer.deinit();

        while (tokenizer.pos < tokenizer.input.len) {
            tokenizer.current_char = tokenizer.input[tokenizer.pos];
            try tokenizer.next();
        }

        tokenizer.current_char = '\x00';
        try tokenizer.next();

        return tokenizer.tokenization;
    }

    inline fn next(self: *Tokenizer) Error!void {
        var result = switch (self.state) {
            .Done => {},
            .PropertyColonLookup => self.on_property_colon_lookup(),
            .PropertyName => self.on_property_name(),
            .PropertySemicolonLookup => self.on_property_semicolon_lookup(),
            .PropertyValue => self.on_property_value(),
            .PropertyValueLookup => self.on_property_value_lookup(),
            .SawDot => self.on_dot(),
            .StartBlock => self.on_start_block(),
            .SawSharp => self.on_sharp(),
            .Selector => self.on_selector(),
            .SelectorLookup => self.on_selector_lookup(),
            .Start => self.on_start(),
        };
        if (result) {
            self.pos += 1;
        } else |err| {
            std.debug.print("Error={}, State={}, Char: '{}'\n", .{ err, self.state, self.current_char });
            return err;
        }
    }

    fn on_start(self: *Tokenizer) Error!void {
        self.skipSpace();

        if (isIdentifier(self.current_char)) {
            self.state = .Selector;
            try self.tokenization.tokens.append(Token{ .type = .TypeSelector, .start = self.pos });
            return;
        }

        return switch (self.current_char) {
            '.' => self.state = .SawDot,
            '#' => self.state = .SawSharp,
            '$' => {
                try self.readVariable();
            },
            '\x00' => self.state = .Done,
            else => error.UnexpectedCharacter,
        };
    }

    fn on_selector_lookup(self: *Tokenizer) Error!void {
        self.skipSpace();

        if (isIdentifier(self.current_char)) {
            self.state = .Selector;
            try self.tokenization.tokens.append(Token{ .type = .TypeSelector, .start = self.pos });
            return;
        }

        return switch (self.current_char) {
            '.' => self.state = .SawDot,
            '#' => self.state = .SawSharp,
            '{' => {
                self.state = .StartBlock;
                try self.tokenization.tokens.append(Token{ .type = .BlockStart, .start = self.pos, .end = self.pos + 1 });
            },
            '\x00' => self.state = .Done,
            else => error.UnexpectedCharacter,
        };
    }

    fn on_dot(self: *Tokenizer) Error!void {
        if (isIdentifier(self.current_char)) {
            try self.tokenization.tokens.append(Token{ .type = .ClassSelector, .start = self.pos });
            self.state = .Selector;
            return;
        }
        return switch (self.current_char) {
            '\x00' => error.UnexpectedEndOfFile,
            else => error.ClassSelectorCanOnlyContainsAlphaChar,
        };
    }

    fn on_sharp(self: *Tokenizer) Error!void {
        if (isIdentifier(self.current_char)) {
            try self.tokenization.tokens.append(Token{ .type = .IdSelector, .start = self.pos });
            self.state = .Selector;
            return;
        }
        return switch (self.current_char) {
            '\x00' => error.UnexpectedEndOfFile,
            else => error.IdSelectorCanOnlyContainsAlphaChar,
        };
    }

    fn on_selector(self: *Tokenizer) Error!void {
        self.readWhile(isIdentifier);

        if (std.ascii.isSpace(self.current_char)) {
            try self.close_token_and_move_to(.SelectorLookup);
            return;
        }

        return switch (self.current_char) {
            '{' => {
                try self.close_token_and_move_to(.StartBlock);
                try self.tokenization.tokens.append(Token{ .type = .BlockStart, .start = self.pos, .end = self.pos + 1 });
            },
            '\x00' => error.UnexpectedEndOfFile,
            else => error.IdentifierCanOnlyContainsAlphaChar,
        };
    }

    fn on_start_block(self: *Tokenizer) Error!void {
        self.skipSpace();

        if (isIdentifier(self.current_char)) {
            self.state = .PropertyName;
            try self.tokenization.tokens.append(Token{ .type = .PropertyName, .start = self.pos });
            return;
        }
        return switch (self.current_char) {
            '$' => try self.readVariable(),
            '}' => {
                self.state = .SelectorLookup;
                try self.tokenization.tokens.append(Token{ .type = .BlockEnd, .start = self.pos, .end = self.pos + 1 });
            },
            '\x00' => error.UnexpectedEndOfFile,
            else => error.NotImplemented,
        };
    }

    fn on_property_name(self: *Tokenizer) Error!void {
        self.readWhile(isIdentifier);

        if (std.ascii.isSpace(self.current_char)) {
            try self.close_token_and_move_to(.PropertyColonLookup);
            return;
        }

        return switch (self.current_char) {
            ':' => {
                try self.close_token_and_move_to(.PropertyValueLookup);
            },
            '\x00' => error.UnexpectedEndOfFile,
            else => error.PropertyNameCanOnlyContainsAlphaChar,
        };
    }

    fn on_property_colon_lookup(self: *Tokenizer) Error!void {
        self.skipBlank();
        return switch (self.current_char) {
            ':' => self.state = .PropertyValueLookup,
            else => error.UnexpectedCharacter,
        };
    }

    fn on_property_value_lookup(self: *Tokenizer) Error!void {
        self.skipBlank();

        if (isIdentifier(self.current_char)) {
            self.state = .PropertyValue;
            try self.tokenization.tokens.append(Token{ .type = .PropertyValue, .start = self.pos });
            return;
        }

        return switch (self.current_char) {
            ';' => error.PropertyValueCannotBeEmpty,
            else => error.PropertyValueCanOnlyContainsAlphaChar,
        };
    }

    fn on_property_value(self: *Tokenizer) Error!void {
        self.readWhile(isIdentifier);

        return switch (self.current_char) {
            ';' => {
                try self.close_token_and_move_to(.StartBlock);
                try self.tokenization.tokens.append(Token{ .type = .EndStatement, .start = self.pos, .end = self.pos + 1 });
            },
            ' ', '\t' => {
                try self.close_token_and_move_to(.PropertySemicolonLookup);
            },
            '}' => error.PropertyValueMustEndWithASemicolon,
            '\r', '\n' => error.PropertyValueCannotContainCRLF,
            '\x00' => error.UnexpectedEndOfFile,
            else => error.UnexpectedCharacter,
        };
    }

    fn on_property_semicolon_lookup(self: *Tokenizer) Error!void {
        self.skipBlank();
        return switch (self.current_char) {
            ';' => {
                self.state = .StartBlock;
                try self.tokenization.tokens.append(Token{ .type = .EndStatement, .start = self.pos, .end = self.pos + 1 });
            },
            '\r', '\n' => error.NoCRLFBetweenPropertyValueAndSemicolon,
            '\x00' => error.UnexpectedEndOfFile,
            else => error.UnexpectedCharacter,
        };
    }

    fn readVariable(self: *Tokenizer) Error!void {
        self.pos += 1;
        self.current_char = self.input[self.pos];
        try self.readVariableName();
        try self.readVariableValue();
    }

    fn readVariableName(self: *Tokenizer) Error!void {
        if (!isIdentifier(self.current_char)) {
            return error.VariableNameCanOnlyContainsAlphaChar;
        }

        try self.tokenization.tokens.append(Token{ .type = .VariableName, .start = self.pos });
        self.readWhile(isIdentifier);
        try self.close_token();

        self.skipBlank();

        return switch (self.current_char) {
            ':' => self.pos += 1,
            '\r', '\n' => error.VariableNameCannotContainCRLF,
            '\x00' => error.UnexpectedEndOfFile,
            else => error.UnexpectedCharacter,
        };
    }

    fn readVariableValue(self: *Tokenizer) Error!void {
        self.skipBlank();

        try self.tokenization.tokens.append(Token{ .type = .VariableValue, .start = self.pos });
        self.readWhile(isVariableValue);

        self.skipBlank();

        return switch (self.current_char) {
            ';' => {
                try self.close_token();
                try self.tokenization.tokens.append(Token{ .type = .EndStatement, .start = self.pos, .end = self.pos + 1 });
            },
            '\r', '\n' => error.VariableValueCannotContainCRLF,
            '\x00' => error.UnexpectedEndOfFile,
            else => error.UnexpectedCharacter,
        };
    }

    fn skipBlank(self: *Tokenizer) callconv(.Inline) void {
        return self.readWhile(std.ascii.isBlank);
    }

    fn skipSpace(self: *Tokenizer) callconv(.Inline) void {
        return self.readWhile(std.ascii.isSpace);
    }

    fn readWhile(self: *Tokenizer, condition: fn (char: u8) bool) callconv(.Inline) void {
        for (self.input[self.pos..]) |char| {
            if (!condition(char)) {
                self.current_char = char;
                return;
            }
            self.pos += 1;
        }
    }

    fn isIdentifier(char: u8) bool {
        return std.ascii.isAlNum(char) or char == '-' or char == '_';
    }

    fn isVariableValue(char: u8) bool {
        return char != ';' and char != '\r' and char != '\n' and char != '\x00';
    }

    fn close_token(self: *Tokenizer) callconv(.Inline) !void {
        var token = self.tokenization.tokens.pop();
        token.end = self.pos;
        try self.tokenization.tokens.append(token);
    }
    fn close_token_and_move_to(self: *Tokenizer, state: TokenizerState) callconv(.Inline) !void {
        try self.close_token();
        self.state = state;
    }
};

test "Class selector" {
    const input = ".button{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [3]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .BlockEnd, .start = 8, .end = 9 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Class selector" {
    const input = ".big-button{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [3]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 11 },
        Token{ .type = .BlockStart, .start = 11, .end = 12 },
        Token{ .type = .BlockEnd, .start = 12, .end = 13 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Type selector" {
    const input = "h1{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [3]Token = .{
        Token{ .type = .TypeSelector, .start = 0, .end = 2 },
        Token{ .type = .BlockStart, .start = 2, .end = 3 },
        Token{ .type = .BlockEnd, .start = 3, .end = 4 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Id selector" {
    const input = "#name{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [3]Token = .{
        Token{ .type = .IdSelector, .start = 1, .end = 5 },
        Token{ .type = .BlockStart, .start = 5, .end = 6 },
        Token{ .type = .BlockEnd, .start = 6, .end = 7 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Whitespaces between identifier and brackets are skipped" {
    const input = ".button  \t \r\n {}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [3]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7 },
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
        Token{ .type = .ClassSelector, .start = 1, .end = 7 },
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
        Token{ .type = .ClassSelector, .start = 1, .end = 7 },
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
        Token{ .type = .ClassSelector, .start = 1, .end = 7 },
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
        Token{ .type = .ClassSelector, .start = 1, .end = 7 },
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
        Token{ .type = .ClassSelector, .start = 1, .end = 7 },
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
        Token{ .type = .ClassSelector, .start = 1, .end = 7 },
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
    const failure = Tokenizer.tokenize(std.testing.allocator, input);

    try std.testing.expectError(error.PropertyValueMustEndWithASemicolon, failure);
}

test "Property value cannot be whitespaces" {
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
        Token{ .type = .ClassSelector, .start = 1, .end = 7 },
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

test "Variable" {
    const input = "$zig-orange:#f7a41d;";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [3]Token = .{
        Token{ .type = .VariableName, .start = 1, .end = 11 },
        Token{ .type = .VariableValue, .start = 12, .end = 19 },
        Token{ .type = .EndStatement, .start = 19, .end = 20 },
    };
    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Variable - Space and tabs between variable name and colon are skipped" {
    const input = "$zig-orange \t : #f7a41d;";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [3]Token = .{
        Token{ .type = .VariableName, .start = 1, .end = 11 },
        Token{ .type = .VariableValue, .start = 16, .end = 23 },
        Token{ .type = .EndStatement, .start = 23, .end = 24 },
    };
    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Variable - Space and tabs between variable value and semicolon are part of the variable value" {
    const input = "$zig-orange: #f7a41d \t ;";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [3]Token = .{
        Token{ .type = .VariableName, .start = 1, .end = 11 },
        Token{ .type = .VariableValue, .start = 13, .end = 23 },
        Token{ .type = .EndStatement, .start = 23, .end = 24 },
    };

    try expectTokenEquals(&expected, tokenization.tokens.items);
}

test "Variable - Within a block" {
    const input = ".button{ $zig-orange: #f7a41d;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [6]Token = .{
        Token{ .type = .ClassSelector, .start = 1, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .VariableName, .start = 10, .end = 20 },
        Token{ .type = .VariableValue, .start = 22, .end = 29 },
        Token{ .type = .EndStatement, .start = 29, .end = 30 },
        Token{ .type = .BlockEnd, .start = 30, .end = 31 },
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
