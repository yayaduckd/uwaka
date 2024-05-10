Zig Version: `0.12.0`

Currently only Linux-compatible.

🦆

# Usage

1. First, download wakatime-cli from https://github.com/wakatime/wakatime-cli.
2. Then, download/compile uwaka, and run it from the terminal with the arguments specified below.

```
Usage: uwaka [options] file1 file2 ...

Specify files to track with wakatime. Will use the specified wakatime-cli binary to track the files, and the default wakatime config.

Options:
  -h, --help  Display this help message
  -w, --wakatime-cli-path  Path to wakatime-cli binary. REQUIRED.
  -e, --editor-name  Name of editor to pass to wakatime. Defaults to "uwaka".
  -r, --editor-version  Version of editor to pass to wakatime. Required if editor-name is set.
  -g, --git-repo  Path to git repository. If set, uwaka will watch all tracked and untracked (but not ignored) files in the git repository.
```

Tested with `wakatime-cli` version `1.90.0`.

# Known Issues

- Does not yet handle file renaming while tracking a git repo and uwaka is running.
