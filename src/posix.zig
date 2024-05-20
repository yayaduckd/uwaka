// implementations of file monitoring functions using manual polling of last modified dates (works for most posix systems)
// for a more efficient implementation, compile specific implementations for your platform
const uwa = @import("mix.zig");

const std = @import("std");

pub const Context = struct {
    eventQueue: std.ArrayList(uwa.Event),
    lastModifiedMap: std.StringHashMap(i128),
};

pub fn initWatching(options: *uwa.Options) !Context {
    _ = options;
    // create the context
    return Context{
        .eventQueue = std.ArrayList(uwa.Event).init(uwa.alloc),
        .lastModifiedMap = std.StringHashMap(i128).init(uwa.alloc),
    };
}

pub fn deInitWatching(context: *Context) void {
    context.eventQueue.deinit();
    context.lastModifiedMap.deinit();
}

pub fn nextEvent(context: *Context, options: *uwa.Options) !uwa.Event {
    if (context.eventQueue.items.len > 0) {
        return context.eventQueue.pop();
    }
    const cwd = std.fs.cwd(); // current working directory
    var numIter: usize = 0;
    while (true) {
        // poll the files
        var filesIter = options.fileSet.iterator();

        // if a file has changed, send an event
        while (filesIter.next()) |filePtr| {
            const file = filePtr.*;
            const stat = cwd.statFile(file) catch {
                _ = context.lastModifiedMap.remove(file);
                // file deleted
                return uwa.Event{
                    .etype = uwa.EventType.FileDelete,
                    .fileName = file,
                };
            };

            var lastModified = context.lastModifiedMap.get(file);
            if (lastModified == null) {
                try context.lastModifiedMap.put(file, stat.mtime);
                lastModified = stat.mtime;
            }

            if (stat.mtime != lastModified) {
                // file has changed
                const event = uwa.Event{ .etype = uwa.EventType.FileChange, .fileName = file };
                try context.eventQueue.insert(0, event);
                try context.lastModifiedMap.put(file, stat.mtime);
            }
        }

        if (numIter >= 5) {
            // check for new files in repos
            var newFiles = try uwa.getFilesinGitReposAndFolders(options);
            var iter = newFiles.iterator();
            while (iter.next()) |file| {
                if (options.fileSet.contains(file.*)) {
                    continue;
                }
                const event = uwa.Event{
                    .etype = uwa.EventType.FileCreate,
                    .fileName = try uwa.alloc.dupe(u8, file.*),
                };
                try context.eventQueue.insert(0, event);
            }
            newFiles.deinit();
            numIter = 0;
        }

        if (context.eventQueue.items.len > 0) {
            return context.eventQueue.pop();
        }

        // sleep for the polling interval
        std.time.sleep(1000000000 * 2); // 2 seconds
        numIter += 1;
    }
}
