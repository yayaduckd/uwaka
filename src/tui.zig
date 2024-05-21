const std = @import("std");
const uwa = @import("mix.zig");

const ESC = "\x1B";
pub const Ansi = struct {
    const Allocator = std.mem.Allocator;

    pub fn init(alloc: std.mem.Allocator) Ansi {
        return .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *Ansi) void {
        self.arena.deinit();
    }

    arena: std.heap.ArenaAllocator,
    // colors
    RED: []const u8 = ESC ++ "[31m",
    GREEN: []const u8 = ESC ++ "[32m",
    YELLOW: []const u8 = ESC ++ "[33m",
    BLUE: []const u8 = ESC ++ "[34m",
    MAGENTA: []const u8 = ESC ++ "[35m",
    CYAN: []const u8 = ESC ++ "[36m",
    WHITE: []const u8 = ESC ++ "[37m",

    // styles
    RESET: []const u8 = ESC ++ "[0m",
    BOLD: []const u8 = ESC ++ "[1m",
    UNDERLINE: []const u8 = ESC ++ "[4m",
    INVERT: []const u8 = ESC ++ "[7m",

    // cursor
    fn cursor_up(self: *Ansi, n: u32) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}{s}{d}{s}", .{ ESC, "[", n, "A" }) catch {
            @panic("printing cursor_up failed");
        };
    }

    fn cursor_down(self: *Ansi, n: u32) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}{s}{d}{s}", .{ ESC, "[", n, "B" }) catch {
            @panic("printing cursor_down failed");
        };
    }
};

fn compareStrings(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs).compare(std.math.CompareOperator.lt);
}

fn concatStrings(str1: []const u8, str2: []const u8) []const u8 {
    var result = uwa.alloc.alloc(u8, str1.len + str2.len) catch @panic("oom concat strings");
    @memcpy(result[0..str1.len], str1);
    @memcpy(result[str1.len..result.len], str2);
    uwa.alloc.free(str1);
    return result;
}

// concats with newline
inline fn concatStringsN(str1: []const u8, str2: []const u8) []const u8 {
    var result = uwa.alloc.alloc(u8, str1.len + str2.len + 1) catch @panic("oom concat strings");
    @memcpy(result[0..str1.len], str1);
    @memcpy(result[str1.len .. result.len - 1], str2);
    result[result.len - 1] = '\n';
    uwa.alloc.free(str1);
    return result;
}

pub const TuiData = struct {
    fileMap: FileHeartbeatMap,
    currentState: []const u8,

    pub fn init(options: *uwa.Options) !TuiData {
        const fileMap = createSortedFileList(options.fileSet);
        return .{
            .fileMap = fileMap,
            .currentState = try createInitialState(fileMap),
        };
    }
};

const FileHeartbeatMap = std.ArrayHashMap([]const u8, u32, FileMapContext, std.array_hash_map.autoEqlIsCheap([]const u8));

const FileMapContext = struct {
    pub fn hash(self: FileMapContext, key: []const u8) u32 {
        _ = self;
        return std.hash.Adler32.hash(key);
    }

    pub const eql = std.array_hash_map.getAutoEqlFn([]const u8, @This());
};

const FileMapSortContext = struct {
    fileMap: FileHeartbeatMap,
    pub fn init(map: FileHeartbeatMap) FileMapSortContext {
        return .{ .fileMap = map };
    }

    pub fn lessThan(ctx: FileMapSortContext, a_index: usize, b_index: usize) bool {
        const str1 = ctx.fileMap.keys()[a_index];
        const str2 = ctx.fileMap.keys()[b_index];
        return compareStrings(str1, str2);
    }
};

pub fn createSortedFileList(fileSet: uwa.FileSet) FileHeartbeatMap {
    var fileMap = FileHeartbeatMap.init(uwa.alloc);
    var fileSetIter = fileSet.iterator();
    while (fileSetIter.next()) |file| {
        _ = fileMap.fetchPut(file.*, 0) catch @panic("oom while handling tui");
    }
    fileMap.sort(FileMapSortContext.init(fileMap));

    return fileMap;
}

pub fn createInitialState(fileArray: FileHeartbeatMap) ![]const u8 {
    const fullStringPtr = uwa.alloc.create([]const u8) catch @panic("oom while handling tui");
    var fullString = fullStringPtr.*;
    fullString = "";
    for (fileArray.keys()) |file| {
        fullString = concatStringsN(fullString, file);
    }

    return fullString;
}

pub fn logHeartbeat(tui: *TuiData, event: uwa.Event, options: *uwa.Options) !void {
    if (false) {
        try uwa.stdout.print("Heartbeat sent for " ++
            uwa.TermFormat.GREEN ++ uwa.TermFormat.BOLD ++ "{}" ++ uwa.TermFormat.RESET ++
            " on file {s}.\n", .{ event.etype, event.fileName });
        return;
    }
    // _ = tui;
    _ = options;
    try uwa.stdout.print("{s}", .{tui.currentState});
    // tui.
}
