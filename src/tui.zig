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
    page: usize = 0,
    filePositions: FilePositionInfo,
    inputs: uwa.Queue(InputEvent),
    alloc: std.mem.Allocator = uwa.alloc,

    pub fn init(options: *uwa.Options) !*TuiData {
        const fileMap = createSortedFileList(options.fileSet);
        const termsize = try getTermSz(std.io.getStdOut().handle);
        const maxFileLen = termsize.width / 2 - 1;
        const inputs = uwa.Queue(InputEvent).init(uwa.alloc);
        tg = TuiData{
            .fileMap = fileMap,
            .ansi = Ansi.init(uwa.alloc),
            .termsize = termsize,
            .filePositions = getFilePositions(&fileMap, termsize, maxFileLen, null, null),
            .maxFileLen = maxFileLen,
            .inputs = inputs,
        };
        _ = try std.Thread.spawn(.{}, monitorStdIn, .{&tg.inputs});

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

    pub fn compareFn(t: type, a: []const u8, b: []const u8) std.math.Order {
        _ = t;
        return std.mem.order(u8, a, b);
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

    tui.filePositions.positions.deinit();
    tui.filePositions = getFilePositions(&tui.fileMap, tui.termsize, tui.maxFileLen, null, null);
}

const Pos = struct {
    y: usize,
    x: usize,
};

const FilePos = struct {
    page: usize,
    x: usize,
    y: usize,
};

const FilePositionInfo = struct {
    positions: std.ArrayList(?FilePos),
    totalPages: usize,
    maxFileWidth: usize,
};

const SPACE_BTW_FILE_HEARTBEAT = 3;
const HEARTBEAT_SPACE = 3;
const MANDATORY_SPACE = SPACE_BTW_FILE_HEARTBEAT + HEARTBEAT_SPACE + 1;
fn getFilePositions(
    fileMap: *const FileHeartbeatMap,
    termSize: TermSz,
    maxFileLen: usize,
    offsetDown: ?usize,
    spacing: ?usize,
) FilePositionInfo {
    const offset = offsetDown orelse 2;
    const space = spacing orelse 5;
    _ = space;

    var filePositions = std.ArrayList(?FilePos).init(uwa.alloc);

    var longestFileLength: usize = 0;
    var totalFileLength: usize = 0;
    const keys = fileMap.keys();
    for (keys) |file| {
        totalFileLength += file.len;
        if (file.len > longestFileLength) {
            longestFileLength = file.len;
        }
    }
    const longestFileWidth: usize = @min(longestFileLength + MANDATORY_SPACE, maxFileLen);
    if (longestFileWidth == 0 or totalFileLength == 0 or termSize.width == 0 or termSize.height == 0) {
        for (keys) |_| {
            filePositions.append(null) catch @panic("oom while handling tui");
        }
        return FilePositionInfo{ .positions = filePositions, .totalPages = 0, .maxFileWidth = longestFileWidth };
    }
    const cols = termSize.width / (longestFileWidth);
    if (cols == 0) {
        for (keys) |_| {
            filePositions.append(null) catch @panic("oom while handling tui");
        }
        return FilePositionInfo{ .positions = filePositions, .totalPages = 0, .maxFileWidth = longestFileWidth };
    }
    const rows = keys.len / cols + 1;
    const pages = rows / (termSize.height - offset) + 1;

    var currentRow = offset;
    var currentCol: usize = 0;
    var currentPage: usize = 0;
    for (keys) |_| {
        const pos = FilePos{
            .y = currentRow,
            .x = currentCol,
            .page = currentPage,
        };
        currentRow += 1;
        if (currentRow >= termSize.height) {
            currentRow = offset;
            currentCol += longestFileWidth;
        }
        uwa.log.debug("row: {d} col: {d} page: {d}", .{ currentRow, currentCol, currentPage });
        if (currentCol + longestFileWidth >= termSize.width) {
            currentCol = 0;
            currentPage += 1;
        }
        filePositions.append(pos) catch @panic("oom while handling tui");
    }
    return FilePositionInfo{ .positions = filePositions, .totalPages = pages, .maxFileWidth = longestFileWidth };
}

fn getPosToPrintFile(tui: *TuiData, file: []const u8) ?FilePos {
    const keys = tui.fileMap.keys();
    // keys are sorted so we can do a binary search
    const fileIndex = std.sort.binarySearch([]const u8, file, keys, FileMapSortContext, FileMapSortContext.compareFn).?;
    return tui.filePositions.positions.items[fileIndex];
}

pub fn setupFileArea(tui: *TuiData) !void {
    const a = tui.ansi;
    try uwa.stdout.print("{s}{s}", .{ a.ERASE_SCREEN, a.CURSOR_HOME });
}

pub fn printEntireMap(tui: *TuiData) !void {
    const a = tui.ansi;

    try setupFileArea(tui);
    try uwa.stdout.print("{s}{s} – Page ({d}/{d})", .{ tui.ansi.BOLD, a.COLORFUL_UWAKA, tui.page + 1, tui.filePositions.totalPages });
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
        if (pos.page != tui.page) return; // skip if not on the current page
        if (pos.y > 0) {
            try uwa.stdout.print("{s}", .{a.cursorDownB(pos.y)});
        }
        try uwa.stdout.print("{s}{s} - {d}", .{
            a.cursorToCol(pos.x),
            file[0..@min(file.len, tui.filePositions.maxFileWidth - MANDATORY_SPACE)],
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
    tui.maxFileLen = newTermSz.width / 2 - 1;
    tui.filePositions.positions.deinit();
    tui.filePositions = getFilePositions(&tui.fileMap, newTermSz, tui.maxFileLen, null, null);
}

const InputEvent = enum {
    NextPage,
    PrevPage,
    Other,
};

fn monitorStdIn(queue: *uwa.Queue(InputEvent)) !void {
    const stdin = std.io.getStdIn();
    var buffer: [1024]u8 = undefined;
    while (true) {
        const n = try stdin.read(&buffer);
        const key = buffer[0];
        if (n == 1) {
            try queue.push(InputEvent.NextPage);
            continue;
        }
        switch (key) {
            'b' => {
                try queue.push(InputEvent.PrevPage);
            },
            else => {
                try queue.push(InputEvent.Other);
            },
        }
    }
}

pub fn updateTui(tui: *TuiData, options: *uwa.Options, event: ?uwa.Event, isHeartbeat: bool) !void {
    const newTermSz = try getTermSz(std.io.getStdOut().handle);

    const in = tui.inputs.pop();
    if (in) |ev| {
        switch (ev) {
            InputEvent.NextPage => {
                tui.page += 1;
                if (tui.page > tui.filePositions.totalPages - 1) tui.page = 0;
            },
            InputEvent.PrevPage => {
                if (tui.page == 0) {
                    tui.page = tui.filePositions.totalPages - 1;
                } else {
                    tui.page -= 1;
                }
            },
            InputEvent.Other => {},
        }
        try uwa.stdout.print("{s}", .{tui.ansi.cursorUp(1)});
        try printEntireMap(tui);
    }

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
