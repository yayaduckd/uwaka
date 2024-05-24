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

    // private modes
    HIDE_CURSOR: []const u8 = ESC ++ "[?25l",
    SHOW_CURSOR: []const u8 = ESC ++ "[?25h",

    // custom
    // red, yellow, bright yellow, green, blue
    COLORFUL_UWAKA: []const u8 = ESC ++ "[31mu" ++ ESC ++ "[33mw" ++ ESC ++ "[1;33ma" ++ ESC ++ "[32mk" ++ ESC ++ "[34ma" ++ ESC ++ "[0m",

    // cursor
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
        const row = (termsize.height - 1) - pos.rowsDown;
        const col = pos.colsRight;
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
    alloc: std.mem.Allocator = uwa.alloc,

    pub fn init(options: *uwa.Options) !*TuiData {
        tg = TuiData{
            .fileMap = createSortedFileList(options.fileSet),
            .ansi = Ansi.init(uwa.alloc),
            .termsize = try getTermSz(std.io.getStdOut().handle),
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

const Pos = struct {
    rowsDown: usize,
    colsRight: usize,
};
const MAX_FILE_LEN = 15;
const SPACE_BTW_FILE_HEARTBEAT = 3;
const HEARTBEAT_SPACE = 3;
const SPACING = 5;
const TOTAL_ROW_LEN = MAX_FILE_LEN + SPACE_BTW_FILE_HEARTBEAT + HEARTBEAT_SPACE + SPACING;
fn getPosToPrintFile(tui: *TuiData, file: []const u8, termsize: TermSz, offsetDown: usize) ?Pos {
    const maxFileCols = termsize.width / TOTAL_ROW_LEN;

    const fileIndex = tui.fileMap.getIndex(file).?;
    const row = (fileIndex / maxFileCols) + offsetDown;
    const col = fileIndex % maxFileCols;

    // uwa.stdout.print("{s}, {d} {d}        -   termsize {d} {d}\n", .{ file, row, col, termsize.width, termsize.height }) catch @panic("oom while handling tui");
    if (row >= termsize.height) {
        return null;
    }

    return Pos{
        .rowsDown = row,
        .colsRight = col * TOTAL_ROW_LEN,
    };
}

pub fn setupFileArea(tui: *TuiData) !void {
    var a = tui.ansi;
    const t = tui.termsize;
    var i: usize = 0;
    while (i < t.height) {
        try uwa.stdout.print("{s}{s}\n", .{
            a.cursorToCol(0),
            a.ERASE_TO_END_OF_LINE,
        });
        i += 1;
    }
    try uwa.stdout.print("{s}", .{a.cursorUpB(tui.termsize.height)});
}

pub fn printEntireMap(tui: *TuiData) !void {
    var a = tui.ansi;

    try setupFileArea(tui);
    try uwa.stdout.print("{s}{s}", .{ tui.ansi.BOLD, a.COLORFUL_UWAKA });
    var iter = tui.fileMap.iterator();
    while (iter.next()) |entry| {
        const posOrNull = getPosToPrintFile(tui, entry.key_ptr.*, tui.termsize, 2);
        if (posOrNull) |pos| {
            if (pos.rowsDown > 0) {
                try uwa.stdout.print("{s}", .{a.cursorDownB(pos.rowsDown)});
            }
            try uwa.stdout.print("{s}{s: <15} - {d}", .{
                a.cursorToCol(pos.colsRight),
                entry.key_ptr.*[0..@min(entry.key_ptr.len, MAX_FILE_LEN)],
                entry.value_ptr.*,
            });
            if (pos.rowsDown > 0) {
                try uwa.stdout.print("{s}", .{a.cursorUpB(pos.rowsDown)});
            }
        }
    }
}

pub fn printFileLine(tui: *TuiData, file: []const u8) !void {
    try uwa.stdout.print("{s} - {d}{s}", .{ file, tui.fileMap.get(file).?, tui.ansi.cursorToCol(0) });
}

fn updateTui(tui: *TuiData, event: uwa.Event) void {
    // update fileMap
    const file = event.fileName;
    var fileMap = tui.fileMap;
    const fileEntry = fileMap.get(file).?;
    fileMap.put(file, fileEntry + 1) catch @panic("oom");

    // update terminal
    var a = tui.ansi;
    const fileIndex = fileMap.getIndex(file).?;
    // assume cursor is at the top right of the file list
    if (fileIndex > 0) {
        // go down to the row with the file
        uwa.stdout.print("{s}", .{a.cursorDownB(fileIndex)}) catch @panic("printing failed");
    }
    // erase the line go back up
    uwa.stdout.print("{s}", .{a.ERASE_TO_END_OF_LINE}) catch @panic("printing failed");
    // print the new line
    printFileLine(tui, file) catch @panic("printing failed");
    if (fileIndex > 0) {
        // go back up to the top right
        uwa.stdout.print("{s}", .{a.cursorUpB(fileIndex)}) catch @panic("printing failed");
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
        // return standard VT100 size
        return TermSz{ .height = 24, .width = 80 };
    }
}

pub fn logHeartbeat(tui: *TuiData, event: uwa.Event, options: *uwa.Options) !void {
    if (false) {
        try uwa.stdout.print("Heartbeat sent for " ++
            uwa.TermFormat.GREEN ++ uwa.TermFormat.BOLD ++ "{}" ++ uwa.TermFormat.RESET ++
            " on file {s}.\n", .{ event.etype, event.fileName });
        return;
    }
    try tui.fileMap.put(event.fileName, tui.fileMap.get(event.fileName).? + 1);
    _ = options;
    const newTermSz = try getTermSz(std.io.getStdOut().handle);
    if (newTermSz.height != tui.termsize.height or newTermSz.width != tui.termsize.width) {
        tui.termsize = newTermSz;
        try printEntireMap(tui);
    }
    // should just update the file line
    try printEntireMap(tui);
}
