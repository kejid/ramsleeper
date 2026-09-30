# RAM Sleeper

See how much memory each running Claude Code session uses, including the MCP servers, shells, and other processes it started, and unload the idle ones without losing them. An unloaded session keeps its whole conversation and can be resumed later.

This is useful when you keep many sessions open, for example in the Claude desktop app, and the machine slows down: every session is its own process tree, often 0.3 to 1.3 GB and a dozen or more processes, and idle sessions keep that memory.

## Use it

Start with `/ramsleeper:setup`. It opens a local page that checks Node.js, lists the commands, starts the tray icon or gives the menu bar setup for your system, and answers common questions.

In any Claude Code session:

- `/ramsleeper:sessions` lists the sessions with their memory, process count, status (busy or idle), and last activity. In the Claude desktop app the list appears as an interactive card in the chat; in a terminal it is a table.
- `/ramsleeper:sessions unload 3` unloads the session on row 3. Claude shows exactly which processes will stop and how much memory that frees, and asks you before stopping anything. You can also just ask, for example "which session eats the most memory?" or "unload the idle ones I haven't touched today".
- `/ramsleeper:dashboard` opens a small local window that refreshes every 10 seconds and has an Unload button on each row.

To continue an unloaded session:

- **Claude desktop app:** click the session in the sidebar and send a message. The app starts it again from its transcript, with the same conversation.
- **Terminal:** run `claude --resume <session-id>` in the session's folder. The unload result prints the exact command.

### Safety rules

- The session you are talking to is never unloaded, and neither is the Claude desktop app itself.
- A busy session, one with a turn running, is only stopped through a separate Interrupt and unload action with its own warning. The running turn is cut off; the conversation up to it is kept. This is the way out for a stuck session.
- A session without a transcript on disk is refused, because it could not be resumed.
- Before stopping a process, the plugin checks that its PID still belongs to the same session, by process start time and by the session ID you confirmed. PIDs are reused, and Windows reuses them quickly.
- Everything the session started stops with it. That includes MCP servers and shells, and also dev servers or databases you launched from that session. The confirmation lists these separately.

## Always visible: tray and menu bar

These companions are optional and live in `companion/`. They use the same script as the plugin.

Run `/ramsleeper:tray` to start the one for your system, or start it by hand as shown below.

**Windows notification area.** The icon shows whole gigabytes held by all sessions. Its color is green below 15 % of your RAM, amber below 30 %, and red above that. Left-click opens a list with Unload buttons. Right-click offers the dashboard, start at sign-in, and exit.

```
powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File companion\windows-tray\ramsleeper-tray.ps1
```

**macOS menu bar and Linux panels.** Install [xbar](https://xbarapp.com) or [SwiftBar](https://swiftbar.app) on macOS, or [Argos](https://github.com/p-e-w/argos) on GNOME or [Kargos](https://github.com/lipido/kargos) on KDE. Then symlink the plugin script into that app's plugin folder:

```
ln -s "$PWD/companion/menubar/ramsleeper.30s.sh" "<plugin folder>/ramsleeper.30s.sh"
```

Unload asks for confirmation in a native dialog: `osascript` on macOS, `zenity` or `kdialog` on Linux.

## Install

The plugin needs [Node.js](https://nodejs.org) 18 or newer on `PATH`. It has no npm dependencies.

```
claude plugin marketplace add <path or GitHub owner/repo of this repository>
claude plugin install ramsleeper@ramsleeper
```

To try it without installing, run `claude --plugin-dir <path to this repository>`.

## How it works

Every running Claude Code process writes a small file to `~/.claude/sessions/<pid>.json`. The file holds its session ID, working folder, status, and start time. The plugin reads these files and then reads the operating system's process table to find each session's child processes and their memory. On Windows the figure is the private working set, which is the Memory column in Task Manager. On macOS and Linux it is RSS, which counts shared memory more than once. Session titles come from the Claude desktop app's local session files and, for terminal sessions, from the first prompt in the transcript under `~/.claude/projects/`.

Unloading stops exactly the processes listed in the confirmation: `taskkill /F` on Windows, SIGTERM and then SIGKILL on macOS and Linux. The transcript is never touched; the session's stale file in `~/.claude/sessions` is removed, because a killed process cannot remove it itself.

Tested on Windows 11 with the Claude desktop app and Claude Code 2.1: a session unloaded this way came back on its next message as a new process resuming the same session ID, and it still knew what it had been told before. The macOS and Linux code paths (process table, menu bar output, dialogs) are written to the same rules, but they have not been run on those systems yet. Reports are welcome.

## Data

The plugin runs locally and sends nothing over the network. It reads `~/.claude/sessions`, the transcripts' file names and first lines under `~/.claude/projects`, the Claude desktop app's session titles, and the process list. The Windows tray writes its process ID to `%LOCALAPPDATA%\ramsleeper\tray.pid`. Turning on start at sign-in adds a `RAM Sleeper` shortcut to your Startup folder and a small launcher, `%LOCALAPPDATA%\ramsleeper\start-tray.ps1`, that starts the newest installed version of the tray. Turning it off removes both. The dashboard is a web server bound to `127.0.0.1` only. Each run uses a new random token, and every request must carry it, so other computers and other websites open in your browser cannot use it. The server stops 15 minutes after its page is closed.

## License

MIT, see [LICENSE](LICENSE).
