const std = @import("std");

const WatchSystem = enum {
    inotify,
    posix,
};

fn addTargets(targets: []std.Build.ResolvedTarget, b: *std.Build, nativeTarget: std.Build.ResolvedTarget) ?*std.Build.Step.Compile {
    var nativeExe: ?*std.Build.Step.Compile = null;
    const watchSystemOverride = b.option(WatchSystem, "watch_system", "Specify what backend uwaka should use to monitor files for changes.");

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    for (targets) |target| {
        const architecture = target.result.cpu.arch;
        const os = target.result.os.tag;

        var options = b.addOptions();

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

        if (std.mem.eql(u8, @tagName(target.result.os.tag), @tagName(nativeTarget.result.os.tag)) and
            std.mem.eql(u8, @tagName(target.result.cpu.arch), @tagName(nativeTarget.result.cpu.arch)))
        {
            nativeExe = exe;
        }
    }
    return nativeExe;
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const nativeTarget = b.standardTargetOptions(.{});
    const buildAllOs = b.option(bool, "build_all_os", "Build for all supported operating systems") orelse false;
    var targets = std.ArrayList(std.Build.ResolvedTarget).init(b.allocator);

    if (buildAllOs) {
        const possibleTargets: [5][]const u8 = .{
            "x86_64-linux-gnu",
            "aarch64-linux-gnu",
            "x86_64-windows-gnu",
            "x86_64-macos-none",
            "aarch64-macos-none",
        };

        for (possibleTargets) |currentTarget| {
            targets.append(b.resolveTargetQuery(std.Build.parseTargetQuery(.{
                .arch_os_abi = currentTarget,
                .cpu_features = null,
                .dynamic_linker = null,
            }) catch unreachable)) catch unreachable;
        }
    } else {
        targets.append(nativeTarget) catch unreachable;
    }

    const exe = addTargets(targets.items, b, nativeTarget);

    if (exe) |e| {
        // This *creates* a Run step in the build graph, to be executed when another
        // step is evaluated that depends on it. The next line below will establish
        // such a dependency.
        const run_cmd = b.addRunArtifact(e);

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
}
