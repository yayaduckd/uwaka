const std = @import("std");

const uwa = @import("mix.zig");
const cli = @import("cli.zig");

pub const std_options = .{
    .logFn = myLogFn,
};

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const logFile = "uwaka.log";
    const cwd = std.fs.cwd();
    var createdFile = cwd.openFile(logFile, .{ .lock = .exclusive, .mode = .write_only });
    if (createdFile) |_| {} else |err| {
        if (err == std.fs.File.OpenError.FileNotFound) {
            createdFile = cwd.createFile(logFile, .{
                .truncate = false,
                .lock = .exclusive,
            }) catch |err2| {
                std.debug.print("Error creating log file: {}\n", .{err2});
                return;
            };
        }
    }
    const file = createdFile catch {
        @panic("error logging");
    };

    defer file.close();
    file.seekFromEnd(0) catch {};
    const writer = file.writer();

    // timestamp
    const timestamp = std.time.milliTimestamp();
    writer.print("[{d}] {s}({s}): ", .{ timestamp, level.asText(), @tagName(scope) }) catch {};
    writer.print(format, args) catch {};
    _ = writer.write("\n") catch {};
}

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
    uwa.log.debug("\n\n\n\n\nRunning on {s}", .{@tagName(uwa.osTag)});

    var options = try cli.parseArgs(uwa.alloc);
    uwa.log.debug("Wakatime cli path: {s}", .{options.wakatimeCliPath});
    const tui: ?*uwa.TuiData = blk: {
        if (options.tuiEnabled) {
            break :blk try uwa.TuiData.init(&options);
        }
        break :blk null;
    };
    // add watch for all files in file list
    var context = try uwa.initWatching(&options);

    // main loop
    var eventQueue = uwa.Queue(uwa.Event).init(uwa.alloc);
    var nextEventCondition = std.Thread.Condition{};
    _ = try std.Thread.spawn(.{}, pollEvents, .{
        &context,
        &options,
        &eventQueue,
        &nextEventCondition,
    });
    while (true) {
        const event = eventQueue.pop();
        var heartbeatSent = false;
        if (event) |e| {
            uwa.log.debug("Event: {} {s}", .{
                e.etype,
                e.fileName,
            });

            heartbeatSent = uwa.handleEvent(e, &options, &context) catch |err| {
                if (err == uwa.UwakaFileError.IntegrityCompromisedError) {
                    context = try uwa.rebuildFileList(&options, &context);
                    uwa.log.warn("Detected integrity issues, rebuilding file list", .{});
                    continue;
                } else {
                    uwa.log.err("Error handling event {any}", .{e});
                    @panic("Error handling event");
                }
            };
            nextEventCondition.signal();
        }
        if (tui) |t| {
            uwa.updateTui(t, &options, event, heartbeatSent) catch |err| {
                if (err == uwa.UwakaFileError.IntegrityCompromisedError) {
                    context = try uwa.rebuildFileList(&options, &context);
                    uwa.log.warn("Detected integrity issues, rebuilding file list", .{});
                } else {
                    uwa.log.err("error handling tui, crashing.\n{}", .{err});
                    @panic("error");
                }
            };
        } else if (heartbeatSent) {
            try uwa.stdout.print("Heartbeat sent for " ++
                uwa.TermFormat.GREEN ++ uwa.TermFormat.BOLD ++ "{}" ++ uwa.TermFormat.RESET ++
                " on file {s}.\n", .{ event.?.etype, event.?.fileName });
        }
        std.time.sleep(1000000 * 250); // 250ms
    }
}

fn pollEvents(
    context: *uwa.Context,
    options: *uwa.Options,
    eventQueue: *uwa.Queue(uwa.Event),
    nextEventCondition: *std.Thread.Condition,
) void {
    var nextEventLock = std.Thread.Mutex{};
    // poll for events
    while (true) {
        _ = nextEventLock.tryLock();
        const e = uwa.nextEvent(context, options) catch {
            @panic("Error getting next event");
        };
        eventQueue.push(e) catch @panic("oom");
        if (e.etype == uwa.EventType.FileDelete) {
            nextEventCondition.wait(&nextEventLock);
        }
        nextEventLock.unlock();
    }
}
