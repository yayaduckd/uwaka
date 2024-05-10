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
    Unknown,
};

pub const Event = struct {
    etype: EventType,
    fileName: []const u8,
};
