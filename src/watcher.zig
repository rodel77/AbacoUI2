const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

pub const Watcher = struct {
    path: *const []u8,
    handle: *anyopaque,
    allocator: Allocator,
    dir: std.fs.Dir,
    event_buffer: [4096] u8 align(@alignOf(windows.FILE_NOTIFY_INFORMATION)),
    overlapped: windows.OVERLAPPED,

    pub fn init(allocator: Allocator, path: *const []u8) !*Watcher {
        const self = try allocator.create(Watcher);

        self.allocator = allocator;
        self.path = path;
        self.dir = try std.fs.openDirAbsolute(path.*, .{
            .access_sub_paths = true
        });
        const sub_path = try windows.sliceToPrefixedFileW(std.fs.cwd().fd, path.*);
        // std.debug.assert(std.fs.path.isAbsolute(sub_path));

        const options = windows.OpenFileOptions{
            .access_mask = windows.GENERIC_READ | windows.SYNCHRONIZE | windows.FILE_LIST_DIRECTORY,
            .creation = windows.FILE_OPEN,
            .filter = .dir_only,
            .dir = std.fs.cwd().fd,
        };

        self.handle = windows.OpenFile(sub_path.span(), options) catch |err| switch(err) {
            windows.OpenError.NotDir => {
                std.debug.print("not a directory\n", .{});
                std.process.exit(1);
            },
            else => {
                return err;
            }
        };

        self.event_buffer = undefined;
        self.overlapped  = windows.OVERLAPPED{
            .Internal = 0,
            .InternalHigh = 0,
            .DUMMYUNIONNAME = .{
                .DUMMYSTRUCTNAME = .{
                    .Offset = 0,
                    .OffsetHigh = 0,
                }
            },
            .hEvent = null,
        };

        return self;
    }

    pub fn deinit(self: *Watcher) void {
        windows.CloseHandle(self.handle);
        self.allocator.destroy(self);
    }

    fn read_event(self: *Watcher, event: *[4096] u8) !?[]u8 {
        const file_information: *const windows.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(event));

        if(file_information.Action==windows.FILE_ACTION_REMOVED or file_information.Action==windows.FILE_ACTION_RENAMED_OLD_NAME) return null;

        const ptr = &event[@sizeOf(windows.FILE_NOTIFY_INFORMATION)];
        const name_ptr: *u16 = @ptrCast(@alignCast(ptr));
        const name: [*]u16 = @ptrCast(name_ptr);
        const filename_utf16 = name[0..file_information.FileNameLength / 2];
        var name_data: [std.fs.max_path_bytes]u8 = undefined;
        const basename = name_data[0..(try std.unicode.utf16LeToUtf8(&name_data, filename_utf16))];
        // std.debug.print("File changed {s} action {d}\n", .{basename, file_information.Action});

        // std.time.sleep(100);

        const path = try self.dir.realpathAlloc(self.allocator, basename);
        _ = std.mem.lastIndexOf(u8, path[0..path.len], ".ui") orelse return null;
        return path;
    }

    pub fn next_event(self: *Watcher) !?[]u8 {
        const notify_filter = windows.FileNotifyChangeFilter {
            .dir_name = true,
            .file_name = true,
            .attributes = true,
            .last_write = true,
            .creation = true,
        };

        const result = windows.kernel32.ReadDirectoryChangesW(
            self.handle,
            &self.event_buffer,
            self.event_buffer.len,
            windows.TRUE,
            notify_filter,
            null,
            &self.overlapped,
            null
        );

        if(result!=1){
            std.debug.print("unexpected error while reading directory changes\n", .{});
            unreachable;
        }

        const path = try read_event(self, &self.event_buffer);
        return path;
    }
};