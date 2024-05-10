const std = @import("std");

const uwaka = @import("mix.zig");

const Args = enum {
    help,
    wakatimeCliPath,
    editorName,
    editorVersion,
    gitRepo,
};

pub const Options = struct {
    explicitFiles: std.BufSet, // list of files to watch
    fileSet: std.BufSet, // list of files to watch
    help: bool, // whether to show help
    wakatimeCliPath: []const u8, // path to wakatime-cli binary
    editorName: []const u8, // name of editor to pass to wakatime
    editorVersion: []const u8, // version of editor to pass to wakatime
    gitRepo: []const u8, // git repo to pass to wakatime
};

const stdout = std.io.getStdOut().writer();
var stderr = std.io.getStdErr().writer();

fn parseArgs(allocator: std.mem.Allocator) !Options {
    var options = Options{
        .explicitFiles = std.BufSet.init(allocator),
        .fileSet = std.BufSet.init(allocator),
        .help = false,
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
                Args.help => options.help = true,
                Args.wakatimeCliPath => {
                    if (args.next()) |wakatimeCliPath| {

                        // validate that the path contains the wakatime-cli binary
                        // test run it
                        var process = std.process.Child.init(&.{ wakatimeCliPath, "--version" }, allocator);
                        try stdout.print("wakatime-cli version: ", .{});
                        _ = process.spawnAndWait() catch {
                            try stderr.print("\rError running wakatime-cli binary {s}. Verify that the path specified is a valid binary.\n", .{wakatimeCliPath});
                            std.process.exit(0);
                        };

                        options.wakatimeCliPath = try allocator.dupe(u8, wakatimeCliPath);
                    } else {
                        try stderr.print("Expected argument for --wakatime-cli-path\n", .{});
                        std.process.exit(0);
                    }
                },
                Args.editorName => {
                    if (args.next()) |editorName| {
                        options.editorName = try allocator.dupe(u8, editorName);
                    } else {
                        try stderr.print("Expected argument for --editor-name\n", .{});
                        std.process.exit(0);
                    }
                },
                Args.editorVersion => {
                    if (args.next()) |editorVersion| {
                        options.editorVersion = try allocator.dupe(u8, editorVersion);
                    } else {
                        try stderr.print("Expected argument for --editor-version\n", .{});
                        std.process.exit(0);
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
                        try stderr.print("Expected argument for --git-repo\n", .{});
                        std.process.exit(0);
                    }
                },
            }
        } else {
            try options.fileSet.insert(arg);
            try options.explicitFiles.insert(arg);
        }
    }

    if (options.fileSet.count() == 0) {
        try stderr.print("No files to watch\n", .{});
        std.process.exit(0);
    } else if (options.wakatimeCliPath.len == 0) {
        try stderr.print("\rwakatime-cli path not set.\n", .{});
        std.process.exit(0);
    } else if ((options.editorName.len != 0 and options.editorVersion.len == 0) or (options.editorName.len == 0 and options.editorVersion.len != 0)) {
        try stderr.print("\rEditor version or editor name not set.\n", .{});
        std.process.exit(0);
    }

    if (options.editorName.len == 0) {
        options.editorName = uwaka.NAME;
        options.editorVersion = uwaka.VERSION;
    }

    return options;
}

fn rebuildFileList(allocator: std.mem.Allocator, options: *Options, context: ?uwaka.Context) !uwaka.Context {

    // clear fileset
    options.fileSet.deinit();
    // new hashset
    var newFileSet = std.BufSet.init(allocator);

    // add all explicitly added files
    var explicitFileIterator = options.explicitFiles.iterator();
    while (explicitFileIterator.next()) |file| {
        try newFileSet.insert(file.*);
    }

    // add all files in the git repo
    if (options.gitRepo.len > 0) {
        const files = try uwaka.getFilesInGitRepo(options.gitRepo, allocator);
        for (files) |file| {
            try newFileSet.insert(file);
        }
    }

    // re-assign the new fileset
    options.fileSet = newFileSet;

    if (context) |ctx| {
        // clear the context
        uwaka.deInitWatching(ctx);
    }
    // re-init the context
    const ctx = try uwaka.initWatching(options, allocator);
    return ctx;
}

fn runWakaTimeCli(filePath: []const u8, options: Options, allocator: std.mem.Allocator) !void {
    // run wakatime-cli

    var argumentArray = std.ArrayList([]const u8).init(allocator);
    defer argumentArray.deinit();

    try argumentArray.append(options.wakatimeCliPath);
    try argumentArray.append("--entity");
    try argumentArray.append(filePath);

    try argumentArray.append("--guess-language");
    try argumentArray.append("--plugin");
    const formattedEditor = try std.fmt.allocPrint(allocator, "uwaka-universal/{s} {s}-wakatime/{s}", .{ uwaka.VERSION, options.editorName, options.editorVersion });
    try argumentArray.append(formattedEditor);

    try argumentArray.append("--write");

    var process = std.process.Child.init(argumentArray.items, allocator);

    _ = process.spawnAndWait() catch {
        @panic("Error running wakatime-cli binary");
    };
}

// From the WakaTime docs:
// This is a high-level overview of a WakaTime plugin from the time it's loaded, until the editor is exited.

//     Plugin loaded by text editor/IDE, runs plugin's initialization code
//     Initialization code
//         Setup any global variables, like plugin version, editor/IDE version
//         Check for wakatime-cli, or download into ~/.wakatime/ if missing or needs an update
//         Check for api key in ~/.wakatime.cfg, prompt user to enter if does not exist
//         Setup event listeners to detect when current file changes, a file is modified, and a file is saved
//     Current file changed (our file change event listener code is run)
//         go to Send heartbeat function with isWrite false
//     User types in a file (our file modified event listener code is run)
//         go to Send heartbeat function with isWrite false
//     A file is saved (our file save event listener code is run)
//         go to Send heartbeat function with isWrite true
//     Send heartbeat function
//         check lastHeartbeat variable. if isWrite is false, and file has not changed since last heartbeat, and less than 2 minutes since last heartbeat, then return and do nothing
//         run wakatime-cli in background process passing it the current file
//         update lastHeartbeat variable with current file and current time

fn sendHeartbeat(allocator: std.mem.Allocator, lastHeartbeat: *i64, options: Options, event: uwaka.Event) !void {
    const HEARTBEAT_INTERVAL = 1000 * 60 * 2; // 2 mins (in milliseconds)
    const currentTime = std.time.milliTimestamp();

    const isWrite = event.etype == uwaka.EventType.FileChange;
    if (!isWrite and currentTime - lastHeartbeat.* < HEARTBEAT_INTERVAL) {
        return;
    }
    runWakaTimeCli(event.fileName, options, allocator) catch {
        @panic("Error running wakatime-cli binary");
    };
    uwaka.log.debug("Heartbeat sent for event {} on file {s}.", .{ event.etype, event.fileName });
    lastHeartbeat.* = currentTime;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var options = try parseArgs(allocator);
    defer options.fileSet.deinit();

    if (options.help) {
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
        try stdout.print(helpText, .{});
        return;
    }
    uwaka.log.debug("Wakatime cli path: {s}", .{options.wakatimeCliPath});

    // add watch for all files in file list

    var context = try uwaka.initWatching(&options, allocator);

    var lastEventTime = std.time.milliTimestamp();
    const DEBOUNCE_TIME = 1000; // 1 second
    const lastHeartbeat: *i64 = try allocator.create(i64);
    lastHeartbeat.* = std.time.milliTimestamp() - 1000 * 60 * 2; // 2 mins ago
    defer allocator.destroy(lastHeartbeat);
    // main loop
    while (true) {
        const event = try uwaka.nextEvent(&context, &options);

        uwaka.log.debug("Event: {} {s}", .{
            event.etype,
            event.fileName,
        });

        switch (event.etype) {
            uwaka.EventType.FileChange => {
                const currentTime = std.time.milliTimestamp();
                if (currentTime - lastEventTime < DEBOUNCE_TIME) {
                    uwaka.log.debug("event ignored at time {}", .{currentTime});
                    lastEventTime = currentTime;
                    continue;
                }

                if (std.mem.eql(u8, event.fileName, ".gitignore")) {
                    // rebuild file list
                    uwaka.log.debug("Rebuilding file list due to .gitignore change", .{});
                    context = try rebuildFileList(allocator, &options, context);
                }

                lastEventTime = currentTime;
                try sendHeartbeat(allocator, lastHeartbeat, options, event);
            },
            uwaka.EventType.FileCreate, uwaka.EventType.FileMove, uwaka.EventType.FileDelete => {
                // rebuild file list
                context = try rebuildFileList(allocator, &options, context);
            },
            else => {
                try stderr.print("Unknown event type: {}\n", .{event.etype});
            },
        }
    }
}
