# RAM Sleeper

**See how much memory each Claude Code session uses, and put idle ones to sleep without losing them.**

Every Claude Code session is its own tree of processes: the `claude` process plus its MCP servers, shells, browsers, and dev servers. With several sessions open, for example in the Claude desktop app, that adds up to gigabytes, and idle sessions keep holding it. RAM Sleeper shows the memory of each session's whole tree and unloads the ones you pick. An unloaded session keeps its conversation. Open it again and it loads back into memory where you left off.

![Dashboard listing six Claude Code sessions with memory bars, status, and Unload buttons](docs/images/dashboard-dark.png)

## What you get

- **Per-session memory.** Covers every process a session started, each session's status (busy or idle), last activity, and the desktop app's own share.
- **Unload without losing anything.** The session is asked to exit on its own, as if you pressed Ctrl+C, so the desktop app does not report a crash. Its transcript stays on disk. When you open the session and send a message, it loads back into memory with the same conversation.
- **Stuck sessions too.** A busy session can be interrupted and unloaded after a separate warning.
- **Four ways to use it:**
  - ask Claude, or run `/ramsleeper:sessions`;
  - a local dashboard, `/ramsleeper:dashboard`;
  - a Windows tray icon;
  - a menu bar item on macOS and Linux.

## Screenshots

Every unload is confirmed first. The confirmation lists every process that will stop and highlights anything that isn't an MCP server or a shell, such as a dev server:

![Unload confirmation listing the processes that will stop, with a Vite dev server highlighted](docs/images/unload-confirm-dark.png)

In the Claude desktop app the list appears as a card in the chat. Its buttons ask Claude to unload a session, and Claude still confirms first. The picture below is the plugin's real widget output, drawn outside the app:

![Chat card with memory per session and Unload buttons](docs/images/chat-widget.png)

The number on the Windows tray icon is how many sessions have been idle for 15 minutes or more, which are the ones worth unloading. The color shows how much of your RAM all sessions hold: green below 15 %, amber below 30 %, red above. Hover over the icon for the exact figures, or click it for the list:

![Tray popup with the session list, and the tray icon in green, amber, and red](docs/images/tray-popup.png)

`/ramsleeper:setup` checks the requirements, starts the tray, and answers common questions:

![Setup page with requirement checks, commands, tray controls, and FAQ](docs/images/setup-dark.png)

All screenshots use demo data (`RAMSLEEPER_DEMO=1`), not real sessions.

## Install

RAM Sleeper needs [Node.js](https://nodejs.org) 18 or newer on `PATH`. It has no npm dependencies.

```
claude plugin marketplace add kejid/ramsleeper
claude plugin install ramsleeper@ramsleeper
```

Then run `/ramsleeper:setup`. To try it without installing, start Claude Code with `claude --plugin-dir <path to this repository>`.

## Use it

| You want to | Do this |
|---|---|
| See which session uses the most memory | `/ramsleeper:sessions`, or just ask Claude |
| Unload a session | `/ramsleeper:sessions unload 3` (row 3 of the last list), or the Unload button in the dashboard or tray |
| Keep a live view open | `/ramsleeper:dashboard` |
| Get the tray icon (Windows) or the menu bar item (macOS, Linux) | `/ramsleeper:tray` |
| Bring an unloaded session back | Open it in the Claude app and send a message. In a terminal, run `claude --resume <session-id>` in its folder. |

### Safety rules

- The session you are talking to is never unloaded, and neither is the Claude desktop app itself.
- Only the processes shown in the confirmation are stopped. Before stopping anything, the plugin checks that each PID still belongs to the same process, by its start time, and to the session you confirmed, by its session ID. PIDs are reused, and Windows reuses them quickly.
- A session without a transcript on disk is refused, because it could not be resumed.
- A busy session is stopped only through the separate Interrupt and unload action. The running turn is cut off, and everything before it is kept.

## Platforms

| | Windows 10/11 | macOS | Linux |
|---|---|---|---|
| Session list and memory | ✅ tested | ⚠️ untested | 🧪 smoke test passes |
| Unload (graceful, then forced) | ✅ tested | ⚠️ untested | 🧪 smoke test passes |
| Resume in the Claude desktop app | ✅ tested | ⚠️ untested | not applicable |
| Dashboard | ✅ tested | ⚠️ untested | 🧪 smoke test passes |
| Tray or menu bar | ✅ tray icon | ⚠️ xbar or SwiftBar, untested | 🧪 menu output passes; ⚠️ Argos or Kargos and dialogs untested |

**✅ tested** on Windows 11 with Claude desktop 2.16120 and Claude Code 2.1.284 against real sessions. A session unloaded this way came back on its next message, with a new process resuming the same session ID and the whole conversation.

**🧪 smoke test passes** means `tests/smoke.mjs` passes on Debian 12 with Node 20 in Docker. The test uses fake sessions; nothing was tried on a Linux desktop with real Claude Code sessions. On Linux, `ps` must come from procps, which desktop distributions ship; BusyBox `ps` is not enough.

### Help wanted: macOS and Linux testers

The macOS code has never run on a Mac, and the Linux code has only passed an automated test in a container. If you can try it, please open an issue with your OS and version and what happened for each of these:

1. `node tests/smoke.mjs` passes. It starts fake sessions in a temporary folder and never touches real ones; paste its output.
2. `node skills/ramsleeper/scripts/sessions.mjs list` shows your sessions with plausible memory figures.
3. `node skills/ramsleeper/scripts/sessions.mjs unload <pid>` previews the right processes. Run it with `--yes` on a throwaway session, then resume that session.
4. The menu bar item appears through xbar, SwiftBar, Argos, or Kargos (see below), and its Unload item asks for confirmation.
5. `/ramsleeper:dashboard` opens and refreshes.

`RAMSLEEPER_DEMO=1` shows made-up sessions, so you can check the interface without touching real ones.

## Tray and menu bar

**Windows:** run `/ramsleeper:tray`, or start it by hand:

```
powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File companion\windows-tray\ramsleeper-tray.ps1
```

Right-click the icon for the dashboard, start at sign-in, and exit.

**macOS and Linux:** install [xbar](https://xbarapp.com) or [SwiftBar](https://swiftbar.app) on macOS, [Argos](https://github.com/p-e-w/argos) on GNOME, or [Kargos](https://github.com/lipido/kargos) on KDE. Then link the plugin script into that app's plugin folder:

```
ln -s "$PWD/companion/menubar/ramsleeper.30s.sh" "<plugin folder>/ramsleeper.30s.sh"
```

The setup page prints the exact command for the apps it finds. Unload asks for confirmation in a native dialog: `osascript` on macOS, `zenity` or `kdialog` on Linux.

## How it works

Every running Claude Code process writes `~/.claude/sessions/<pid>.json` with its session ID, working folder, status, and start time. RAM Sleeper reads these files, then walks the operating system's process table to find each session's descendants and their memory. On Windows the figure is the private working set, the Memory column in Task Manager's Details tab. On macOS and Linux it is RSS, which counts shared memory more than once. Session titles come from the Claude desktop app's local session files or, for terminal sessions, from the first prompt in the transcript under `~/.claude/projects/`.

To unload, RAM Sleeper first asks the session to exit on its own. On Windows a short-lived helper attaches to the session's hidden console and raises Ctrl+C. On macOS and Linux the session gets SIGINT. Claude Code then shuts down cleanly, so the desktop app treats the exit as normal. Anything from the confirmed list still running after five seconds is stopped: with `taskkill /F` on Windows, with SIGTERM and then SIGKILL elsewhere. The transcript is never touched. The session's leftover file in `~/.claude/sessions` is removed, because a stopped process cannot remove it itself.

## Data

RAM Sleeper runs locally and sends nothing over the network. It reads these:

- `~/.claude/sessions`;
- transcript file names and first lines under `~/.claude/projects`;
- the Claude desktop app's session titles;
- the process list.

It writes these:

- The Windows tray records its process ID in `%LOCALAPPDATA%\ramsleeper\tray.pid`.
- Turning on start at sign-in adds a `RAM Sleeper` shortcut to your Startup folder and a small launcher, `%LOCALAPPDATA%\ramsleeper\start-tray.ps1`, that starts the newest installed version. Turning it off removes both.

The dashboard is a web server bound to `127.0.0.1` only. Each run uses a new random token that every request must carry, so neither other computers nor other websites open in your browser can use it. It stops 15 minutes after its page is closed.

## License

MIT, see [LICENSE](LICENSE). RAM Sleeper is an independent project and is not affiliated with Anthropic.
