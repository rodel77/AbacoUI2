const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const print = std.debug.print;

pub const Attribute = struct {
    name: []const u8,
    expression: []const u8,
};

pub const Class = struct {
    native: bool = false,
    indent: usize = 0,
    type: ?[]const u8 = null,
    name: ?[]const u8 = null,
    attributes: ArrayList(Attribute),
    element_id: usize = 0,

    const Self = @This();

    pub fn init(allocator: Allocator) Class {
        return Self{.attributes = ArrayList(Attribute).init(allocator)};
    }

    pub fn deinit(self: *Self) void {
        self.attributes.deinit();
    }
};

pub const Scanner = struct {
    source: *const []u8,
    name: []const u8,
    current: usize,
    start: usize,
    line: u32,
    allocator: Allocator,
    current_class: ?Class = null,
    classes: std.ArrayList(Class),

    const Self = @This();

    pub fn init(allocator: Allocator, name: [] const u8, source: *const []u8) !Self {
        return Self{
            .name = name,
            .classes = std.ArrayList(Class).init(allocator),
            .allocator = allocator,
            .source = source,
            .current = 0,
            .start = 0,
            .line = 1,
        };
    }

    pub fn deinit(self: *Self) void {
        for(self.classes.items) |*class| {
            class.deinit();
        }

        self.classes.deinit();
    }

    pub fn calculate_indent(self: *Self) usize {
        var indent: usize = 0;

        while(self.current<self.source.len and (self.peek()==' ' or self.peek()=='\t')){
            indent += 1;
            self.current += 1;
        }

        return indent;
    }

    pub fn peek(self: *Self) u8 {
        return self.source.*[self.current];
    }

    pub fn next(self: *Self) u8 {
        const result = self.source.*[self.current];
        self.current += 1;
        return result;
    }

    pub fn eof(self: *Self) bool {
        return self.current >= self.source.len;
    }

    pub fn check_newline(self: *Self) bool {
        if(self.eof()) return false;

        const token = self.peek();
        switch(token){
            '\n' => {
                _ = self.next();
                self.line += 1;
                return true;
            },
            '\r' => {
                _ = self.next();
                return true;
            },
            else => {
                return false;
            }
        }
    }

    pub fn consume_expression(self: *Self) []const u8 {
        const start = self.current;

        while(!self.eof() and self.peek()!='\n' and self.peek()!='\r'){
            self.current += 1;
        }

        const str = self.source.*[start..self.current];

        return str;
    }

    pub fn consume_string(self: *Self) []const u8 {
        const start = self.current;
        while(!self.eof() and self.peek()!=' ' and self.peek()!='\n' and self.peek()!='\r'){
            self.current += 1;
        }

        const str = self.source.*[start..self.current];

        if(!self.eof() and self.peek()==' '){
            self.current += 1;
        }

        return str;
    }

    pub fn consume_line(self: *Self) !void {
        const indent = self.calculate_indent();        

        // comments
        if(self.peek()=='#'){
            _ = self.consume_expression();
            return;
            // self.consume_line()
        }

        if(self.eof()){
            return;
        }

        if(self.check_newline()){
            return;
        }

        const token = self.peek();
        // class declaration
        if(token==':' or token==';'){
            try self.classes.append(Class.init(self.allocator));
            var class: *Class = &self.classes.items[self.classes.items.len-1];

            class.native = token==':';
            class.indent = indent;

            _ = self.next();
            const class_type = self.consume_string();
            class.type = class_type;

            if(self.eof() or self.peek()=='\n' or self.peek()=='\r') return;

            const class_name = self.consume_string();
            class.name = class_name;

            if(!self.eof() and !self.check_newline()){
                // TODO err
                print("new line expected\n", .{});
            }

            return;
        }

        // parse property set
        const property = self.consume_string();

        if(self.eof() or self.peek()=='\n' or self.peek()=='\r'){
            // @TODO: error handling
            print("[error] expression expected!", .{});
        }

        const expression = self.consume_expression();

        if(self.classes.items.len==0){
            print("[error] no class found to assign property.\n", .{});
            return;
        }

        var current_class = &self.classes.items[self.classes.items.len-1];
        try current_class.attributes.append(Attribute{
            .name = property,
            .expression = expression,
        });
    }

    pub fn compile(self: *Self) !void {
        while(!self.eof()){
            try self.consume_line();
        }
    }
};