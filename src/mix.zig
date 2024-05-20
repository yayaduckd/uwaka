const std = @import("std");
const buildOptions = @import("build_options");

pub const osTag = @tagName(@import("builtin").os.tag);

const osSpecificImplementation = blk: {
    const ws = buildOptions.@"build.build.WatchSystem";
    switch (buildOptions.watch_system) {
        ws.inotify => break :blk @import("linux.zig"),
        ws.posix => break :blk @import("posix.zig"),
    }
};

pub usingnamespace osSpecificImplementation;
pub usingnamespace @import("main.zig");
pub usingnamespace @import("git.zig");
pub usingnamespace @import("events.zig");

pub const NAME = "uwaka";
pub const VERSION = "0.3.1";

pub var stdout: std.fs.File.Writer = blk: {
    const tag = @tagName(@import("builtin").os.tag);
    if (std.mem.eql(u8, tag, "linux")) {
        break :blk std.io.getStdOut().writer();
    } else {
        break :blk undefined;
    }
};
pub var stderr: std.fs.File.Writer = blk: {
    const tag = @tagName(@import("builtin").os.tag);
    if (std.mem.eql(u8, tag, "linux")) {
        break :blk std.io.getStdErr().writer();
    } else {
        break :blk undefined;
    }
};

pub const log = std.log.default;

pub const EventType = enum {
    FileChange,
    FileCreate,
    FileDelete,
    FileMove,
    Unknown,

    pub fn format(value: EventType, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;
        const formatted = switch (value) {
            EventType.FileChange => "file change event",
            EventType.FileCreate => "file creation event",
            EventType.FileDelete => "file deletion event",
            EventType.FileMove => "file move event",
            EventType.Unknown => "unknown event type",
        };
        try writer.writeAll(formatted);
        return;
    }
};

pub const Event = struct {
    etype: EventType,
    fileName: []const u8,
};

pub const Options = struct {
    explicitFiles: std.BufSet, // list of files to watch
    fileSet: std.BufSet, // list of files to watch
    wakatimeCliPath: []const u8, // path to wakatime-cli binary
    editorName: []const u8, // name of editor to pass to wakatime
    editorVersion: []const u8, // version of editor to pass to wakatime
    gitRepos: ?std.BufSet, // git repo to watch
};

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const alloc = gpa.allocator();
