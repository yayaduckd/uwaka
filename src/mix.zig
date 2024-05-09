pub usingnamespace @import("linux.zig");
pub usingnamespace @import("main.zig");

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
