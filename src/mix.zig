pub usingnamespace @import("linux.zig");
pub usingnamespace @import("main.zig");
pub usingnamespace @import("git.zig");

pub const NAME = "uwaka";
pub const VERSION = "0.2.0";

const std = @import("std");
pub const log = std.log.default;

pub const EventType = enum {
    FileChange,
    FileCreate,
    FileDelete,
    FileMove,
    Unknown,
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
    gitRepo: []const u8, // git repo to pass to wakatime
};
