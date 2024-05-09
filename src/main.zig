const std = @import("std");

const uwaka = @import("mix.zig");

const Args = enum { help };

pub const Options = struct {
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

    // add watch for all files in file list

    const context = try uwaka.initWatching(options, allocator);

    // main loop
    while (true) {
        const event = try uwaka.nextEvent(context);

        try stdout.print("Event: {} {s}\n", .{
            event.etype,
            event.fileName,
        });
    }
}
