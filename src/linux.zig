// implementations of file monitoring functions using Linux's inotify API

const uwa = @import("mix.zig");

const std = @import("std");

const MAX_PATH_LENGTH = 4096;
const MOVE_TIMEOUT: i64 = 10000; // 10 second

pub const Context = struct {
    inotify_fd: i32,
    watchedFiles: std.AutoHashMap(i32, []const u8),
    eventQueue: std.ArrayList(uwa.Event),
    moveCookies: std.AutoHashMap(u32, i64),
};

pub fn initWatching(options: *uwa.Options) !Context {
    var context = Context{
        .inotify_fd = 0,
        .watchedFiles = std.AutoHashMap(i32, []const u8).init(uwa.alloc),
        .eventQueue = std.ArrayList(uwa.Event).init(uwa.alloc),
        .moveCookies = std.AutoHashMap(u32, i64).init(uwa.alloc),
    };

    // init inotify
    context.inotify_fd = std.posix.inotify_init1(0) catch |e| {
        try uwa.stderr.print("Failed to initialize inotify\n", .{});
        return e;
    }; // no flags, potentially can set IN_NONBLOCK and/or IN_CLOEXEC

    uwa.log.debug("Initialized inotify with fd {d}", .{context.inotify_fd});

    const cwd = std.fs.cwd(); // current working directory

    var iterator = options.fileSet.iterator();
    while (iterator.next()) |filePtr| {
        const file = filePtr.*;
        uwa.log.debug("Processing file {s}", .{file});
        const stat = cwd.statFile(file) catch {
            try uwa.stderr.print("Failed to stat file {s}\n", .{file});
            continue;
        };

        if (stat.kind != .file) {
            try uwa.stderr.print("File {s} is not a regular file. Ignored.\n", .{file});
            continue;
        }

        const wd = std.posix.inotify_add_watch(context.inotify_fd, file, std.os.linux.IN.MODIFY) catch {
            try uwa.stderr.print("Failed to add watch for file {s}\n", .{file});
            continue;
        };
        try context.watchedFiles.put(wd, file);

        uwa.log.debug("Added watch for file {s} with wd {d}", .{ file, wd });
    }

    if (context.watchedFiles.count() == 0) {
        try uwa.stderr.print("No files to watch\n", .{});
    }

    const watchMask = std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE;
    // watch the git directory
    const gwd = std.posix.inotify_add_watch(context.inotify_fd, options.gitRepo, watchMask) catch |err| {
        try uwa.stderr.print("Failed to add watch for git directory {s}\n", .{options.gitRepo});
        return err;
    };
    try context.watchedFiles.put(gwd, options.gitRepo);

    context.eventQueue = std.ArrayList(uwa.Event).init(uwa.alloc);

    return context;
}

pub fn deInitWatching(context: *Context) void {
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

fn handleMove(cookie: u32, context: *Context) ?uwa.EventType {
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
        return uwa.EventType.FileMove;
    } else {
        _ = context.moveCookies.remove(cookie);
        return null;
    }
}

fn inotifyToUwakaEvent(event: inotifyEvent, context: *Context) ?uwa.EventType {
    switch (event.mask) {
        std.os.linux.IN.MODIFY => return uwa.EventType.FileChange,
        std.os.linux.IN.CREATE => return uwa.EventType.FileCreate,
        std.os.linux.IN.DELETE => return uwa.EventType.FileDelete,
        std.os.linux.IN.DELETE | std.os.linux.IN.IGNORED => return uwa.EventType.FileDelete,
        std.os.linux.IN.IGNORED => @panic("unreachable"),
        std.os.linux.IN.MOVED_FROM => return handleMove(event.cookie, context),
        std.os.linux.IN.MOVED_TO => return handleMove(event.cookie, context),
        else => {
            uwa.log.debug("Unknwon event with mask {}", .{event.mask});
            return uwa.EventType.Unknown;
        },
    }
}

pub fn nextEvent(context: *Context, options: *uwa.Options) !uwa.Event {
    if (context.eventQueue.items.len > 0) {
        return context.eventQueue.pop();
    }

    // otherwise, read from inotify fd
    if (context.inotify_fd == 0) {
        @panic("inotify_fd not initialized\n");
    }

    var buffer = std.mem.zeroes([@sizeOf(inotifyEvent) + std.os.linux.NAME_MAX + 1]u8);

    const totalBytesRead = std.posix.read(context.inotify_fd, &buffer) catch |err| {
        try uwa.stderr.print("Failed to read from inotify fd {d}\n", .{context.inotify_fd});
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
            var fileName = context.watchedFiles.get(event.wd).?;
            if (etype == uwa.EventType.FileDelete) {
                fileName = event.name;
            }
            const uwakaEvent = uwa.Event{
                .etype = etype,
                .fileName = fileName,
            };
            try context.eventQueue.append(uwakaEvent);
        } else {
            continue;
        }
    }
    return nextEvent(context, options);
}
