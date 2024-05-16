// implementations of file monitoring functions using manual polling of last modified dates (works for most unix systems)
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
    const cwd = std.fs.cwd(); // current working directory
    while (true) {
        // poll the files
        var filesIter = options.fileSet.iterator();

        // if a file has changed, send an event
        while (filesIter.next()) |filePtr| {
            const file = filePtr.*;
            const stat = cwd.statFile(file) catch |err| {
                uwa.log.err("Could not stat file: {s}. Error: {}", .{file, err});
                continue;
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

        if (context.eventQueue.items.len > 0) {
            return context.eventQueue.pop();
        }

        // sleep for the polling interval
        std.time.sleep(1000000000 * 10); // 10 seconds
    }
}
