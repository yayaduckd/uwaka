const std = @import("std");

const uwaka = @import("mix.zig");

const Args = enum {
    help,
    wakatimeCliPath,
};

pub const Options = struct {
    fileList: std.ArrayList([]const u8), // list of files to watch
    help: bool, // whether to show help
    wakatimeCliPath: ?[]const u8, // path to wakatime-cli binary
};

const stdout = std.io.getStdOut().writer();
var stderr = std.io.getStdErr().writer();

fn parseArgs(allocator: std.mem.Allocator) !Options {
    var options = Options{
        .help = false,
        .fileList = std.ArrayList([]const u8).init(allocator),
        .wakatimeCliPath = null,
    };

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const argMap = std.ComptimeStringMap(Args, &.{
        .{ "--help", Args.help },
        .{ "-h", Args.help },
        .{ "--wakatime-cli-path", Args.wakatimeCliPath },
        .{ "-w", Args.wakatimeCliPath },
    });

    _ = args.next(); // skip the first arg which is the program name
    // All args with -- will be options, others will be files to watch
    while (args.next()) |arg| {
        if (argMap.get(arg)) |argEnum| {
            switch (argEnum) {
                Args.help => options.help = true,
                Args.wakatimeCliPath => {
                    if (args.next()) |wakatimeCliPath| {

                        // validate that the path contains the wakatime-cli binary
                        // test run it
                        var process = std.process.Child.init(&.{ wakatimeCliPath, "--version" }, allocator);
                        try stdout.print("wakatime-cli version: ", .{});
                        process.spawn() catch {
                            try stderr.print("\rError running wakatime-cli binary {s}. Verify that the path specified is a valid binary.\n", .{wakatimeCliPath});
                            std.process.exit(0);
                        };
                        _ = process.wait() catch {
                            try stderr.print("\rError running wakatime-cli binary {s}. Verify that the path specified is a valid binary.\n", .{wakatimeCliPath});
                            std.process.exit(0);
                        };

                        options.wakatimeCliPath = try allocator.dupe(u8, wakatimeCliPath);
                    } else {
                        try stderr.print("Expected argument for --wakatime-cli-path\n", .{});
                        std.process.exit(0);
                    }
                },
            }
        } else {
            try options.fileList.append(arg);
        }
    }

    if (options.fileList.items.len == 0) {
        try stderr.print("No files to watch\n", .{});
        std.process.exit(0);
    } else if (options.wakatimeCliPath == null) {
        try stderr.print("\rwakatime-cli path not set.\n", .{});
        std.process.exit(0);
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
            \\  -w, --wakatime-cli-path  Path to wakatime-cli binary
            \\
        ;
        try stdout.print(helpText, .{});
        return;
    }
    uwaka.log.debug("Wakatime cli path: {s}", .{options.wakatimeCliPath orelse "not set"});

    // add watch for all files in file list

    const context = try uwaka.initWatching(options, allocator);

    var lastEventTime = std.time.milliTimestamp();
    const DEBOUNCE_TIME = 100;
    // main loop
    while (true) {
        const event = try uwaka.nextEvent(context);
        const currentTime = std.time.milliTimestamp();
        if (currentTime - lastEventTime < DEBOUNCE_TIME) {
            continue;
        }
        lastEventTime = currentTime;

        try stdout.print("Event: {} {s}\n", .{
            event.etype,
            event.fileName,
        });
    }
}
