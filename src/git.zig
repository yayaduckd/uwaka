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
