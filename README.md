# tai

Terminal client for the tai agent. The Neovim plugin is [tai.nvim](https://github.com/blmayer/tai).

One POSIX shell script. `jq` and `curl` do the JSON and HTTP. It reads `.tai` from the project (same file as the plugin) and keeps its own session at `.tai-cli-session.json`. The `jq` filters and prompts are read from `$XDG_DATA_HOME/tai` (default `~/.local/share/tai`), then from each directory in `$XDG_DATA_DIRS`.

```
tai  llama_cpp/gemma  orchestrator  [idle]
you: fix the build
CODER show the error [1]
>
```

Output is appended to the terminal. Scroll the window to read earlier lines. The input is the `>` line. The terminal title tracks the status line. The bell rings when the agent stops.

| Key | Action |
|---|---|
| Enter | Send the line. `y` / `n` / `s` while a command is waiting |
| Ctrl-C | Stop the agent |
| Ctrl-L | Redraw the prompt |
| Ctrl-U | Clear the line |
| Ctrl-N | Clear the session |
| Ctrl-H | Show or hide help |
| Ctrl-Q | Quit |

An empty prompt shows `ctrl-h help` in dim text. That text is not part of the line.

```
make test
make install
```

`make install` puts the script in `~/.local/bin` and the data files in `~/.local/share/tai` (`$(PREFIX)/share/tai` when `PREFIX` is set). A `PREFIX` of `/usr/local` or `/usr` is found through the default `XDG_DATA_DIRS`.
