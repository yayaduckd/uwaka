const std = @import("std");

const uwa = @import("mix.zig");
const cli = @import("cli.zig");

fn rebuildFileList(options: *uwa.Options, context: ?*uwa.Context) !uwa.Context {

    // clear fileset
    options.fileSet.deinit();

    // add all files in the git repo
    if (options.gitRepo) |path| {
        options.fileSet = try uwa.getFilesInGitRepo(path);
    }

    // add all explicitly added files
    var explicitFileIterator = options.explicitFiles.iterator();
    while (explicitFileIterator.next()) |file| {
        try options.fileSet.insert(file.*);
    }

    if (context) |ctx| {
        // clear the context
        uwa.deInitWatching(ctx);
    }
    // re-init the context
    const ctx = try uwa.initWatching(options);
    return ctx;
}

fn runWakaTimeCli(filePath: []const u8, options: uwa.Options) !void {
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
fn sendHeartbeat(lastHeartbeat: i64, options: uwa.Options, event: uwa.Event) !bool {
    const HEARTBEAT_INTERVAL = 1000 * 60 * 2; // 2 mins (in milliseconds)
    const currentTime = std.time.milliTimestamp();

    const isWrite = event.etype == uwa.EventType.FileChange;
    if (!isWrite and currentTime - lastHeartbeat < HEARTBEAT_INTERVAL) {
        return false;
    }
    runWakaTimeCli(event.fileName, options) catch {
        @panic("Error sending event info to wakatime cli.");
    };
    try uwa.stdout.print("Heartbeat sent for " ++
        cli.TermFormat.GREEN ++ cli.TermFormat.BOLD ++ "{}" ++ cli.TermFormat.RESET ++
        " on file {s}.\n", .{ event.etype, event.fileName });
    return true;
}

fn shutdown(context: *uwa.Context, options: *uwa.Options) void {
    uwa.deInitWatching(context);
    options.fileSet.deinit();
    options.explicitFiles.deinit();
    uwa.alloc.free(options.editorName);
    uwa.alloc.free(options.editorVersion);
    uwa.alloc.free(options.wakatimeCliPath);
    if (options.gitRepo) |path| {
        uwa.alloc.free(path);
    }

    // deinit allocator
    _ = uwa.gpa.deinit();
    std.process.exit(0);
}

pub fn main() !void {
    // initialize writer
    if (std.mem.eql(u8, uwa.osTag, "windows")) {
        uwa.stdout = std.io.getStdOut().writer();
        uwa.stderr = std.io.getStdErr().writer();
    }
    uwa.log.info("Running on {s}", .{uwa.osTag});

    var options = try cli.parseArgs(uwa.alloc);

    uwa.log.debug("Wakatime cli path: {s}", .{options.wakatimeCliPath});

    // add watch for all files in file list

    var context = try uwa.initWatching(&options);
    var lastEventTime = std.time.milliTimestamp();
    const DEBOUNCE_TIME = 5000; // 5 seconds
    var lastHeartbeat: i64 = std.time.milliTimestamp() - 1000 * 60 * 2; // 2 mins ago
    // main loop
    while (true) {
        const event = try uwa.nextEvent(&context, &options);

        uwa.log.debug("Event: {} {s}", .{
            event.etype,
            event.fileName,
        });

        switch (event.etype) {
            uwa.EventType.FileChange => {
                const currentTime = std.time.milliTimestamp();
                if (currentTime - lastEventTime < DEBOUNCE_TIME) {
                    uwa.log.debug("event ignored at time {}", .{currentTime});
                    lastEventTime = currentTime;
                    continue;
                }

                if (std.mem.eql(u8, event.fileName, ".gitignore")) {
                    // rebuild file list
                    uwa.log.debug("Rebuilding file list due to .gitignore change", .{});
                    context = try rebuildFileList(&options, &context);
                }

                const sent = try sendHeartbeat(lastHeartbeat, options, event);
                if (sent) {
                    lastHeartbeat = currentTime;
                }
                lastEventTime = currentTime;
            },
            uwa.EventType.FileCreate, uwa.EventType.FileMove => {
                // rebuild file list
                context = try rebuildFileList(&options, &context);
            },
            uwa.EventType.FileDelete => {
                options.fileSet.remove(event.fileName);
                options.explicitFiles.remove(event.fileName);
            },
            else => {
                uwa.log.err("Unknown event type: {}", .{event.etype});
            },
        }
    }
}
