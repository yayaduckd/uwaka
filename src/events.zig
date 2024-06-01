const uwa = @import("mix.zig");

const std = @import("std");

pub fn rebuildFileList(options: *uwa.Options, context: ?*uwa.Context) !uwa.Context {

    // clear fileset
    options.fileSet.deinit();
    options.fileSet = try uwa.getFilesinGitReposAndFolders(options);

    // add all explicitly added files
    var explicitFileIterator = options.explicitFiles.iterator();
    while (explicitFileIterator.next()) |file| {
        try options.fileSet.insert(file.*);
    }

    if (context) |ctx| {
        // clear the context
        uwa.deInitWatching(ctx);
    }
    // re-init the context
    const ctx = try uwa.initWatching(options);
    return ctx;
}

var lastEventTime: i64 = 0;
var lastHeartbeat: i64 = 0;
const DEBOUNCE_TIME = 5000; // 5 seconds
pub fn handleEvent(event: uwa.Event, options: *uwa.Options, context: *uwa.Context) !bool {
    var heartbeatSent = false;
    switch (event.etype) {
        uwa.EventType.FileChange => {
            const currentTime = std.time.milliTimestamp();
            if (currentTime - lastEventTime < DEBOUNCE_TIME) {
                uwa.log.debug("event ignored at time {}", .{currentTime});
                lastEventTime = currentTime;
                return heartbeatSent;
            }

            if (std.mem.eql(u8, event.fileName, ".gitignore")) {
                // rebuild file list
                uwa.log.debug("Rebuilding file list due to .gitignore change", .{});
                context.* = try rebuildFileList(options, context);
            }

            heartbeatSent = try uwa.sendHeartbeat(lastHeartbeat, options, event);
            if (heartbeatSent) {
                lastHeartbeat = currentTime;
            }
            lastEventTime = currentTime;
        },
        uwa.EventType.FileCreate, uwa.EventType.FileMove => {
            try options.fileSet.insert(event.fileName);
        },
        uwa.EventType.FileDelete => {
            try uwa.assertIntegrity(options.fileSet.contains(event.fileName));
            options.fileSet.remove(event.fileName);
            options.explicitFiles.remove(event.fileName);
        },
        else => {
            uwa.log.err("Unknown event type: {}", .{event.etype});
        },
    }
    return heartbeatSent;
}

// atomically push and pop events
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        contents: std.ArrayList(T),
        mutex: std.Thread.Mutex,
        const Allocator = std.mem.Allocator;

        pub fn init(alloc: Allocator) Queue(T) {
            return Self{
                .contents = std.ArrayList(T).init(alloc),
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn push(self: *Queue(T), event: T) Allocator.Error!void {
            self.mutex.lock();
            try self.contents.append(event);
            self.mutex.unlock();
        }

        pub fn pop(self: *Queue(T)) ?T {
            if (self.contents.items.len == 0) {
                return null;
            }
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.contents.popOrNull();
        }
    };
}
