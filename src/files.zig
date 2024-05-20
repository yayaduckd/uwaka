const uwa = @import("mix.zig");

const std = @import("std");

pub fn getFilesInGitRepo(repoPath: []const u8) !FileSet {
    // git ls-files --cached --others --exclude-standard
    // possible todo: switch to using libgit2 instead of shelling out to git
    var files = FileSet.init(uwa.alloc);

    const resolvedRepoPath = try std.fs.path.resolve(uwa.alloc, &.{repoPath});
    const gitFilesResult = std.process.Child.run(.{
        .allocator = uwa.alloc,
        .argv = &.{ "git", "ls-files", "--cached", "--others", "--exclude-standard" },
        .cwd = resolvedRepoPath,
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
        const fullPath: []u8 = try std.fs.path.join(uwa.alloc, &.{ resolvedRepoPath, line });
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

pub fn addFileSet(self: *FileSet, other: *FileSet) void {
    var it = other.iterator();
    while (it.next()) |entry| {
        self.insert(entry.*) catch {
            @panic("oom adding filesets");
        };
    }
}

/// A FileSet is almost identical to a BufSet, but it stores files.
/// It will resolve paths before storing them.
pub const FileSet = struct {
    const Allocator = std.mem.Allocator;
    const BufSet = std.BufSet;
    const BufSetHashMap = std.StringHashMap(void);
    pub const Iterator = BufSetHashMap.KeyIterator;

    usingnamespace std;
    bufSet: BufSet,
    allocator: Allocator,

    pub fn init(a: Allocator) FileSet {
        return .{ .bufSet = BufSet.init(a), .allocator = a };
    }

    /// Free a BufSet along with all stored keys.
    pub fn deinit(self: *FileSet) void {
        self.bufSet.deinit();
        self.* = undefined;
    }

    /// Insert an item into the BufSet.  The item will be
    /// copied, so the caller may delete or reuse the
    /// passed string immediately.
    pub fn insert(self: *FileSet, value: []const u8) !void {
        const resolvedPath = try std.fs.path.resolve(self.allocator, &.{value});
        try self.bufSet.insert(resolvedPath);
    }

    /// Check if the set contains an item matching the passed string
    pub fn contains(self: FileSet, value: []const u8) bool {
        return self.bufSet.contains(value);
    }

    /// Remove an item from the set.
    pub fn remove(self: *FileSet, value: []const u8) void {
        self.bufSet.remove(value);
    }

    /// Returns the number of items stored in the set
    pub fn count(self: *const FileSet) usize {
        return self.bufSet.count();
    }

    /// Returns an iterator over the items stored in the set.
    /// Iteration order is arbitrary.
    pub fn iterator(self: *const FileSet) Iterator {
        return self.bufSet.iterator();
    }

    /// Get the allocator used by this set
    pub fn allocator(self: *const FileSet) Allocator {
        return self.bufSet.allocator();
    }

    fn free(self: *const FileSet, value: []const u8) void {
        self.bufSet.allocator().free(value);
    }

    fn copy(self: *const FileSet, value: []const u8) ![]const u8 {
        return self.bufSet.copy(value);
    }
};

pub fn addPathToBufSet(bufset: *std.BufSet, path: []const u8) !void {
    // resolve
    const resolvedPath = try std.fs.path.resolve(uwa.alloc, &.{path});
    try bufset.insert(resolvedPath);
}

pub fn getFilesInFolder(folderPath: []const u8) !FileSet {
    var result = FileSet.init(uwa.alloc);
    // open folder
    var cwd = std.fs.cwd();
    const resolvedFolderPath = try std.fs.path.resolve(uwa.alloc, &.{folderPath});
    defer uwa.alloc.free(resolvedFolderPath);
    var dir = cwd.openDir(resolvedFolderPath, .{ .iterate = true }) catch |err| {
        try uwa.stderr.print("Could not open directory {s}", .{resolvedFolderPath});
        return err;
    };
    // recursively search
    var walker = try dir.walk(uwa.alloc);
    while (try walker.next()) |entry| {
        if (entry.kind == std.fs.File.Kind.file or entry.kind == std.fs.File.Kind.sym_link) {
            const fullPath: []u8 = try std.fs.path.join(uwa.alloc, &.{ resolvedFolderPath, entry.path });
            try result.insert(fullPath);
            uwa.alloc.free(fullPath);
        }
    }
    walker.deinit();
    dir.close();
    return result;
}

pub fn getFilesinGitReposAndFolders(options: *uwa.Options) !FileSet {
    var result = FileSet.init(uwa.alloc);
    if (options.gitRepos) |repos| {
        var reposIter = repos.iterator();
        while (reposIter.next()) |repo| {
            var files = getFilesInGitRepo(repo.*) catch |err| {
                return err;
            };
            addFileSet(&result, &files);
        }
    }
    if (options.explicitFolders) |folders| {
        var foldersIter = folders.iterator();
        while (foldersIter.next()) |folder| {
            var files = getFilesInFolder(folder.*) catch |err| {
                return err;
            };
            addFileSet(&result, &files);
        }
    }
    return result;
}
