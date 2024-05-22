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

    //erase
    ERASE_TO_END_OF_LINE: []const u8 = ESC ++ "[K",

    // private modes
    HIDE_CURSOR: []const u8 = ESC ++ "[?25l",
    SHOW_CURSOR: []const u8 = ESC ++ "[?25h",

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

const SignalMap = struct {
    signalPresent: bool = false,
    numSIGINT: usize = 0,
    numSIGWINCH: usize = 0,

    pub fn signal(self: *SignalMap, sig: c_int) void {
        switch (sig) {
            uwa.c.SIGINT => self.numSIGINT += 1,
            uwa.c.SIGWINCH => self.numSIGWINCH += 1,
            else => {},
        }
        self.signalPresent = true;
    }

    pub fn popSignal(self: *SignalMap, sig: c_int) ?c_int {
        var result: ?c_int = null;
        switch (sig) {
            uwa.c.SIGINT => {
                self.numSIGINT -= 1;
                result = uwa.c.SIGINT;
            },
            uwa.c.SIGWINCH => {
                self.numSIGWINCH -= 1;
                result = uwa.c.SIGWINCH;
            },
            else => {},
        }
        if (self.numSIGINT == 0 and self.numSIGWINCH == 0) {
            self.signalPresent = false;
        }
        return result;
    }

    pub fn pop(self: *SignalMap) ?c_int {
        if (!self.signalPresent) {
            return null;
        } else if (self.numSIGINT > 0) {
            return self.popSignal(uwa.c.SIGINT);
        } else if (self.numSIGWINCH > 0) {
            return self.popSignal(uwa.c.SIGWINCH);
        } else unreachable;
    }
};

fn handleSignal(sig: c_int) callconv(.C) void {
    tg.sigmap.signal(sig);
}

pub const TuiData = struct {
    fileMap: FileHeartbeatMap,
    ansi: Ansi,
    sigmap: *SignalMap,
    termsize: TermSz,
    alloc: std.mem.Allocator = uwa.alloc,

    pub fn init(options: *uwa.Options) !*TuiData {
        const sigmap = SignalMap{};
        const sigmapPtr = try uwa.alloc.create(SignalMap);
        sigmapPtr.* = sigmap;

        tg = TuiData{
            .fileMap = createSortedFileList(options.fileSet),
            .ansi = Ansi.init(uwa.alloc),
            .sigmap = sigmapPtr,
            .termsize = getTermSz(std.io.getStdOut()),
        };

        _ = uwa.c.signal(uwa.c.SIGWINCH, handleSignal);
        _ = uwa.c.signal(uwa.c.SIGINT, handleSignal);

        try uwa.stdout.print("{s}", .{tg.ansi.HIDE_CURSOR});
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

pub fn printEntireMap(tui: *TuiData) !void {
    var iter = tui.fileMap.iterator();
    while (iter.next()) |entry| {
        try uwa.stdout.print("{s} - {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    // move cursor back to top right of map
    try uwa.stdout.print("{s}", .{tui.ansi.cursorUpB(tui.fileMap.count())});
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

pub fn getTermSz(tty: i32) !TermSz {
    var winsz = std.c.winsize{ .ws_col = 0, .ws_row = 0, .ws_xpixel = 0, .ws_ypixel = 0 };

    const rv = std.c.ioctl(tty, uwa.c.TIOCGWINSZ, &winsz);
    const err = std.posix.errno(rv);
    if (rv == 0) {
        return TermSz{ .height = winsz.ws_row, .width = winsz.ws_col };
    } else {
        return std.posix.unexpectedErrno(err);
    }
}

pub fn logHeartbeat(tui: *TuiData, event: uwa.Event, options: *uwa.Options) !void {
    if (false) {
        try uwa.stdout.print("Heartbeat sent for " ++
            uwa.TermFormat.GREEN ++ uwa.TermFormat.BOLD ++ "{}" ++ uwa.TermFormat.RESET ++
            " on file {s}.\n", .{ event.etype, event.fileName });
        return;
    }
    _ = options;
    var hasSIGWINCH = false;
    while (tui.sigmap.pop()) |sig| {
        try uwa.stdout.print("{}", .{tui.sigmap});
        if (sig == uwa.c.SIGWINCH) {
            hasSIGWINCH = true;
        } else if (sig == uwa.c.SIGINT) {
            try uwa.stdout.print("SIGINT received, exiting...\n", .{});
            try uwa.stdout.print("{s}", .{tui.ansi.SHOW_CURSOR});
            std.process.exit(0);
        }
    }
    if (hasSIGWINCH) {
        tui.termsize = try getTermSz(std.io.getStdOut().handle);
        try uwa.stdout.print("Terminal size: {d}x{d}\n", .{ tui.termsize.width, tui.termsize.height });
    }
}
