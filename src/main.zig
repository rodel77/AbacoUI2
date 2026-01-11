const std = @import("std");
const print = std.debug.print;
const watcher = @import("watcher.zig");
const Scanner = @import("scanner.zig").Scanner;
const Emitter = @import("emitter.zig").Emitter;
const server = @import("server.zig");
const Server = server.Server;

const http = std.http;

const Allocator = std.mem.Allocator;

const EXTENSION = ".ui";

var http_server: Server = undefined;

var compiler_mutex = std.Thread.Mutex{};

var files: std.StringHashMap([]u8) = undefined;

pub fn main() !void {
    // var ar
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    // const allocator = arena.allocator();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    files = std.StringHashMap([]u8).init(allocator);
    defer files.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // executable
    _ = args.next();

    const path = args.next();
    if (path == null) {
        std.debug.print("path expected as first argument\n", .{});
        return;
    }

    const absolute_path = std.fs.cwd().realpathAlloc(allocator, path.?) catch |er| switch(er) {
        std.posix.RealPathError.FileNotFound => {
            print("path not found\n", .{});
            return;
        },
        else => |err| return err,
    };
    defer allocator.free(absolute_path);

    const dir_watcher = try watcher.Watcher.init(allocator, &absolute_path);
    defer dir_watcher.deinit();

    const dir = try std.fs.openDirAbsolute(absolute_path, .{
        .iterate = true,
    });

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    // init http server

    const host = [4]u8{127, 0, 0, 1};
    const address = std.net.Address.initIp4(host, 2379);
    http_server = try Server.init(allocator, address, handle_http_request);


    while(try walker.next()) |entry| {
        const extension = std.fs.path.extension(entry.path);
        if(!std.mem.eql(u8, extension, EXTENSION)) continue;

        const file: std.fs.File = dir.openFile(entry.path, .{}) catch |err| {
            if(err==error.AccessDenied) continue;
            unreachable;
        };

        try process_file(allocator, dir, entry.path, &file);
        file.close();
    }

    try http_server.listen();

    while(true){
        const result_path = dir_watcher.next_event() catch |err| {
            if(err==error.AccessDenied) continue;
            print("Error reading dir: {?}", .{err});
            continue;
        };
        if(result_path) |p| {
            const file = try dir_watcher.dir.openFile(p, .{});

            const relative = try std.fs.path.relative(allocator, absolute_path, p);

            try process_file(allocator, dir_watcher.dir, relative, &file);

            file.close();
            allocator.free(p);
            allocator.free(relative);
        }
    }
}

pub fn JSONArray(comptime T: type) type {
    return []T;
}

pub fn alloc_escape_string(allocator: Allocator, input: []const u8) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, input.len * 2);
    defer buffer.deinit();

    for(input) |char| {
        switch(char) {
            '"' => {
                try buffer.appendSlice("\\\"");
            },
            '\n' => {
                try buffer.appendSlice("\\n");
            },
            '\\' => {
                try buffer.appendSlice("\\\\");
            },
            else => {
                try buffer.append(char);
            }
        }
    }

    return buffer.toOwnedSlice();
}

pub fn find_path(path: []u8, cache: *std.StringHashMap([]u8)) ?[]const u8 {
    if (cache.getEntry(path)) |entry| {
        return entry.key_ptr.*;
    }

    // deep search
    var iterator = cache.keyIterator();
    while (iterator.next()) |key_ptr| {
        const key = key_ptr.*;
        const p = path;
        if (ends_with(p, key)) {
            return key_ptr.*;
        }
        if (ends_with(key, p)) {
            return key_ptr.*;
        }
    }

    return null;
}

pub fn prepare_response(allocator: Allocator, paths: [][]u8, cache: *std.StringHashMap([]u8), buffer: *std.ArrayList(u8)) !void {
    try buffer.append('{');
    for (paths, 0..) |path, index| {
        const p = find_path(path, cache);
        if(p == null) {
            print("path not found: {s}", .{path});
            unreachable;
        }
        const key = p.?;
        const entry = cache.getEntry(key).?;

        const result = try alloc_escape_string(allocator, entry.value_ptr.*);
        try buffer.writer().print("\"{s}\": \"{s}\"", .{entry.key_ptr.*, result});
        allocator.free(result);

        if(index < paths.len - 1){
            try buffer.append(',');
        }
    }
    try buffer.append('}');
}

pub fn handle_http_request(request: *server.Request, response: *server.Response) server.ResponseError!void {
    compiler_mutex.lock();
    defer compiler_mutex.unlock();

    const parsed = std.json.parseFromSlice([][]u8, http_server.allocator, request.data, .{}) catch unreachable;
    defer parsed.deinit();

    const paths = parsed.value;

    var buffer = std.ArrayList(u8).init(http_server.allocator);
    prepare_response(http_server.allocator, paths, &files, &buffer) catch unreachable;

    response.setHeader("Content-Type", "application/json");
    try response.send(buffer.items);

    buffer.deinit();
}

pub fn ends_with(str: []const u8, suffix: []const u8) bool {
    return str.len >= suffix.len and std.mem.eql(u8, str[str.len - suffix.len ..], suffix);
}

pub fn process_file(allocator: Allocator, working_dir: std.fs.Dir, name: []const u8, file: *const std.fs.File) !void {
    compiler_mutex.lock();
    defer compiler_mutex.unlock();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(content);
    if(content.len==0) return;

    var scanner = try Scanner.init(allocator, name, &content);
    defer scanner.deinit();
    try scanner.compile();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const new_file = name[0..name.len-3];

    var emitter = Emitter.init(allocator, &buffer, &scanner);
    defer emitter.deinit();
    try emitter.emit(new_file);

    // make new file with .lua extension
    var new_path = try allocator.alloc(u8, new_file.len + 4);
    @memcpy(new_path[0..new_file.len], new_file);
    @memcpy(new_path[new_file.len..][0..4], ".lua");
    defer allocator.free(new_path);

    var output = try working_dir.createFile(new_path, .{});
    defer output.close();

    try output.writeAll(buffer.items);

    const key = try allocator.dupe(u8, new_path);
    std.mem.replaceScalar(u8, key, '\\', '/', );

    const compiled = try buffer.toOwnedSlice();

    try put_and_free(http_server.allocator, &files, key, compiled);
}

const expect = std.testing.expect;

test "basic compilation" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.appendSlice(":ScreenGui GUI\n");
    try buffer.appendSlice("DisplayOrder 23\n");
    try buffer.appendSlice("IgnoreGuiInset true\n");
    try buffer.appendSlice("Size UDim2.fromScale(1, 1)\n");

    var scanner = try Scanner.init(std.testing.allocator, "test.lua", &buffer.items);
    defer scanner.deinit();
    try scanner.compile();

    try expect(scanner.classes.items.len==1);
    try expect(std.mem.eql(u8, scanner.classes.items[0].name.?, "GUI"));
    try expect(std.mem.eql(u8, scanner.classes.items[0].type.?, "ScreenGui"));
}

test "basic compilation and emitting" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.appendSlice(":ScreenGui GUI\n");
    try buffer.appendSlice("DisplayOrder 23\n");
    try buffer.appendSlice("IgnoreGuiInset true\n");
    try buffer.appendSlice("Size UDim2.fromScale(1, 1)\n");

    var scanner = try Scanner.init(std.testing.allocator, "test.lua", &buffer.items);
    defer scanner.deinit();
    try scanner.compile();

    try expect(scanner.classes.items.len==1);
    try expect(std.mem.eql(u8, scanner.classes.items[0].name.?, "GUI"));
    try expect(std.mem.eql(u8, scanner.classes.items[0].type.?, "ScreenGui"));

    var out = std.ArrayList(u8).init(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator, &out, &scanner);
    defer emitter.deinit();
    try emitter.emit("test.lua");

    try expect(out.items.len>0);

    out.deinit();
}

pub fn put_and_free(allocator: Allocator, map: *std.StringHashMap([]u8), key: []u8, value: []u8) !void {
    const val = try map.getOrPut(key);
    if(val.found_existing){
        allocator.free(val.value_ptr.*);
    }

    val.value_ptr.* = value;
}

test "hashmap" {
    var cache = std.StringHashMap([]u8).init(std.testing.allocator);
    defer cache.deinit();

    const str = try std.testing.allocator.alloc(u8, 100);
    @memset(str, 'D');
    const key = try std.testing.allocator.dupe(u8, "test.lua");
    defer std.testing.allocator.free(key);

    try put_and_free(std.testing.allocator, &cache, key, str);

    const str2 = try std.testing.allocator.alloc(u8, 100);
    @memset(str2, 'A');
    try put_and_free(std.testing.allocator, &cache, key, str2);
    std.testing.allocator.free(str2);
}