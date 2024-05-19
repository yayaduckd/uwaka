const std = @import("std");
// const stdout = std.io.getStdOut().writer();
// var stderr = std.io.getStdErr().writer();

const uwa = @import("mix.zig");

const Args = enum {
    help,
    wakatimeCliPath,
    editorName,
    editorVersion,
    gitRepo,
};

pub const TermFormat = struct {
    RED: []const u8 = "\x1b[31m",
    GREEN: []const u8 = "\x1b[32m",
    YELLOW: []const u8 = "\x1b[33m",
    BLUE: []const u8 = "\x1b[34m",
    MAGENTA: []const u8 = "\x1b[35m",
    CYAN: []const u8 = "\x1b[36m",
    WHITE: []const u8 = "\x1b[37m",

    RESET: []const u8 = "\x1b[0m",
    BOLD: []const u8 = "\x1b[1m",
    UNDERLINE: []const u8 = "\x1b[4m",
    INVERT: []const u8 = "\x1b[7m",
}{};

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
    uwa.stdout.print(helpText, .{}) catch {};
    std.process.exit(0);
}

fn printCliError(comptime format: []const u8, args: anytype) void {
    uwa.stdout.print("{s}{s}Error:{s} " ++ format, .{ TermFormat.RED, TermFormat.BOLD, TermFormat.RESET } ++ args) catch {};
    printHelp();
}

pub fn parseArgs(allocator: std.mem.Allocator) !uwa.Options {
    var options = uwa.Options{
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
                        try uwa.stdout.print("wakatime-cli version: ", .{});
                        _ = process.spawnAndWait() catch {
                            printCliError("\rError running wakatime-cli binary {s}. Verify that the path specified is a valid binary.\n", .{wakatimeCliPath});
                        };

                        options.wakatimeCliPath = wakatimeCliPath;
                    } else {
                        printCliError("Expected argument for {s}\n", .{arg});
                    }
                },
                Args.editorName => {
                    if (args.next()) |editorName| {
                        options.editorName = editorName;
                    } else {
                        printCliError("Expected argument for {s}\n", .{arg});
                    }
                },
                Args.editorVersion => {
                    if (args.next()) |editorVersion| {
                        options.editorVersion = editorVersion;
                    } else {
                        printCliError("Expected argument for {s}\n", .{arg});
                    }
                },
                Args.gitRepo => {
                    if (args.next()) |gitRepo| {
                        options.gitRepo = gitRepo;
                        var gitSet = try uwa.getFilesInGitRepo(options.gitRepo);
                        var iter = gitSet.iterator();
                        while (iter.next()) |file| {
                            try options.fileSet.insert(file.*);
                        }
                        gitSet.deinit();
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
        options.editorName = uwa.NAME;
        options.editorVersion = uwa.VERSION;
    }

    return options;
}
