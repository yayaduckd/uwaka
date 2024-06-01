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
    BLACK: []const u8 = ESC ++ "[30m",
    RED: []const u8 = ESC ++ "[31m",
    GREEN: []const u8 = ESC ++ "[32m",
    YELLOW: []const u8 = ESC ++ "[33m",
    BLUE: []const u8 = ESC ++ "[34m",
    MAGENTA: []const u8 = ESC ++ "[35m",
    CYAN: []const u8 = ESC ++ "[36m",
    WHITE: []const u8 = ESC ++ "[37m",

    BRIGHT_BLACK: []const u8 = ESC ++ "[1;30m",
    BRIGHT_RED: []const u8 = ESC ++ "[1;31m",
    BRIGHT_GREEN: []const u8 = ESC ++ "[1;32m",
    BRIGHT_YELLOW: []const u8 = ESC ++ "[1;33m",
    BRIGHT_BLUE: []const u8 = ESC ++ "[1;34m",
    BRIGHT_MAGENTA: []const u8 = ESC ++ "[1;35m",
    BRIGHT_CYAN: []const u8 = ESC ++ "[1;36m",
    BRIGHT_WHITE: []const u8 = ESC ++ "[1;37m",

    // styles
    RESET: []const u8 = ESC ++ "[0m",
    BOLD: []const u8 = ESC ++ "[1m",
    UNDERLINE: []const u8 = ESC ++ "[4m",
    INVERT: []const u8 = ESC ++ "[7m",

    //erase
    ERASE_TO_END_OF_LINE: []const u8 = ESC ++ "[K",
    ERASE_SCREEN: []const u8 = ESC ++ "[2J",

    // private modes
    HIDE_CURSOR: []const u8 = ESC ++ "[?25l",
    SHOW_CURSOR: []const u8 = ESC ++ "[?25h",

    // custom
    // red, yellow, bright yellow, green, blue
    COLORFUL_UWAKA: []const u8 = ESC ++ "[31mu" ++ ESC ++ "[33mw" ++ ESC ++ "[1;33ma" ++ ESC ++ "[32mk" ++ ESC ++ "[34ma" ++ ESC ++ "[0m",

    // cursor
    CURSOR_HOME: []const u8 = ESC ++ "[H",
    fn cursorUp(self: *Ansi, n: usize) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}{s}{d}{s}", .{ ESC, "[", n, "A" }) catch {
            @panic("printing cursor_up failed");
        };
    }

    fn cursorUpB(self: *Ansi, n: usize) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}{s}{d}{s}", .{ ESC, "[", n, "F" }) catch {
            @panic("printing cursor_up failed");
        };
    }

    fn cursorDown(self: *Ansi, n: usize) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}{s}{d}{s}", .{ ESC, "[", n, "B" }) catch {
            @panic("printing cursor_down failed");
        };
    }

    fn cursorDownB(self: *Ansi, n: usize) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}{s}{d}{s}", .{ ESC, "[", n, "E" }) catch {
            @panic("printing cursor_down failed");
        };
    }

    fn cursorToCol(self: *Ansi, n: usize) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}{s}{d}{s}", .{ ESC, "[", n, "G" }) catch {
            @panic("printing cursor_down failed");
        };
    }

    fn cursorToPos(self: *Ansi, pos: Pos, termsize: TermSz) []const u8 {
        const row = (termsize.height - 1) - pos.y;
        const col = pos.x;
        return std.fmt.allocPrint(self.arena.allocator(), "{s}{s}{d};{d}{s}", .{ ESC, "[", row, col, "H" }) catch {
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

var tg: TuiData = undefined;

pub const TuiData = struct {
    fileMap: FileHeartbeatMap,
    ansi: Ansi,
    termsize: TermSz,
    maxFileLen: usize,
    filePositions: std.ArrayList(?Pos),
    alloc: std.mem.Allocator = uwa.alloc,

    pub fn init(options: *uwa.Options) !*TuiData {
        const fileMap = createSortedFileList(options.fileSet);
        const termsize = try getTermSz(std.io.getStdOut().handle);
        const maxFileLen = termsize.width / 2;
        tg = TuiData{
            .fileMap = fileMap,
            .ansi = Ansi.init(uwa.alloc),
            .termsize = termsize,
            .filePositions = getFilePositions(&fileMap, termsize, maxFileLen, null, null),
            .maxFileLen = maxFileLen,
        };

        try printEntireMap(&tg);
        return &tg;
    }
};

const FileHeartbeatMap = std.ArrayHashMap([]const u8, u32, std.array_hash_map.StringContext, std.array_hash_map.autoEqlIsCheap([]const u8));

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

pub fn updateSortedFileList(fileSet: uwa.FileSet, tui: *TuiData) !void {
    var newMap = createSortedFileList(fileSet);
    var fileMapIter = tui.fileMap.iterator();
    while (fileMapIter.next()) |entry| {
        if (newMap.contains(entry.key_ptr.*)) {
            newMap.put(entry.key_ptr.*, entry.value_ptr.*) catch @panic("oom while handling tui");
        }
    }
    newMap.sort(FileMapSortContext.init(newMap));
    tui.fileMap.deinit();
    tui.fileMap = newMap;

    tui.filePositions.deinit();
    tui.filePositions = getFilePositions(&tui.fileMap, tui.termsize, tui.maxFileLen, null, null);
}

const Pos = struct {
    y: usize,
    x: usize,
};

fn getFilePositions(
    fileMap: *const FileHeartbeatMap,
    termSize: TermSz,
    maxFileLen: usize,
    offsetDown: ?usize,
    spacing: ?usize,
) std.ArrayList(?Pos) {
    const SPACE_BTW_FILE_HEARTBEAT = 3;
    const HEARTBEAT_SPACE = 3;
    const offset = offsetDown orelse 2;
    const space = spacing orelse 5;

    var filePositions = std.ArrayList(?Pos).init(uwa.alloc);

    var longestFileLength: usize = 0;
    var totalFileLength: usize = 0;
    const keys = fileMap.keys();
    for (keys) |file| {
        totalFileLength += file.len;
        if (file.len > longestFileLength) {
            longestFileLength = file.len;
        }
    }
    const longestFileWidth: usize = @min(longestFileLength + SPACE_BTW_FILE_HEARTBEAT + HEARTBEAT_SPACE, maxFileLen);
    if (longestFileWidth == 0 or totalFileLength == 0 or termSize.width == 0 or termSize.height == 0) {
        for (keys) |_| {
            filePositions.append(null) catch @panic("oom while handling tui");
        }
        return filePositions;
    }
    const cols = termSize.width / (longestFileWidth + space);
    if (cols == 0) {
        for (keys) |_| {
            filePositions.append(null) catch @panic("oom while handling tui");
        }
        return filePositions;
    }
    const rows = keys.len / cols + 1;

    var currentRow = offset;
    var currentCol: usize = 0;
    for (keys) |_| {
        var pos: ?Pos = null;
        if (currentRow <= termSize.height and currentCol <= termSize.width) {
            pos = Pos{
                .y = currentRow,
                .x = currentCol,
            };
        }
        currentRow += 1;
        if (currentRow >= rows + offset) {
            currentRow = offset;
            currentCol += longestFileWidth + space;
        }
        filePositions.append(pos) catch @panic("oom while handling tui");
    }
    if (filePositions.items[filePositions.items.len - 1] == null and space > 1) {
        filePositions.deinit();
        return getFilePositions(fileMap, termSize, maxFileLen, offsetDown, space - 1);
    }
    return filePositions;
}

fn getPosToPrintFile(tui: *TuiData, file: []const u8) ?Pos {
    const fileIndex = tui.fileMap.getIndex(file).?;
    return tui.filePositions.items[fileIndex];
}

pub fn setupFileArea(tui: *TuiData) !void {
    const a = tui.ansi;
    try uwa.stdout.print("{s}{s}", .{ a.ERASE_SCREEN, a.CURSOR_HOME });
}

pub fn printEntireMap(tui: *TuiData) !void {
    const a = tui.ansi;

    try setupFileArea(tui);
    try uwa.stdout.print("{s}{s}", .{ tui.ansi.BOLD, a.COLORFUL_UWAKA });
    if (tui.termsize.height < 10 or tui.termsize.width < 10) {
        return;
    }
    var iter = tui.fileMap.iterator();
    while (iter.next()) |entry| {
        try printFileLine(tui, entry.key_ptr.*, entry.value_ptr.*);
    }
}

pub fn printFileLine(tui: *TuiData, file: []const u8, heartbeats: u32) !void {
    var a = tui.ansi;
    const posOrNull = getPosToPrintFile(tui, file);
    if (posOrNull) |pos| {
        uwa.log.debug("printing file {s} with {d} hearbeats", .{ file, heartbeats });
        if (pos.y > 0) {
            try uwa.stdout.print("{s}", .{a.cursorDownB(pos.y)});
        }
        try uwa.stdout.print("{s}{s} - {d}", .{
            a.cursorToCol(pos.x),
            file[0..@min(file.len, tui.maxFileLen)],
            heartbeats,
        });
        if (pos.y > 0) {
            try uwa.stdout.print("{s}", .{a.cursorUpB(pos.y)});
        }
    }
}

const TermSz = struct {
    height: u16,
    width: u16,
};

pub fn getTermSz(tty: std.posix.fd_t) !TermSz {
    if (uwa.osTag != .windows) {
        var winsz = std.posix.winsize{ .ws_col = 0, .ws_row = 0, .ws_xpixel = 0, .ws_ypixel = 0 };
        const rv = blk: {
            if (uwa.osTag == .linux) {
                break :blk std.os.linux.ioctl(tty, std.os.linux.T.IOCGWINSZ, @intFromPtr(&winsz));
            } else {
                break :blk std.c.ioctl(tty, uwa.c.TIOCGWINSZ, &winsz);
            }
        };
        const err = std.posix.errno(rv);
        if (rv == 0) {
            return TermSz{ .height = winsz.ws_row, .width = winsz.ws_col };
        } else {
            return std.posix.unexpectedErrno(err);
        }
    } else {
        const windows = std.os.windows;
        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (windows.kernel32.GetConsoleScreenBufferInfo(tty, &info) != windows.TRUE)
            return error.Unexpected;
        return TermSz{ .height = @intCast(info.dwSize.Y), .width = @intCast(info.dwSize.X) };
    }
}

fn updateTuiSize(tui: *TuiData, newTermSz: TermSz) void {
    tui.termsize = newTermSz;
    tui.maxFileLen = newTermSz.width / 2;
    tui.filePositions.deinit();
    tui.filePositions = getFilePositions(&tui.fileMap, newTermSz, tui.maxFileLen, null, null);
}

pub fn updateTui(tui: *TuiData, options: *uwa.Options, event: ?uwa.Event, isHeartbeat: bool) !void {
    const newTermSz = try getTermSz(std.io.getStdOut().handle);

    if ((newTermSz.height != tui.termsize.height or newTermSz.width != tui.termsize.width)) {
        uwa.log.debug("updating tui size", .{});
        updateTuiSize(tui, newTermSz);
        try printEntireMap(tui);
    }
    if (event) |e| {
        var requiresRefresh = false;
        switch (e.etype) {
            uwa.EventType.FileCreate => {
                requiresRefresh = true;
            },
            uwa.EventType.FileDelete => {
                requiresRefresh = true;
            },
            else => {},
        }
        if (requiresRefresh) {
            try updateSortedFileList(options.fileSet, tui);
            try printEntireMap(tui);
        }

        if (!isHeartbeat) return;
        try tui.fileMap.put(e.fileName, tui.fileMap.get(e.fileName).? + 1);
        // should just update the file line
        const entry = tui.fileMap.getEntry(e.fileName).?;
        try printFileLine(tui, entry.key_ptr.*, entry.value_ptr.*);
        return;
    }
}
