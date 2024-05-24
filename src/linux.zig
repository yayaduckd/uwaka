// implementations of file monitoring functions using Linux's inotify API

const uwa = @import("mix.zig");

const std = @import("std");

const MAX_PATH_LENGTH = 4096;
const MOVE_TIMEOUT: i64 = 10000; // 10 second
const directoryWatchMask = std.os.linux.IN.MOVED_FROM |
    std.os.linux.IN.MOVED_TO |
    std.os.linux.IN.CREATE |
    // std.os.linux.IN.DELETE |
    std.os.linux.IN.ONLYDIR;
const fileWatchMask = std.os.linux.IN.MODIFY | std.os.linux.IN.DELETE_SELF;

pub const Context = struct {
    inotify_fd: i32,
    watchedFiles: std.AutoHashMap(i32, []const u8),
    eventQueue: std.ArrayList(uwa.Event),
    moveCookies: std.AutoHashMap(u32, i64),
    createdFiles: uwa.FileSet,
};

pub fn initWatching(options: *uwa.Options) !Context {
    var context = Context{
        .inotify_fd = 0,
        .watchedFiles = std.AutoHashMap(i32, []const u8).init(uwa.alloc),
        .eventQueue = std.ArrayList(uwa.Event).init(uwa.alloc),
        .moveCookies = std.AutoHashMap(u32, i64).init(uwa.alloc),
        .createdFiles = uwa.FileSet.init(uwa.alloc),
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

        const wd = std.posix.inotify_add_watch(context.inotify_fd, file, fileWatchMask) catch {
            try uwa.stderr.print("Failed to add watch for file {s}\n", .{file});
            continue;
        };
        try context.watchedFiles.put(wd, file);
        uwa.log.debug("Added watch for file {s} with wd {d}", .{ file, wd });
    }

    if (context.watchedFiles.count() == 0) {
        try uwa.stderr.print("No files to watch\n", .{});
    }

    // watch the git directory
    if (options.gitRepos) |repos| {
        var reposIterator = repos.iterator();
        while (reposIterator.next()) |repo| {
            const gwd = std.posix.inotify_add_watch(context.inotify_fd, repo.*, directoryWatchMask) catch |err| {
                try uwa.stderr.print("Failed to add watch for git directory {s}\n", .{repo.*});
                return err;
            };
            try context.watchedFiles.put(gwd, repo.*);
            uwa.log.debug("Added watch for directory {s} with wd {d}", .{ repo.*, gwd });
        }
    }
    if (options.explicitFolders) |folders| {
        var foldersIterator = folders.iterator();
        while (foldersIterator.next()) |folder| {
            const fwd = std.posix.inotify_add_watch(context.inotify_fd, folder.*, directoryWatchMask) catch |err| {
                try uwa.stderr.print("Failed to add watch for folder {s}\n", .{folder.*});
                return err;
            };
            try context.watchedFiles.put(fwd, folder.*);
            uwa.log.debug("Added watch for directory {s} with wd {d}", .{ folder.*, fwd });
        }
    }

    context.eventQueue = std.ArrayList(uwa.Event).init(uwa.alloc);

    return context;
}

pub fn deInitWatching(context: *Context) void {
    if (context.inotify_fd != 0) {
        std.posix.close(context.inotify_fd);
    }
    context.eventQueue.deinit();
    context.watchedFiles.deinit();
    context.moveCookies.deinit();
    context.createdFiles.deinit();
}

// define the inotify_event struct
const inotifyEvent = struct {
    wd: c_int,
    mask: u32,
    cookie: u32,
    len: u32,
    name: ?[]u8,
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

const EventTypeInfo = struct {
    isDir: bool,
    etype: uwa.EventType,
};

fn inotifyToUwakaEvent(event: inotifyEvent, context: *Context) ?EventTypeInfo {
    const m = event.mask;
    const IN = std.os.linux.IN;
    const etype = uwa.EventType;
    var isDir = false;
    const finalType = blk: {
        if (m & IN.ISDIR > 0) isDir = true;
        if (m & IN.MODIFY > 0) break :blk etype.FileChange;
        if (m & IN.CREATE > 0) break :blk etype.FileCreate;
        if (m & IN.DELETE_SELF > 0) break :blk etype.FileDelete;
        if (m & IN.MOVED_FROM > 0) break :blk handleMove(event.cookie, context);
        if (m & IN.MOVED_TO > 0) break :blk handleMove(event.cookie, context);
        uwa.log.debug("Unknown event with mask {}", .{m});
        break :blk etype.Unknown;
    };

    if (finalType) |t| {
        return .{
            .isDir = isDir,
            .etype = t,
        };
    }
    return null;
}

pub fn nextEvent(context: *Context, options: *uwa.Options) !uwa.Event {
    if (context.eventQueue.items.len > 0) {
        const event = context.eventQueue.pop();
        return event;
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
        if (event.len > 0) {
            const nullCharPos = std.mem.indexOfScalar(u8, buffer[bytesRead..buffer.len], 0) orelse buffer.len - bytesRead;
            event.name = buffer[bytesRead .. bytesRead + nullCharPos];
            bytesRead += event.len;
        } else {
            event.name = null;
        }

        uwa.log.debug("inotify event: {any}. filename = '{s}'", .{ event, event.name orelse "" });

        if (event.mask == std.os.linux.IN.IGNORED) continue;
        const eventTypeInfo = inotifyToUwakaEvent(event, context);
        uwa.log.debug("eventTypeInfo: {any}", .{eventTypeInfo});
        if (eventTypeInfo) |etypeinfo| {
            var fileName = context.watchedFiles.get(event.wd).?;
            uwa.log.debug("{s}", .{fileName});
            if (etypeinfo.etype == uwa.EventType.FileDelete) {
                fileName = try uwa.alloc.dupe(u8, event.name orelse fileName);
                _ = context.watchedFiles.remove(event.wd);
                context.createdFiles.remove(fileName);
            } else if (etypeinfo.etype == uwa.EventType.FileCreate) {
                const dir = context.watchedFiles.get(event.wd).?;
                const joinedPath = try std.fs.path.join(uwa.alloc, &.{ dir, event.name.? });
                defer uwa.alloc.free(joinedPath);
                try context.createdFiles.insert(joinedPath);
                fileName = context.createdFiles.get(joinedPath).?;
                const mask: u32 = if (etypeinfo.isDir) directoryWatchMask else fileWatchMask;
                uwa.log.debug("adding watch for {s} with mask {d}", .{ fileName, mask });
                const wd = try std.posix.inotify_add_watch(context.inotify_fd, fileName, mask);
                try context.watchedFiles.put(wd, fileName);
            }
            const uwakaEvent = uwa.Event{
                .etype = etypeinfo.etype,
                .fileName = fileName,
            };
            if (!etypeinfo.isDir) {
                try context.eventQueue.append(uwakaEvent);
            }
        } else {
            continue;
        }
    }
    return nextEvent(context, options);
}
