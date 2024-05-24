const std = @import("std");
const buildOptions = @import("build_options");

pub const osTag = @import("builtin").os.tag;

const osSpecificImplementation = blk: {
    const ws = buildOptions.@"build.build.WatchSystem";
    switch (buildOptions.watch_system) {
        ws.inotify => break :blk @import("linux.zig"),
        ws.posix => break :blk @import("posix.zig"),
    }
};

pub const c = blk: {
    if (osTag != .linux and osTag != .windows) {
        break :blk @cImport({
            @cInclude("sys/ioctl.h");
        });
    } else {
        break :blk undefined;
    }
};

pub usingnamespace osSpecificImplementation;
pub usingnamespace @import("main.zig");
pub usingnamespace @import("files.zig");
pub usingnamespace @import("events.zig");
pub usingnamespace @import("tui.zig");
pub usingnamespace @import("cli.zig");

const uwa = @import("mix.zig");

pub const NAME = "uwaka";
pub const VERSION = "0.5.0";

pub var stdout: std.fs.File.Writer = blk: {
    if (!(osTag == .windows)) {
        break :blk std.io.getStdOut().writer();
    } else {
        break :blk undefined;
    }
};
pub var stderr: std.fs.File.Writer = blk: {
    if (!(osTag == .windows)) {
        break :blk std.io.getStdErr().writer();
    } else {
        break :blk undefined;
    }
};

pub const log = std.log.default;

pub fn print(text: []const u8) void {
    stdout.print("{s}", .{text}) catch @panic("error python printing");
}

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
    explicitFiles: uwa.FileSet, // list of files to watch
    fileSet: uwa.FileSet, // list of files to watch
    wakatimeCliPath: []const u8, // path to wakatime-cli binary
    editorName: []const u8, // name of editor to pass to wakatime
    editorVersion: []const u8, // version of editor to pass to wakatime
    tuiEnabled: bool, // enable tui
    gitRepos: ?uwa.FileSet, // git repo to watch
    explicitFolders: ?uwa.FileSet,
};

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const alloc = gpa.allocator();
