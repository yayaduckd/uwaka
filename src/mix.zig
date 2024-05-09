pub usingnamespace @import("linux.zig");
pub usingnamespace @import("main.zig");

pub const NAME = "uwaka";
pub const VERSION = "0.1.0";

const std = @import("std");
pub const log = std.log.default;

pub const EventType = enum {
    FileChange,
    Unknown,
};

pub const Event = struct {
    etype: EventType,
    fileName: []const u8,
};
