const uwaka = @import("mix.zig");

const std = @import("std");
var stderr = std.io.getStdErr().writer();

pub fn getFilesInGitRepo(repoPath: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var files = std.ArrayList([]const u8).init(allocator);

    // get tracked files
    // git ls-tree --name-only -r HEAD
    const trackedResult = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "ls-tree", "--name-only", "-r", "HEAD" },
        .cwd = repoPath,
    }) catch |err| {
        try stderr.print("Error: unable to get tracked files in git repo.", .{});
        return err;
    };

    const trackedFiles = trackedResult.stdout;
    // split by newline
    var lines = std.mem.split(u8, trackedFiles, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        try files.append(line);
    }

    // get untracked files
    // find lines starting with ?? in git status --short
    const untrackedResult = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "status", "--short" },
        .cwd = repoPath,
    }) catch |err| {
        try stderr.print("Error: unable to get untracked files in git repo.", .{});
        return err;
    };

    const untrackedFiles = untrackedResult.stdout;
    var untrackedLines = std.mem.split(u8, untrackedFiles, "\n");
    while (untrackedLines.next()) |line| {
        if (line.len < 3) {
            continue;
        }
        if (line[0] == '?' and line[1] == '?') {
            try files.append(line[3..]);
        }
    }

    return files.items;
}
