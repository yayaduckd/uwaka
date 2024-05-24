const std = @import("std");

const uwa = @import("mix.zig");
const cli = @import("cli.zig");

fn runWakaTimeCli(filePath: []const u8, options: *uwa.Options) !void {
    // run wakatime-cli

    var argumentArray = std.ArrayList([]const u8).init(uwa.alloc);
    defer argumentArray.deinit();

    try argumentArray.append(options.wakatimeCliPath); // path to wakatime-cli

    try argumentArray.append("--entity");
    try argumentArray.append(filePath); // pass the file to wakatime cli

    try argumentArray.append("--guess-language"); // let wakatime cli guess the language
    try argumentArray.append("--plugin"); // pass the plugin name as specified, or default values if not
    const formattedEditor = try std.fmt.allocPrint(uwa.alloc, "uwaka-universal/{s} {s}-wakatime/{s}", .{ uwa.VERSION, options.editorName, options.editorVersion });
    try argumentArray.append(formattedEditor);
    defer uwa.alloc.free(formattedEditor);

    try argumentArray.append("--write"); // lets wakatime cli know that this is a write event (the file was saved)

    var process = std.process.Child.init(argumentArray.items, uwa.alloc);

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

// returns true if a heartbeat was sent, false otherwise
pub fn sendHeartbeat(lastHeartbeat: i64, options: *uwa.Options, event: uwa.Event) !bool {
    const HEARTBEAT_INTERVAL = 1000 * 60 * 2; // 2 mins (in milliseconds)
    const currentTime = std.time.milliTimestamp();

    const isWrite = event.etype == uwa.EventType.FileChange;
    if (!isWrite and currentTime - lastHeartbeat < HEARTBEAT_INTERVAL) {
        return false;
    }
    runWakaTimeCli(event.fileName, options) catch {
        @panic("Error sending event info to wakatime cli.");
    };

    return true;
}

pub fn shutdown(context: *uwa.Context, options: *uwa.Options) void {
    uwa.deInitWatching(context);
    options.fileSet.deinit();
    options.explicitFiles.deinit();
    uwa.alloc.free(options.wakatimeCliPath);
    if (options.gitRepos) |repos| {
        _ = repos;
        options.gitRepos.?.deinit();
    }
    if (options.explicitFolders) |folders| {
        _ = folders;
        options.explicitFolders.?.deinit();
    }

    // deinit allocator
    _ = uwa.gpa.deinit();
    std.process.exit(0);
}

pub fn main() !void {
    // initialize writer
    if (uwa.osTag == .windows) {
        uwa.stdout = std.io.getStdOut().writer();
        uwa.stderr = std.io.getStdErr().writer();
    }
    uwa.log.info("Running on {s}", .{@tagName(uwa.osTag)});

    var options = try cli.parseArgs(uwa.alloc);
    uwa.log.debug("Wakatime cli path: {s}", .{options.wakatimeCliPath});
    const tui = try uwa.TuiData.init(&options);

    // add watch for all files in file list

    var context = try uwa.initWatching(&options);

    // main loop
    var eventQueue = uwa.EventQueue.init(uwa.alloc);
    _ = try std.Thread.spawn(.{}, pollEvents, .{ &context, &options, &eventQueue });
    while (true) {
        const event = eventQueue.pop();
        if (event) |e| {
            uwa.log.debug("Event: {} {s}", .{
                e.etype,
                e.fileName,
            });

            uwa.handleEvent(e, &options, &context) catch {
                try uwa.stderr.print("Error handling event {any}", .{e});
                @panic("Error handling event");
            };
        }
        try uwa.updateTui(tui, event, &options);
        std.time.sleep(1000000 * 1000); // 10ms
    }
}

fn pollEvents(context: *uwa.Context, options: *uwa.Options, eventQueue: *uwa.EventQueue) void {
    // poll for events
    while (true) {
        const e = uwa.nextEvent(context, options) catch {
            @panic("Error getting next event");
        };
        eventQueue.push(e) catch @panic("oom");
    }
}
