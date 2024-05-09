const std = @import("std");
const logger = std.log.default;

const Args = enum { help };

const Options = struct {
    fileList: std.ArrayList([]const u8),
    help: bool,
};

const stdout = std.io.getStdOut().writer();
var stderr = std.io.getStdErr().writer();

fn parseArgs(allocator: std.mem.Allocator) !Options {
    var options = Options{ .help = false, .fileList = std.ArrayList([]const u8).init(allocator) };

    var args = try std.process.argsWithAllocator(allocator);

    const argMap = std.ComptimeStringMap(Args, &.{
        .{ "--help", Args.help },
        .{ "-h", Args.help },
    });

    _ = args.next(); // skip the first arg which is the program name
    // All args with -- will be options, others will be files to watch
    while (args.next()) |arg| {
        if (argMap.get(arg)) |argEnum| {
            switch (argEnum) {
                Args.help => options.help = true,
            }
        } else {
            try options.fileList.append(arg);
        }
    }

    return options;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const options = try parseArgs(allocator);
    defer options.fileList.deinit();

    if (options.help) {
        const helpText =
            \\Usage: uwaka [options] [file1 file2 ...]
            \\
            \\Options:
            \\  -h, --help  Display this help message
            \\
        ;
        try stdout.print(helpText, .{});
        return;
    }

    // init inotify
    const inotify = std.posix.inotify_init1(0); // no flags, potentially can set IN_NONBLOCK and/or IN_CLOEXEC

    const inotify_fd = inotify catch {
        try stderr.print("Failed to initialize inotify\n", .{});
        return;
    };
    defer std.posix.close(inotify_fd);

    logger.debug("Initialized inotify with fd {d}", .{inotify_fd});

    // add watch for all files in file list

    const cwd = std.fs.cwd(); // current working directory

    var wds = std.ArrayList(i32).init(allocator);
    for (options.fileList.items) |file| {
        logger.debug("Processing file {s}\n", .{file});
        const stat = cwd.statFile(file) catch {
            try stderr.print("Failed to stat file {s}\n", .{file});
            continue;
        };

        if (stat.kind != .file) {
            try stderr.print("File {s} is not a regular file. Ignored.\n", .{file});
            continue;
        }

        const wd = std.posix.inotify_add_watch(inotify_fd, file, std.os.linux.IN.MODIFY) catch {
            try stderr.print("Failed to add watch for file {s}\n", .{file});
            continue;
        };
        try wds.append(wd);

        logger.debug("Added watch for file {s} with wd {d}", .{ file, wd });
    }
    defer {
        for (wds.items) |wd| {
            std.posix.inotify_rm_watch(inotify_fd, wd);
            logger.debug("Deferred — Removed watch for wd {d}", .{wd});
        }
        wds.deinit();
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
