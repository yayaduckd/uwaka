const uwaka = @import("mix.zig");

const std = @import("std");
const stderr = std.io.getStdErr().writer();
const stdout = std.io.getStdOut().writer();

const MAX_PATH_LENGTH = 4096;
const MOVE_TIMEOUT: i64 = 10000; // 10 second

pub const Context = struct {
    inotify_fd: i32,
    watchedFiles: std.AutoHashMap(i32, []const u8),
    eventQueue: std.ArrayList(uwaka.Event),
    moveCookies: std.AutoHashMap(u32, i64),
};

pub fn initWatching(options: *uwaka.Options, allocator: std.mem.Allocator) !Context {
    var context = Context{
        .inotify_fd = 0,
        .watchedFiles = std.AutoHashMap(i32, []const u8).init(allocator),
        .eventQueue = std.ArrayList(uwaka.Event).init(allocator),
        .moveCookies = std.AutoHashMap(u32, i64).init(allocator),
    };

    // init inotify
    context.inotify_fd = std.posix.inotify_init1(0) catch |e| {
        try stderr.print("Failed to initialize inotify\n", .{});
        return e;
    }; // no flags, potentially can set IN_NONBLOCK and/or IN_CLOEXEC

    uwaka.log.debug("Initialized inotify with fd {d}", .{context.inotify_fd});

    const cwd = std.fs.cwd(); // current working directory

    var iterator = options.fileSet.iterator();
    while (iterator.next()) |filePtr| {
        const file = filePtr.*;
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

    const watchMask = std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO | std.os.linux.IN.CREATE;
    // watch the git directory
    const gwd = std.posix.inotify_add_watch(context.inotify_fd, options.gitRepo, watchMask) catch |err| {
        try stderr.print("Failed to add watch for git directory {s}\n", .{options.gitRepo});
        return err;
    };
    try context.watchedFiles.put(gwd, options.gitRepo);

    context.eventQueue = std.ArrayList(uwaka.Event).init(allocator);

    return context;
}

pub fn deInitWatching(context: Context) void {
    if (context.inotify_fd != 0) {
        std.posix.close(context.inotify_fd);
    }
}

// define the inotify_event struct
const inotifyEvent = struct {
    wd: c_int,
    mask: u32,
    cookie: u32,
    len: u32,
    name: []u8,
};

fn handleMove(cookie: u32, context: *Context) ?uwaka.EventType {
    var iterator = context.moveCookies.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.time.milliTimestamp() - value > MOVE_TIMEOUT) {
            _ = context.moveCookies.remove(key);
        }
    }

    const moveCookie = context.moveCookies.get(cookie);
    if (moveCookie == null) {
        context.moveCookies.put(cookie, std.time.milliTimestamp()) catch {
            @panic("out of memory");
        };
        return uwaka.EventType.FileMove;
    } else {
        _ = context.moveCookies.remove(cookie);
        return null;
    }
}

fn inotifyToUwakaEvent(event: inotifyEvent, context: *Context) ?uwaka.EventType {
    switch (event.mask) {
        std.os.linux.IN.MODIFY => return uwaka.EventType.FileChange,
        std.os.linux.IN.CREATE => return uwaka.EventType.FileCreate,
        std.os.linux.IN.IGNORED => @panic("unreachable"),
        std.os.linux.IN.MOVED_FROM => return handleMove(event.cookie, context),
        std.os.linux.IN.MOVED_TO => return handleMove(event.cookie, context),
        else => {
            uwaka.log.debug("Unknwon event with mask {}", .{event.mask});
            return uwaka.EventType.Unknown;
        },
    }
}

pub fn nextEvent(context: *Context, options: *uwaka.Options) !uwaka.Event {
    if (context.eventQueue.items.len > 0) {
        return context.eventQueue.pop();
    }

    // otherwise, read from inotify fd
    if (context.inotify_fd == 0) {
        @panic("inotify_fd not initialized\n");
    }

    var buffer = std.mem.zeroes([@sizeOf(inotifyEvent) + std.os.linux.NAME_MAX + 1]u8);

    const totalBytesRead = std.posix.read(context.inotify_fd, &buffer) catch |err| {
        try stderr.print("Failed to read from inotify fd {d}\n", .{context.inotify_fd});
        return err;
    };

    var bytesRead: usize = 0;
    while (bytesRead < totalBytesRead) {
        // create a new inotify event
        var event: inotifyEvent = undefined;
        // copy wd
        event.wd = std.mem.bytesToValue(c_int, buffer[bytesRead .. bytesRead + @sizeOf(c_int)]);
        bytesRead += @sizeOf(c_int);
        // copy mask
        event.mask = std.mem.bytesToValue(u32, buffer[bytesRead .. bytesRead + @sizeOf(u32)]);
        bytesRead += @sizeOf(u32);
        // copy cookie
        event.cookie = std.mem.bytesToValue(u32, buffer[bytesRead .. bytesRead + @sizeOf(u32)]);
        bytesRead += @sizeOf(u32);
        // copy len
        event.len = std.mem.bytesToValue(u32, buffer[bytesRead .. bytesRead + @sizeOf(u32)]);
        bytesRead += @sizeOf(u32);
        // copy name
        event.name = buffer[bytesRead .. bytesRead + event.len];
        bytesRead += event.len;

        if (event.mask == std.os.linux.IN.IGNORED) {
            // file name
            const fileName = context.watchedFiles.get(event.wd).?;
            options.explicitFiles.remove(fileName);
            options.fileSet.remove(fileName);
            _ = context.watchedFiles.remove(event.wd);
            continue;
        }

        const eventType = inotifyToUwakaEvent(event, context);
        if (eventType) |etype| {
            const uwakaEvent = uwaka.Event{
                .etype = etype,
                .fileName = context.watchedFiles.get(event.wd).?,
            };
            try context.eventQueue.append(uwakaEvent);
        } else {
            continue;
        }
    }
    return nextEvent(context, options);
}
