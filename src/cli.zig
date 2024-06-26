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
    disableTui,
};

const ESC = "\x1B";
pub const TermFormat = struct {
    RED: []const u8 = ESC ++ "[31m",
    GREEN: []const u8 = ESC ++ "[32m",
    YELLOW: []const u8 = ESC ++ "[33m",
    BLUE: []const u8 = ESC ++ "[34m",
    MAGENTA: []const u8 = ESC ++ "[35m",
    CYAN: []const u8 = ESC ++ "[36m",
    WHITE: []const u8 = ESC ++ "[37m",

    RESET: []const u8 = ESC ++ "[0m",
    BOLD: []const u8 = ESC ++ "[1m",
    UNDERLINE: []const u8 = ESC ++ "[4m",
    INVERT: []const u8 = ESC ++ "[7m",
}{};

fn printHelp() void {
    const helpText =
        \\Usage: uwaka [options] file1 file2 ...
        \\
        \\Specify files to track with wakatime. Will use the specified wakatime-cli binary to track the files, and the default wakatime config.
        \\
        \\Folders can also be specified, in which case all files in the folder and subfolders will be tracked.
        \\
        \\Options:
        \\  -h, --help  Display this help message
        \\  -w, --wakatime-cli-path  Path to wakatime-cli binary. REQUIRED.
        \\  -e, --editor-name  Name of editor to pass to wakatime. Defaults to "uwaka".
        \\  -r, --editor-version  Version of editor to pass to wakatime. Required if editor-name is set.
        \\  -g, --git-repo  Path to git repository.
        \\                  If set, uwaka will watch all tracked and untracked (but not ignored) files in the git repository.
        \\                  Multiple git repos can be set with multiple -g flags.
        \\ -t, --disable-tui  Disable the TUI. Will only log to stdout.
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
        .explicitFiles = uwa.FileSet.init(allocator),
        .fileSet = uwa.FileSet.init(allocator),
        .wakatimeCliPath = "",
        .editorName = "",
        .editorVersion = "",
        .tuiEnabled = true,
        .gitRepos = null,
        .explicitFolders = null,
    };

    var arena = std.heap.ArenaAllocator.init(uwa.alloc);
    defer arena.deinit();
    var args = try std.process.argsWithAllocator(arena.allocator());
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
        .{ "-t", Args.disableTui },
        .{ "--disable-tui", Args.disableTui },
    });

    const cwd = std.fs.cwd();
    _ = args.skip(); // skip the first arg which is the program name
    // All args with -- will be options, others will be files to watch
    while (args.next()) |arg| {
        if (argMap.get(arg)) |argEnum| {
            switch (argEnum) {
                Args.help => {
                    printHelp();
                },
                Args.wakatimeCliPath => {
                    if (args.next()) |wakatimeCliPath| {
                        if (options.wakatimeCliPath.len != 0) {
                            printCliError("Wakatime cli path specified multiple times. Make up your mind!\n", .{});
                        }

                        // validate that the path contains the wakatime-cli binary
                        // test run it
                        var process = std.process.Child.init(&.{ wakatimeCliPath, "--version" }, allocator);
                        try uwa.stdout.print("wakatime-cli version: ", .{});
                        _ = process.spawnAndWait() catch {
                            printCliError("Error running wakatime-cli binary {s}. Verify that the path specified is a valid binary.\n", .{wakatimeCliPath});
                        };

                        options.wakatimeCliPath = try uwa.alloc.dupe(u8, wakatimeCliPath);
                    } else {
                        printCliError("Expected argument for {s}\n", .{arg});
                    }
                },
                Args.editorName => {
                    if (options.editorName.len != 0) {
                        printCliError("Editor name specified multiple times. Make up your mind!\n", .{});
                    }

                    if (args.next()) |editorName| {
                        options.editorName = try uwa.alloc.dupe(u8, editorName);
                    } else {
                        printCliError("Expected argument for {s}\n", .{arg});
                    }
                },
                Args.editorVersion => {
                    if (options.editorVersion.len != 0) {
                        printCliError("Editor version specified multiple times. Make up your mind!\n", .{});
                    }

                    if (args.next()) |editorVersion| {
                        options.editorVersion = try uwa.alloc.dupe(u8, editorVersion);
                    } else {
                        printCliError("Expected argument for {s}\n", .{arg});
                    }
                },
                Args.disableTui => {
                    options.tuiEnabled = false;
                },
                Args.gitRepo => {
                    if (args.next()) |gitRepo| {
                        options.gitRepos = options.gitRepos orelse blk: {
                            // check if git is installed
                            // test run it
                            const result = std.process.Child.run(.{
                                .allocator = allocator,
                                .argv = &.{ "git", "version" },
                                .cwd = gitRepo,
                            }) catch {
                                printCliError("Unable to run git. Verify it is installed and available on PATH.", .{});
                                unreachable;
                            };
                            allocator.free(result.stdout);
                            allocator.free(result.stderr);

                            break :blk uwa.FileSet.init(allocator);
                        };

                        try options.gitRepos.?.insert(gitRepo);
                        var gitSet = try uwa.getFilesInGitRepo(gitRepo);
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
            // argument is a file
            // stat file
            const file = try std.fs.path.resolve(uwa.alloc, &.{arg});

            var isDirectory = false;
            const stat = cwd.statFile(file);
            if (stat == std.posix.OpenError.IsDir) {
                isDirectory = true;
            } else {
                const noErrorStat = stat catch {
                    printCliError("Could not stat file {s}. Verify it exists.\n", .{arg});
                    unreachable;
                };
                isDirectory = noErrorStat.kind == std.fs.File.Kind.directory;
            }

            if (isDirectory) {
                options.explicitFolders = options.explicitFolders orelse uwa.FileSet.init(allocator);
                try options.explicitFolders.?.insert(arg);

                var filesFound = try uwa.getFilesInFolder(arg);
                uwa.addFileSet(&options.fileSet, &filesFound);
                filesFound.deinit();
            } else {
                try options.fileSet.insert(arg);
                try options.explicitFiles.insert(arg);
            }
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
