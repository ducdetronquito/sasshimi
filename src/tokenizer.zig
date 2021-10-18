const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const std = @import("std");

pub const TokenType = enum {
    BlockStart, // {
    BlockEnd, // }
    EndOfFile,
    EndStatement, // ;
    PropertyName, // margin
    PropertyValue, // 0px
    Selector, // h1, .button, #name
    VariableName, // zig-orange
    VariableValue, // #f7a41d
};

pub const Token = struct {
    type: TokenType,
    start: usize = 0,
    end: usize = 0,
};

pub const Tokenization = struct {
    allocator: *Allocator,
    tokens: []Token,
    input: []const u8,

    pub fn init(allocator: *Allocator, input: []const u8, tokens: []Token) Tokenization {
        return .{ .allocator = allocator, .input = input, .tokens = tokens };
    }

    pub fn deinit(self: *Tokenization) void {
        self.allocator.free(self.tokens);
    }
};

pub const TokenizerState = enum {
    Done,
    StartBlock,
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
    PropertyNameCannotContainCRLF,
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
    tokens: ArrayList(Token),

    fn init(allocator: *Allocator, input: []const u8) Tokenizer {
        return .{ .input = input, .state = .Start, .tokens = ArrayList(Token).init(allocator) };
    }

    fn deinit(self: *Tokenizer) void {
        self.state = .Start;
        self.current_char = '\x00';
        self.tokens.deinit();
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
        try tokenizer.tokens.append(.{ .type = .EndOfFile, .start = tokenizer.pos - 1, .end = tokenizer.pos });
        return Tokenization.init(allocator, input, tokenizer.tokens.toOwnedSlice());
    }

    inline fn next(self: *Tokenizer) Error!void {
        var result = switch (self.state) {
            .Done => {},
            .StartBlock => self.on_start_block(),
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

        if (isSelectorStart(self.current_char)) {
            self.state = .Selector;
            try self.tokens.append(Token{ .type = .Selector, .start = self.pos });
            return;
        }

        return switch (self.current_char) {
            '$' => {
                try self.readVariable();
            },
            '\x00' => self.state = .Done,
            else => error.UnexpectedCharacter,
        };
    }

    fn on_selector_lookup(self: *Tokenizer) Error!void {
        self.skipSpace();

        if (isSelectorStart(self.current_char)) {
            self.state = .Selector;
            try self.tokens.append(Token{ .type = .Selector, .start = self.pos });
            return;
        }

        return switch (self.current_char) {
            '{' => {
                self.state = .StartBlock;
                try self.tokens.append(Token{ .type = .BlockStart, .start = self.pos, .end = self.pos + 1 });
            },
            '\x00' => self.state = .Done,
            else => error.UnexpectedCharacter,
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
                try self.tokens.append(Token{ .type = .BlockStart, .start = self.pos, .end = self.pos + 1 });
            },
            '\x00' => error.UnexpectedEndOfFile,
            else => error.IdentifierCanOnlyContainsAlphaChar,
        };
    }

    fn on_start_block(self: *Tokenizer) Error!void {
        self.skipSpace();

        if (self.current_char == '$') {
            try self.readVariable();
            return;
        }

        if (isIdentifier(self.current_char) or isSelectorStart(self.current_char)) {
            try self.tokens.append(Token{ .type = undefined, .start = self.pos, .end = undefined });
            self.readWhile(isIdentifier);
            try self.close_token();
            self.skipSpace();
            switch (self.current_char) {
                ':' => {
                    var token = self.get_last_token();
                    token.type = .PropertyName;
                    self.pos += 1;

                    try self.readPropertyValue();
                    token = self.get_last_token();
                    return;
                },
                '{' => {
                    var token = self.get_last_token();
                    token.type = .Selector;
                    try self.tokens.append(Token{ .type = .BlockStart, .start = self.pos, .end = self.pos + 1 });
                    return;
                },
                ',', '+', '>' => {
                    //Last Token is a Selector, stay on state BlockStart
                    return error.NotImplemented;
                },
                else => {
                    return error.NotImplemented;
                },
            }
        }

        return switch (self.current_char) {
            '}' => {
                self.state = .StartBlock;
                try self.tokens.append(Token{ .type = .BlockEnd, .start = self.pos, .end = self.pos + 1 });
            },
            '\x00' => self.state = .Done,
            else => error.NotImplemented,
        };
    }

    fn readPropertyValue(self: *Tokenizer) !void {
        self.skipBlank();

        try self.tokens.append(Token{ .type = .PropertyValue, .start = self.pos });
        self.readWhile(isPropertyValue);
        try self.close_token();

        return switch (self.current_char) {
            ';' => {
                const property_value = self.get_last_token();
                if (property_value.start == property_value.end) {
                    return error.PropertyValueCannotBeEmpty;
                }
                try self.tokens.append(Token{ .type = .EndStatement, .start = self.pos, .end = self.pos + 1 });
            },
            '}' => error.PropertyValueMustEndWithASemicolon,
            '\r', '\n' => error.PropertyValueCannotContainCRLF,
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

        try self.tokens.append(Token{ .type = .VariableName, .start = self.pos });
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

        try self.tokens.append(Token{ .type = .VariableValue, .start = self.pos });
        self.readWhile(isPropertyValue);

        self.skipBlank();

        return switch (self.current_char) {
            ';' => {
                try self.close_token();
                try self.tokens.append(Token{ .type = .EndStatement, .start = self.pos, .end = self.pos + 1 });
            },
            '\r', '\n' => error.VariableValueCannotContainCRLF,
            '\x00' => error.UnexpectedEndOfFile,
            else => error.UnexpectedCharacter,
        };
    }

    inline fn skipBlank(self: *Tokenizer) void {
        return self.readWhile(std.ascii.isBlank);
    }

    inline fn skipSpace(self: *Tokenizer) void {
        return self.readWhile(std.ascii.isSpace);
    }

    inline fn readWhile(self: *Tokenizer, condition: fn (char: u8) bool) void {
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

    fn isSelectorStart(char: u8) bool {
        return isIdentifier(char) or char == '.' or char == '#';
    }

    fn isPropertyValue(char: u8) bool {
        return isIdentifier(char) or std.ascii.isBlank(char) or char == '#';
    }

    inline fn close_token(self: *Tokenizer) !void {
        var token = self.tokens.pop();
        token.end = self.pos;
        try self.tokens.append(token);
    }

    inline fn close_token_and_move_to(self: *Tokenizer, state: TokenizerState) !void {
        try self.close_token();
        self.state = state;
    }

    inline fn get_last_token(self: *Tokenizer) *Token {
        const tokens = self.tokens.items;
        return &tokens[tokens.len - 1];
    }
};

test "Selector - Class selector" {
    const input = ".button{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [4]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .BlockEnd, .start = 8, .end = 9 },
        Token{ .type = .EndOfFile, .start = 9, .end = 10 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Selector - Identifier can contains dashes" {
    const input = ".big-button{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [4]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 11 },
        Token{ .type = .BlockStart, .start = 11, .end = 12 },
        Token{ .type = .BlockEnd, .start = 12, .end = 13 },
        Token{ .type = .EndOfFile, .start = 13, .end = 14 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Selector - Type selector" {
    const input = "h1{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [4]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 2 },
        Token{ .type = .BlockStart, .start = 2, .end = 3 },
        Token{ .type = .BlockEnd, .start = 3, .end = 4 },
        Token{ .type = .EndOfFile, .start = 4, .end = 5 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Selector - Id selector" {
    const input = "#name{}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [4]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 5 },
        Token{ .type = .BlockStart, .start = 5, .end = 6 },
        Token{ .type = .BlockEnd, .start = 6, .end = 7 },
        Token{ .type = .EndOfFile, .start = 7, .end = 8 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Selector - Whitespaces between selector and the open bracket are skipped" {
    const input = ".button  \t \r\n {}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [4]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 14, .end = 15 },
        Token{ .type = .BlockEnd, .start = 15, .end = 16 },
        Token{ .type = .EndOfFile, .start = 16, .end = 17 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Property - Name and value" {
    const input = ".button{margin:0;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [7]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 15, .end = 16 },
        Token{ .type = .EndStatement, .start = 16, .end = 17 },
        Token{ .type = .BlockEnd, .start = 17, .end = 18 },
        Token{ .type = .EndOfFile, .start = 18, .end = 19 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Property - Space and tabs between name and colon are skipped" {
    const input = ".button{margin  \t :0;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [7]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 19, .end = 20 },
        Token{ .type = .EndStatement, .start = 20, .end = 21 },
        Token{ .type = .BlockEnd, .start = 21, .end = 22 },
        Token{ .type = .EndOfFile, .start = 22, .end = 23 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Property - Space and tabs between colon and value are skipped" {
    const input = ".button{margin: \t  0;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [7]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 19, .end = 20 },
        Token{ .type = .EndStatement, .start = 20, .end = 21 },
        Token{ .type = .BlockEnd, .start = 21, .end = 22 },
        Token{ .type = .EndOfFile, .start = 22, .end = 23 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Property - Space and tabs between the first value character and the semicolon are part of the value" {
    const input = ".button{margin:0 \t  ;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [7]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 15, .end = 20 },
        Token{ .type = .EndStatement, .start = 20, .end = 21 },
        Token{ .type = .BlockEnd, .start = 21, .end = 22 },
        Token{ .type = .EndOfFile, .start = 22, .end = 23 },
    };
    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Property - Value cannot contains CRLF" {
    const input = ".button{margin: 0\r\n;}";
    const failure = Tokenizer.tokenize(std.testing.allocator, input);
    try std.testing.expectError(error.PropertyValueCannotContainCRLF, failure);
}

test "Property - Value must end with a semicolon" {
    const input = ".button{margin: 0}";
    const failure = Tokenizer.tokenize(std.testing.allocator, input);

    try std.testing.expectError(error.PropertyValueMustEndWithASemicolon, failure);
}

test "Property - Value cannot be only whitespaces" {
    const input = ".button{margin: \t  ;}";
    const failure = Tokenizer.tokenize(std.testing.allocator, input);

    try std.testing.expectError(error.PropertyValueCannotBeEmpty, failure);
}

test "Property - Value cannot be empty" {
    const input = ".button{margin:;}";
    const failure = Tokenizer.tokenize(std.testing.allocator, input);

    try std.testing.expectError(error.PropertyValueCannotBeEmpty, failure);
}

test "Block - Whitespaces between open bracket and identifier character are skipped" {
    const input = ".button{ \r\n \t margin:0;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [7]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 14, .end = 20 },
        Token{ .type = .PropertyValue, .start = 21, .end = 22 },
        Token{ .type = .EndStatement, .start = 22, .end = 23 },
        Token{ .type = .BlockEnd, .start = 23, .end = 24 },
        Token{ .type = .EndOfFile, .start = 24, .end = 25 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Block - Whitespaces after a semicolon are skipped" {
    const input = ".button{margin:0;\r\n\t}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [7]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 15, .end = 16 },
        Token{ .type = .EndStatement, .start = 16, .end = 17 },
        Token{ .type = .BlockEnd, .start = 20, .end = 21 },
        Token{ .type = .EndOfFile, .start = 21, .end = 22 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Block - Multiple properties in a block" {
    const input = ".button{margin:0;padding:0;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [10]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .PropertyName, .start = 8, .end = 14 },
        Token{ .type = .PropertyValue, .start = 15, .end = 16 },
        Token{ .type = .EndStatement, .start = 16, .end = 17 },
        Token{ .type = .PropertyName, .start = 17, .end = 24 },
        Token{ .type = .PropertyValue, .start = 25, .end = 26 },
        Token{ .type = .EndStatement, .start = 26, .end = 27 },
        Token{ .type = .BlockEnd, .start = 27, .end = 28 },
        Token{ .type = .EndOfFile, .start = 28, .end = 29 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Variable" {
    const input = "$zig-orange:#f7a41d;";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [4]Token = .{
        Token{ .type = .VariableName, .start = 1, .end = 11 },
        Token{ .type = .VariableValue, .start = 12, .end = 19 },
        Token{ .type = .EndStatement, .start = 19, .end = 20 },
        Token{ .type = .EndOfFile, .start = 20, .end = 21 },
    };
    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Variable - Space and tabs between variable name and colon are skipped" {
    const input = "$zig-orange \t : #f7a41d;";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [4]Token = .{
        Token{ .type = .VariableName, .start = 1, .end = 11 },
        Token{ .type = .VariableValue, .start = 16, .end = 23 },
        Token{ .type = .EndStatement, .start = 23, .end = 24 },
        Token{ .type = .EndOfFile, .start = 24, .end = 25 },
    };
    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Variable - Space and tabs between variable value and semicolon are part of the variable value" {
    const input = "$zig-orange: #f7a41d \t ;";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [4]Token = .{
        Token{ .type = .VariableName, .start = 1, .end = 11 },
        Token{ .type = .VariableValue, .start = 13, .end = 23 },
        Token{ .type = .EndStatement, .start = 23, .end = 24 },
        Token{ .type = .EndOfFile, .start = 24, .end = 25 },
    };

    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Variable - Within a block" {
    const input = ".button{ $zig-orange: #f7a41d;}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();

    var expected: [7]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .VariableName, .start = 10, .end = 20 },
        Token{ .type = .VariableValue, .start = 22, .end = 29 },
        Token{ .type = .EndStatement, .start = 29, .end = 30 },
        Token{ .type = .BlockEnd, .start = 30, .end = 31 },
        Token{ .type = .EndOfFile, .start = 31, .end = 32 },
    };
    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Block - Nested block" {
    const input = ".button{h1{margin:0;}}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();
    var expected: [10]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .Selector, .start = 8, .end = 10 },
        Token{ .type = .BlockStart, .start = 10, .end = 11 },
        Token{ .type = .PropertyName, .start = 11, .end = 17 },
        Token{ .type = .PropertyValue, .start = 18, .end = 19 },
        Token{ .type = .EndStatement, .start = 19, .end = 20 },
        Token{ .type = .BlockEnd, .start = 20, .end = 21 },
        Token{ .type = .BlockEnd, .start = 21, .end = 22 },
        Token{ .type = .EndOfFile, .start = 22, .end = 23 },
    };
    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Block - Multiple nested block" {
    const input = ".button{h1{margin:0;} h2{margin:0;}}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();
    var expected: [16]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .Selector, .start = 8, .end = 10 },
        Token{ .type = .BlockStart, .start = 10, .end = 11 },
        Token{ .type = .PropertyName, .start = 11, .end = 17 },
        Token{ .type = .PropertyValue, .start = 18, .end = 19 },
        Token{ .type = .EndStatement, .start = 19, .end = 20 },
        Token{ .type = .BlockEnd, .start = 20, .end = 21 },
        Token{ .type = .Selector, .start = 22, .end = 24 },
        Token{ .type = .BlockStart, .start = 24, .end = 25 },
        Token{ .type = .PropertyName, .start = 25, .end = 31 },
        Token{ .type = .PropertyValue, .start = 32, .end = 33 },
        Token{ .type = .EndStatement, .start = 33, .end = 34 },
        Token{ .type = .BlockEnd, .start = 34, .end = 35 },
        Token{ .type = .BlockEnd, .start = 35, .end = 36 },
        Token{ .type = .EndOfFile, .start = 36, .end = 37 },
    };
    try expectTokenEquals(&expected, tokenization.tokens);
}

test "Block - Empty nested block" {
    const input = ".button{h1{}}";
    var tokenization = try Tokenizer.tokenize(std.testing.allocator, input);
    defer tokenization.deinit();
    var expected: [7]Token = .{
        Token{ .type = .Selector, .start = 0, .end = 7 },
        Token{ .type = .BlockStart, .start = 7, .end = 8 },
        Token{ .type = .Selector, .start = 8, .end = 10 },
        Token{ .type = .BlockStart, .start = 10, .end = 11 },
        Token{ .type = .BlockEnd, .start = 11, .end = 12 },
        Token{ .type = .BlockEnd, .start = 12, .end = 13 },
        Token{ .type = .EndOfFile, .start = 13, .end = 14 },
    };
    try expectTokenEquals(&expected, tokenization.tokens);
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
