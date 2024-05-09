const std = @import("std");

const Args = enum { help };

const Options = struct {
    fileList: std.ArrayList([]const u8),
    help: bool,
};

fn parseArgs(allocator: std.mem.Allocator) !Options {
    var options = Options{ .help = false, .fileList = std.ArrayList([]const u8).init(allocator) };

    var args = try std.process.argsWithAllocator(allocator);

    const argMap = std.ComptimeStringMap(Args, &.{
        .{ "--help", Args.help },
        .{ "-h", Args.help },
    });

    // All args with -- will be options, others will be files to watch
    while (args.next()) |arg| {
        if (argMap.get(arg)) |argEnum| {
            switch (argEnum) {
                Args.help => options.help = true,
            }
        } else {
            try options.fileList.append(arg);
        }
    }

    return options;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const options = try parseArgs(allocator);
    defer options.fileList.deinit();

    if (options.help) {
        const helpText =
            \\Usage: uwaka [options] [file1 file2 ...]
            \\
            \\Options:
            \\  -h, --help  Display this help message
            \\
        ;
        std.debug.print(helpText, .{});
    }

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();

    // try stdout.print("Run `zig build test` to run the tests.\n", .{});

    // try bw.flush(); // don't forget to flush!
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
