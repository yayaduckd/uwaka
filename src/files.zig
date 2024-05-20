const uwa = @import("mix.zig");

const std = @import("std");

pub fn getFilesInGitRepo(repoPath: []const u8) !std.BufSet {
    // git ls-files --cached --others --exclude-standard
    // possible todo: switch to using libgit2 instead of shelling out to git
    var files = std.BufSet.init(uwa.alloc);

    const gitFilesResult = std.process.Child.run(.{
        .allocator = uwa.alloc,
        .argv = &.{ "git", "ls-files", "--cached", "--others", "--exclude-standard" },
        .cwd = repoPath,
    }) catch |err| {
        uwa.log.info("Error: unable to get files in git repo.", .{});
        return err;
    };
    defer uwa.alloc.free(gitFilesResult.stdout);
    defer uwa.alloc.free(gitFilesResult.stderr);

    const gitFiles = gitFilesResult.stdout;

    // split by newline
    var lines = std.mem.split(u8, gitFiles, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        const fullPath: []u8 = try std.fs.path.join(uwa.alloc, &.{ repoPath, line });
        try files.insert(fullPath);
        uwa.alloc.free(fullPath);
    }

    return files;
}

pub fn addBufSet(self: *std.BufSet, other: *std.BufSet) void {
    var it = other.iterator();
    while (it.next()) |entry| {
        self.insert(entry.*) catch {
            @panic("oom adding bufsets");
        };
    }
}

pub fn getFilesInFolder(folderPath: []const u8) !std.BufSet {
    var result = std.BufSet.init(uwa.alloc);
    // open folder
    var cwd = std.fs.cwd();
    var dir = cwd.openDir(folderPath, .{ .iterate = true }) catch |err| {
        try uwa.stderr.print("Could not open directory {s}", .{folderPath});
        return err;
    };
    // recursively search
    var walker = try dir.walk(uwa.alloc);
    while (try walker.next()) |entry| {
        if (entry.kind == std.fs.File.Kind.file or entry.kind == std.fs.File.Kind.sym_link) {
            const fullPath: []u8 = try std.fs.path.join(uwa.alloc, &.{ folderPath, entry.path });
            try result.insert(fullPath);
            uwa.alloc.free(fullPath);
        }
    }
    walker.deinit();
    dir.close();
    return result;
}
