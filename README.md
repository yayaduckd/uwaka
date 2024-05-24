Zig Version: `0.12.0`

Currently only Linux is supported efficiently, but uwaka is still usable on systems with POSIX-compatible filesystems including Windows and macOS.

🦆

# Usage

1. First, download wakatime-cli from https://github.com/wakatime/wakatime-cli.
2. Then, download/compile uwaka, and run it from the terminal with the arguments specified below.

```
Usage: uwaka [options] file1 file2 ...

Specify files to track with wakatime. Will use the specified wakatime-cli binary to track the files, and the default wakatime config.

Folders can also be specified, in which case all files in the folder and subfolders will be tracked.

Options:
  -h, --help  Display this help message
  -w, --wakatime-cli-path  Path to wakatime-cli binary. REQUIRED.
  -e, --editor-name  Name of editor to pass to wakatime. Defaults to "uwaka".
  -r, --editor-version  Version of editor to pass to wakatime. Required if editor-name is set.
  -g, --git-repo  Path to git repository.
                  If set, uwaka will watch all tracked and untracked (but not ignored) files in the git repository.
                  Multiple git repos can be set with multiple -g flags.
  -t, --disable-tui  Disable the TUI. Will only log to stdout.
```

Tested with `wakatime-cli` version `1.90.0`.

# Compiling

- Acquire and install version 0.12.0 of [Zig](https://ziglang.org/).
- Run `zig build --release=fast` in the root directory of the project.
- The compiled binary will be in `zig-out/bin/`.

When building, you can specify the implementation used to watch files using `-Dwatch_system=...` where `...` is either `inotify` (Linux only) or `posix`. If not specified, uwaka will compile with the optimal implementation for the target system.
