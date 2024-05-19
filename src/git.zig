const uwa = @import("mix.zig");

const std = @import("std");

pub fn getFilesInGitRepo(repoPath: []const u8) ![][]const u8 {
    // git ls-files --cached --others --exclude-standard $(git rev-parse --show-toplevel)
    // possible todo: switch to using libgit2 instead of shelling out to git
    var files = std.ArrayList([]const u8).init(uwa.alloc);
    defer files.deinit();

    const gitFilesResult = std.process.Child.run(.{
        .allocator = uwa.alloc,
        .argv = &.{ "git", "ls-files", "--cached", "--others", "--exclude-standard" },
        .cwd = repoPath,
    }) catch |err| {
        uwa.log.info("Error: unable to get files in git repo.", .{});
        return err;
    };

    const gitFiles = gitFilesResult.stdout;

    // split by newline
    var lines = std.mem.split(u8, gitFiles, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        const fullPath: []u8 = try std.fs.path.join(uwa.alloc, &.{ repoPath, line });
        try files.append(fullPath);
    }

    return files.toOwnedSlice();
}
