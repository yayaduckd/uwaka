// implementations of file monitoring functions using manual polling of last modified dates (works for most posix systems)
// for a more efficient implementation, compile specific implementations for your platform
const uwa = @import("mix.zig");

const std = @import("std");

pub const Context = struct {
    eventQueue: std.ArrayList(uwa.Event),
    lastModifiedMap: std.StringHashMap(i128),
    gitRepoFiles: std.ArrayList([]const u8),
};

pub fn initWatching(options: *uwa.Options) !Context {
    const gitRepoFiles = try uwa.getFilesInGitRepo(options.gitRepo);
    var gitRepoFilesList = std.ArrayList([]const u8).init(uwa.alloc);
    for (gitRepoFiles) |file| {
        try gitRepoFilesList.append(file);
    }
    // create the context
    return Context{
        .eventQueue = std.ArrayList(uwa.Event).init(uwa.alloc),
        .lastModifiedMap = std.StringHashMap(i128).init(uwa.alloc),
        .gitRepoFiles = gitRepoFilesList,
    };
}

pub fn deInitWatching(context: *Context) void {
    context.eventQueue.deinit();
    context.lastModifiedMap.deinit();
}

fn findNewStrings(old: [][]const u8, new: [][]const u8) [][]const u8 {
    var newStrings = std.ArrayList([]const u8).init(uwa.alloc);
    for (new) |str| {
        var found = false;
        for (old) |str2| {
            if (std.mem.eql(u8, str, str2)) {
                found = true;
            }
        }
        if (!found) {
            newStrings.append(str) catch {
                @panic("oom");
            };
        }
    }
    return newStrings.items;
}

pub fn nextEvent(context: *Context, options: *uwa.Options) !uwa.Event {
    const cwd = std.fs.cwd(); // current working directory
    var numIter: usize = 0;
    while (true) {
        // poll the files
        var filesIter = options.fileSet.iterator();

        // if a file has changed, send an event
        while (filesIter.next()) |filePtr| {
            const file = filePtr.*;
            const stat = cwd.statFile(file) catch {
                var i: usize = 0;
                // remove the file from the git repo files
                for (context.gitRepoFiles.items) |gitFile| {
                    if (std.mem.eql(u8, gitFile, file)) {
                        _ = context.gitRepoFiles.swapRemove(i);
                        break;
                    }
                    i += 1;
                }
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
            // check for new files in repo
            const newFiles = findNewStrings(context.gitRepoFiles.items, try uwa.getFilesInGitRepo(options.gitRepo));
            for (newFiles) |file| {
                const event = uwa.Event{ .etype = uwa.EventType.FileCreate, .fileName = file };
                try context.eventQueue.insert(0, event);
                try context.gitRepoFiles.append(file);
            }
            numIter = 0;
        }

        if (context.eventQueue.items.len > 0) {
            return context.eventQueue.pop();
        }

        // sleep for the polling interval
        std.time.sleep(1000000000 * 2); // 10 seconds
        numIter += 1;
    }
}
