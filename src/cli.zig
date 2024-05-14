const std = @import("std");
const stdout = std.io.getStdOut().writer();
var stderr = std.io.getStdErr().writer();

const uwaka = @import("mix.zig");

const Args = enum {
    help,
    wakatimeCliPath,
    editorName,
    editorVersion,
    gitRepo,
};

const TERM_RED = "\x1b[31m";
const TERM_RESET = "\x1b[0m";
const TERM_BOLD = "\x1b[1m";

fn printHelp() void {
    const helpText =
        \\Usage: uwaka [options] file1 file2 ...
        \\
        \\Specify files to track with wakatime. Will use the specified wakatime-cli binary to track the files, and the default wakatime config.
        \\
        \\Options:
        \\  -h, --help  Display this help message
        \\  -w, --wakatime-cli-path  Path to wakatime-cli binary. REQUIRED.
        \\  -e, --editor-name  Name of editor to pass to wakatime. Defaults to "uwaka".
        \\  -r, --editor-version  Version of editor to pass to wakatime. Required if editor-name is set.
        \\  -g, --git-repo  Path to git repository. If set, uwaka will watch all tracked and untracked (but not ignored) files in the git repository.
        \\
    ;
    stdout.print(helpText, .{}) catch {
        @panic("Failed to print help text");
    };
    std.process.exit(0);
}

fn printCliError(comptime format: []const u8, args: anytype) void {
    stderr.print("{s}{s}Error:{s} " ++ format ++ "\n", .{ TERM_BOLD, TERM_RED, TERM_RESET } ++ args) catch unreachable;
    printHelp();
}

pub fn parseArgs(allocator: std.mem.Allocator) !uwaka.Options {
    var options = uwaka.Options{
        .explicitFiles = std.BufSet.init(allocator),
        .fileSet = std.BufSet.init(allocator),
        .wakatimeCliPath = "",
        .editorName = "",
        .editorVersion = "",
        .gitRepo = "",
    };

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const argMap = std.ComptimeStringMap(Args, &.{
        .{ "--help", Args.help },
        .{ "-h", Args.help },
        .{ "--wakatime-cli-path", Args.wakatimeCliPath },
        .{ "-w", Args.wakatimeCliPath },
        .{ "--editor-name", Args.editorName },
        .{ "-e", Args.editorName },
        .{ "--editor-version", Args.editorVersion },
        .{ "-r", Args.editorVersion },
        .{ "--git-repo", Args.gitRepo },
        .{ "-g", Args.gitRepo },
    });

    _ = args.next(); // skip the first arg which is the program name
    // All args with -- will be options, others will be files to watch
    while (args.next()) |arg| {
        if (argMap.get(arg)) |argEnum| {
            switch (argEnum) {
                Args.help => {
                    printHelp();
                },
                Args.wakatimeCliPath => {
                    if (args.next()) |wakatimeCliPath| {

                        // validate that the path contains the wakatime-cli binary
                        // test run it
                        var process = std.process.Child.init(&.{ wakatimeCliPath, "--version" }, allocator);
                        try stdout.print("wakatime-cli version: ", .{});
                        _ = process.spawnAndWait() catch {
                            printCliError("\rError running wakatime-cli binary {s}. Verify that the path specified is a valid binary.\n", .{wakatimeCliPath});
                        };

                        options.wakatimeCliPath = try allocator.dupe(u8, wakatimeCliPath);
                    } else {
                        printCliError("Expected argument for {s}\n", .{arg});
                    }
                },
                Args.editorName => {
                    if (args.next()) |editorName| {
                        options.editorName = try allocator.dupe(u8, editorName);
                    } else {
                        printCliError("Expected argument for {s}\n", .{arg});
                    }
                },
                Args.editorVersion => {
                    if (args.next()) |editorVersion| {
                        options.editorVersion = try allocator.dupe(u8, editorVersion);
                    } else {
                        printCliError("Expected argument for {s}\n", .{arg});
                    }
                },
                Args.gitRepo => {
                    if (args.next()) |gitRepo| {
                        options.gitRepo = try allocator.dupe(u8, gitRepo);
                        const files = try uwaka.getFilesInGitRepo(options.gitRepo, allocator);
                        for (files) |file| {
                            try options.fileSet.insert(file);
                        }
                    } else {
                        printCliError("Expected argument for {s}\n", .{arg});
                    }
                },
            }
        } else {
            try options.fileSet.insert(arg);
            try options.explicitFiles.insert(arg);
        }
    }

    if (options.fileSet.count() == 0) {
        printCliError("No files to watch. Use -h to display help.\n", .{});
    } else if (options.wakatimeCliPath.len == 0) {
        printCliError("\rwakatime-cli path not set.\n", .{});
    } else if ((options.editorName.len != 0 and options.editorVersion.len == 0) or (options.editorName.len == 0 and options.editorVersion.len != 0)) {
        printCliError("\rEditor version or editor name not set.\n", .{});
    }

    if (options.editorName.len == 0) {
        options.editorName = uwaka.NAME;
        options.editorVersion = uwaka.VERSION;
    }

    return options;
}
