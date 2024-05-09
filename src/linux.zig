const uwaka = @import("mix.zig");

const std = @import("std");
const stderr = std.io.getStdErr().writer();
const stdout = std.io.getStdOut().writer();

const Context = struct {
    inotify_fd: i32,
    watchedFiles: std.AutoHashMap(i32, []const u8),
};

pub fn initWatching(options: uwaka.Options, allocator: std.mem.Allocator) !Context {
    var context = Context{
        .inotify_fd = 0,
        .watchedFiles = std.AutoHashMap(i32, []const u8).init(allocator),
    };

    // init inotify
    context.inotify_fd = std.posix.inotify_init1(0) catch |e| {
        try stderr.print("Failed to initialize inotify\n", .{});
        return e;
    }; // no flags, potentially can set IN_NONBLOCK and/or IN_CLOEXEC

    uwaka.log.debug("Initialized inotify with fd {d}", .{context.inotify_fd});

    const cwd = std.fs.cwd(); // current working directory

    for (options.fileList.items) |file| {
        uwaka.log.debug("Processing file {s}", .{file});
        const stat = cwd.statFile(file) catch {
            try stderr.print("Failed to stat file {s}\n", .{file});
            continue;
        };

        if (stat.kind != .file) {
            try stderr.print("File {s} is not a regular file. Ignored.\n", .{file});
            continue;
        }

        const wd = std.posix.inotify_add_watch(context.inotify_fd, file, std.os.linux.IN.MODIFY) catch {
            try stderr.print("Failed to add watch for file {s}\n", .{file});
            continue;
        };
        try context.watchedFiles.put(wd, file);

        uwaka.log.debug("Added watch for file {s} with wd {d}", .{ file, wd });
    }

    if (context.watchedFiles.count() == 0) {
        try stderr.print("No files to watch\n", .{});
    }

    return context;
}

// define the inotify_event struct
const InotifyEvent = extern struct {
    wd: i32,
    mask: u32,
    cookie: u32,
    len: u32,
    name: [0]u8,
};

fn inotifyToUwakaEvent(mask: u32) uwaka.EventType {
    switch (mask) {
        std.os.linux.IN.MODIFY => return uwaka.EventType.FileChange,
        else => return uwaka.EventType.Unknown,
    }
}

pub fn nextEvent(context: Context) !uwaka.Event {
    if (context.inotify_fd == 0) {
        @panic("inotify_fd not initialized\n");
    }

    var buffer: [@sizeOf(InotifyEvent)]u8 = undefined;

    const bytesRead = try std.posix.read(context.inotify_fd, &buffer);

    if (bytesRead != @sizeOf(InotifyEvent)) {
        try stderr.print("Read unexpected number of bytes from inotify fd\n", .{});
    }

    // parse as InotifyEvent
    const eventList: InotifyEvent = std.mem.bytesAsValue(InotifyEvent, &buffer).*;

    return uwaka.Event{
        .etype = inotifyToUwakaEvent(eventList.mask),
        .fileName = context.watchedFiles.get(eventList.wd).?,
    };
}
