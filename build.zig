const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    const architecture = target.result.cpu.arch;
    const os = target.result.os.tag;

    var options = b.addOptions();

    const WatchSystem = enum {
        inotify,
        posix,
    };

    const watchSystemOverride = b.option(WatchSystem, "watch_system", "Specify what backend uwaka should use to monitor files for changes.");

    if (watchSystemOverride) |ws| {
        switch (ws) {
            WatchSystem.inotify => options.addOption(WatchSystem, "watch_system", ws),
            WatchSystem.posix => options.addOption(WatchSystem, "watch_system", ws),
        }
    } else {
        if (os == .linux) {
            options.addOption(WatchSystem, "watch_system", WatchSystem.inotify);
        } else {
            options.addOption(WatchSystem, "watch_system", WatchSystem.posix);
        }
    }

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const executableName = std.fmt.allocPrint(b.allocator, "uwaka_{s}-{s}", .{ @tagName(architecture), @tagName(os) }) catch unreachable;

    const exe = b.addExecutable(.{
        .name = executableName,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("build_options", options);
    if (os != .linux and os != .windows) {
        exe.linkLibC();
    }

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
