const std = @import("std");

const uwaka = @import("mix.zig");
const cli = @import("cli.zig");

const stdout = std.io.getStdOut().writer();
var stderr = std.io.getStdErr().writer();

fn rebuildFileList(allocator: std.mem.Allocator, options: *uwaka.Options, context: ?uwaka.Context) !uwaka.Context {

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

fn runWakaTimeCli(filePath: []const u8, options: uwaka.Options, allocator: std.mem.Allocator) !void {
    // run wakatime-cli

    var argumentArray = std.ArrayList([]const u8).init(allocator);
    defer argumentArray.deinit();

    try argumentArray.append(options.wakatimeCliPath); // path to wakatime-cli

    try argumentArray.append("--entity");
    try argumentArray.append(filePath); // pass the file to wakatime cli

    try argumentArray.append("--guess-language"); // let wakatime cli guess the language
    try argumentArray.append("--plugin"); // pass the plugin name as specified, or default values if not
    const formattedEditor = try std.fmt.allocPrint(allocator, "uwaka-universal/{s} {s}-wakatime/{s}", .{ uwaka.VERSION, options.editorName, options.editorVersion });
    try argumentArray.append(formattedEditor);

    try argumentArray.append("--write"); // lets wakatime cli know that this is a write event (the file was saved)

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

fn sendHeartbeat(allocator: std.mem.Allocator, lastHeartbeat: *i64, options: uwaka.Options, event: uwaka.Event) !void {
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

    var options = try cli.parseArgs(allocator);
    defer options.fileSet.deinit();

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
