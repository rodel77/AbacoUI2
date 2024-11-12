const std = @import("std");
const ArrayList = std.ArrayList;
const print = std.debug.print;
const _scanner = @import("scanner.zig");
const Scanner = _scanner.Scanner;
const Class = _scanner.Class;
const Attribute = _scanner.Attribute;

const Allocator = std.mem.Allocator;

const IDBound = struct {
    id_name: []const u8,
    element_id: usize,
};

pub const Emitter = struct {

    out: *ArrayList(u8),
    scanner: *Scanner,
    element_count: usize = 0,
    stack: ArrayList(*Class),
    ids: ArrayList(IDBound),
    allocator: Allocator,

    const Self = @This();


    pub fn init(allocator: Allocator, out: *ArrayList(u8), scanner: *Scanner) Self{
        return .{
            .out = out,
            .scanner = scanner,
            .stack = ArrayList(*Class).init(allocator),
            .ids = ArrayList(IDBound).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
        self.ids.deinit();
    }

    pub fn emit(self: *Self, file: []const u8) !void {
        try self.out.appendSlice("-- Auto generated with AbacoUI\n");
        try self.out.appendSlice("return function()\n");

        if(self.scanner.classes.items.len>0){
            var count: usize = 0;
            while(true){
                const class: *Class = &self.scanner.classes.items[count];

                if(class.native){
                    try self.emit_class(class);
                }else{
                    try self.emit_custom_class(class);
                }

                class.element_id = self.element_count;
                try self.stack.append(class);

                self.element_count += 1;

                // emit aspect ratio
                for(class.attributes.items) |attribute| {
                    if(std.mem.eql(u8, attribute.name, "AspectRatio")){
                        var aspect_ratio = Class.init(self.allocator);
                        aspect_ratio.indent = class.indent + 4;
                        aspect_ratio.type = "UIAspectRatioConstraint";
                        aspect_ratio.native = true;
                        aspect_ratio.attributes = std.ArrayList(Attribute).init(self.allocator);
                        try aspect_ratio.attributes.append(Attribute{
                            .name = "AspectRatio",
                            .expression = attribute.expression,
                        });
                        aspect_ratio.element_id = self.element_count;
                        try self.emit_class(&aspect_ratio);
                        try self.stack.append(&aspect_ratio);
                        aspect_ratio.deinit();
                        self.element_count += 1;
                        break;
                    }
                }

                count += 1;
                if(count >= self.scanner.classes.items.len) break;
            }
        }

        try self.out.appendSlice("    return element0, {");

        // id bounds
        for(self.ids.items) |id_bound| {
            try self.out.writer().print("[\"{s}\"] = element{d},", . {id_bound.id_name, id_bound.element_id});
        }

        try self.out.appendSlice("}, {}, ");

        const output = try self.allocator.dupe(u8, file);
        defer self.allocator.free(output);
        std.mem.replaceScalar(u8, output, '\\', '/', );

        try self.out.writer().print("\"{s}.lua\";\n", .{output});

        try self.out.appendSlice("end");
    }

    pub fn emit_custom_class(self: *Self, class: *Class) !void {
        if(class.type) |type_val| {
            try self.out.writer().print("    local element{d} = UI.createElement(\"{s}\", {c}\n", .{self.element_count, type_val, '{'});
        }else{
            print("missing class type\n", .{});
            return;
        }

        if(class.name) |name| {
            try self.out.writer().print("        Name = \"{s}\",\n", .{name});
        }

        for (class.attributes.items) |attribute| {
            if(std.mem.eql(u8, attribute.name, "ID")){
                const bound = IDBound{
                    .element_id = self.element_count,
                    .id_name = attribute.expression,
                };
                try self.ids.append(bound);
                continue;
            }

            if(
                std.mem.eql(u8, attribute.name, "AspectRatio") and
                !std.mem.eql(u8, class.type.?, "UIAspectRatioConstraint")
            ) continue;

            try self.out.writer().print("        {s} = {s},\n", .{
                attribute.name,
                attribute.expression
            });
        }

        if(self.stack.items.len>0){
            var last: *Class = self.stack.getLast();
            while(last.indent>=class.indent){
                _ = self.stack.pop();

                if(self.stack.items.len==0) {
                    print("Trying to create inner element \"{s}\" at root level\n", .{class.type.?});
                    break;
                }

                last = self.stack.getLast();
            }
            try self.out.writer().print("    {c}, nil, element{d});\n", .{'}', last.element_id});
        }

        try self.out.append('\n');
    }

    pub fn emit_class(self: *Self, class: *Class) !void {
        if(class.type) |type_val| {
            try self.out.writer().print("    local element{d} = Instance.new(\"{s}\");\n", .{self.element_count, type_val});
        }else{
            print("missing class type\n", .{});
            return;
        }

        // inject name
        if(class.name) |name| {
            try self.out.writer().print("    element{d}.Name = \"{s}\";\n", .{self.element_count, name});
        }

        for (class.attributes.items) |attribute| {
            if(std.mem.eql(u8, attribute.name, "ID")){
                const bound = IDBound{
                    .element_id = self.element_count,
                    .id_name = attribute.expression,
                };
                try self.ids.append(bound);
                continue;
            }

            if(
                std.mem.eql(u8, attribute.name, "AspectRatio") and
                !std.mem.eql(u8, class.type.?, "UIAspectRatioConstraint")
            ) continue;

            try self.out.writer().print("    element{d}.{s} = {s};\n", .{
                self.element_count,
                attribute.name,
                attribute.expression,
            });
        }

        if(self.stack.items.len>0){
            var last: *Class = self.stack.getLast();
            while(last.indent>=class.indent){
                _ = self.stack.pop();

                if(self.stack.items.len==0) {
                    print("Trying to create inner element \"{s}\" at root level\n", .{class.type.?});
                    break;
                }

                last = self.stack.getLast();
            }
            try self.out.writer().print("    element{d}.Parent = element{d};\n", .{self.element_count, last.element_id});
        }

        try self.out.append('\n');
    }
};