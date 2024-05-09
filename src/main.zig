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
    const inotify_fd = std.posix.inotify_init1(0) catch {
        try stderr.print("Failed to initialize inotify\n", .{});
        return;
    }; // no flags, potentially can set IN_NONBLOCK and/or IN_CLOEXEC

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
    if (wds.items.len == 0) {
        try stderr.print("No files to watch. Exiting.\n", .{});
        return;
    }

    // epic :) we initialized

    // define the inotify_event struct
    const InotifyEvent = extern struct {
        wd: i32,
        mask: u32,
        cookie: u32,
        len: u32,
        name: [0]u8,
    };

    // main loop
    const buffer = try allocator.alloc(u8, @sizeOf(InotifyEvent));
    while (true) {
        const events = std.ArrayList(InotifyEvent).init(allocator);
        defer events.deinit();

        // const defaultInotifyEvent = InotifyEvent{ .wd = 0, .mask = 0, .cookie = 0, .len = 0, .name = [_]u8{} };

        const bytesRead = std.posix.read(inotify_fd, buffer) catch {
            try stderr.print("Failed to read from inotify fd\n", .{});
            continue;
        };
        if (bytesRead != @sizeOf(InotifyEvent)) {
            try stderr.print("Read unexpected number of bytes from inotify fd\n", .{});
        }

        // parse as InotifyEvent
        const eventList: InotifyEvent = std.mem.bytesAsValue(InotifyEvent, buffer).*;

        try stdout.print("Event: {d} {d} {d} {d} {s}\n", .{
            eventList.wd,
            eventList.mask,
            eventList.cookie,
            eventList.len,
            eventList.name,
        });
    }
}
