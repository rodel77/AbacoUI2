const std = @import("std");

const RequestError = error {
    TooLong,
    InvalidMethod,
};

pub const ResponseError=  error {
    InternalError,
};

pub const Header = struct {
    field: []u8,
    value: []u8,
};

pub const Response = struct {
    stream: *std.net.Stream,
    buffer: std.ArrayList(u8),
    headers: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, stream: *std.net.Stream) Response {
        return .{
            .stream = stream,
            .buffer = std.ArrayList(u8).init(allocator),
            .headers = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.buffer.deinit();
    }

    pub fn setHeader(self: *Response, field: []const u8, value: []const u8) void {
        self.headers.put(field, value) catch unreachable;
    }

    pub fn send(self: *Response, message: []const u8) ResponseError!void {
        // set headers
        var buffer: [128]u8 = undefined;
        const str = std.fmt.bufPrint(&buffer, "{}", .{message.len}) catch unreachable;
        self.setHeader("Content-Length", str);
        self.setHeader("Connection", "Closed");

        // start response
        self.buffer.appendSlice("HTTP/1.1 200 OK\n") catch unreachable;

        // send headers
        var it = self.headers.iterator();
        while(it.next()) |header| {
            self.buffer.writer().print("{s}: {s}\n", .{header.key_ptr.*, header.value_ptr.*}) catch unreachable;
        }

        // send message
        self.buffer.append('\n') catch unreachable;
        self.buffer.appendSlice(message) catch unreachable;
    }

    pub fn write(self: *Response, buffer: []const u8) ResponseError!void {
        _ =  self.stream.writer().write(buffer) catch return ResponseError.InternalError;
    }
};

pub const RequestMethod = enum{
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    PATCH,
};

pub const Request = struct {
    method: RequestMethod,
    path: []const u8,
    data: []const u8,

    pub fn fromString(text: []const u8) Request {
        var iterator = std.mem.splitScalar(u8, text, '\n');

        // Method
        const first_line = iterator.next().?;
        var it = std.mem.splitScalar(u8, first_line, ' ');
        const method = it.next().?;
        const path = it.next().?;
        const version = it.next().?;
        _ = version;

        // Headers
        while(iterator.next()) |line| {
            if(std.mem.eql(u8, line, "\r")) break;

            const index = std.mem.indexOfScalar(u8, line, ':').?;

            const header_name = line[0..index];
            const header_value = line[index+2..];
            _ = header_name;
            _ = header_value;
        }

        // Data
        const data = iterator.next().?;
        const ending = std.mem.indexOfScalar(u8, data, 0).?;


        const methodType = std.meta.stringToEnum(RequestMethod, method).?;

        return .{
            .method = methodType,
            .path = path,
            .data = data[0..ending],
        };
    }
};

pub fn handleRequest(server: *Server, net_server: *std.net.Server) !void {
    const connection = try net_server.accept();
    defer connection.stream.close();

    const reader = connection.stream.reader();

    var buffer: [4096]u8 = undefined;
    @memset(&buffer, 0);

    const size = try reader.read(&buffer);
    if(size==4096) return RequestError.TooLong;

    var request = Request.fromString(&buffer);
    var response = Response.init(server.allocator, &server.stream);
    defer response.deinit();

    try server.handler(&request, &response);

    _ = try connection.stream.writer().write(response.buffer.items);
}

pub fn ticker(self: *Server) !void {
    var server = try self.address.listen(.{});

    std.debug.print("Listening on {?}\n", .{self.address.getPort()});

    while(true){
        try handleRequest(self, &server);
    }
}

const RequestHandler: type = fn(request: *Request, response: *Response) ResponseError!void;

pub const Server = struct {
    address: std.net.Address,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    handler: *const RequestHandler,

    pub fn init(allocator: std.mem.Allocator, address: std.net.Address, handler: RequestHandler) !Server {
        const socket = try std.posix.socket(address.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);

        const stream = std.net.Stream{.handle = socket};

        return .{
            .address = address,
            .stream = stream,
            .allocator = allocator,
            .handler = handler,
        };
    }

    pub fn listen(self: *Server) !void {
        const thread = try std.Thread.spawn(.{}, ticker, .{self});
        _ = thread;
    }
};