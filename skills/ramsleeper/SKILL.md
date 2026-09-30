---
name: ramsleeper
description: Show how much memory (RAM) each running Claude Code session uses, with its MCP servers and other child processes, and unload an idle or stuck session to free memory without losing it. Use when the user asks which session eats memory, why the computer is slow with many Claude sessions open, how many sessions are running, or wants to close, stop, unload, hibernate or free memory from a session they will continue later.
---

# RAM Sleeper

The script `${CLAUDE_SKILL_DIR}/scripts/sessions.mjs` (Node.js, no dependencies) reads local files and the OS process table. It never sends anything over the network.

## Show sessions

If a tool that renders inline HTML widgets is available (in the Claude desktop app it is `show_widget`), generate the widget and pass the script's output to that tool unchanged as the widget code:

```bash
node "${CLAUDE_SKILL_DIR}/scripts/sessions.mjs" widget --lang=en
```

Use `--lang=ru` for a Russian-speaking user; other languages get `en`. The widget is a snapshot with the time it was taken. Its buttons send a chat message asking to refresh the list or to unload a session by PID; handle an unload request with the steps below, preview and confirmation included. Add at most one sentence of your own, for example which idle session holds the most memory.

Otherwise, run:

```bash
node "${CLAUDE_SKILL_DIR}/scripts/sessions.mjs" list
```

and show the result to the user as a table in their language: number, title, RAM, process count, status (busy = a turn is running, idle = waiting), last activity. Mark the row flagged `◀ this session`. Mention the total and the desktop app's own memory line. On Windows the figure is the private working set, the same as the "Memory" column in Task Manager; on macOS and Linux it is RSS, which counts shared pages more than once.

If `node` is not found, tell the user the plugin needs Node.js 18 or newer on PATH and stop.

## Dashboard

If the user wants something that stays open and refreshes by itself, rather than a snapshot in chat, start the local dashboard in the background:

```bash
node "${CLAUDE_SKILL_DIR}/scripts/sessions.mjs" serve
```

It listens on 127.0.0.1 only, opens as a small standalone window (Edge or Chrome app mode; the default browser otherwise, or always with `--tab`), refreshes every 10 seconds, and has an Unload button that asks for confirmation in the page. Give the user the printed link.

## Unload a session

Unloading stops the session's process tree: the `claude` process, its MCP servers, shells, and anything it started, such as a dev server. The conversation stays in its transcript, so the session can be continued later.

1. Find the session's PID. The user may name it by row number, title, or ID. A row number refers to the table you showed last, so take that row's PID; rows are sorted by memory and can reorder between runs, so never pass a row number to the script. If no table was shown yet, run `list` first.
2. Preview without changing anything:
   ```bash
   node "${CLAUDE_SKILL_DIR}/scripts/sessions.mjs" unload <pid>
   ```
   It prints the processes that will stop, how much memory they hold, and the exact command for step 4, or a refusal. Relay a refusal as is: the script refuses the session you are running in and sessions without a transcript.
3. Show the user the title, the memory to be freed, and every child process that will stop. Call out anything that is not an MCP server or shell, such as a dev server or database, because it stops too. If the preview says the session is BUSY, say plainly that the turn it is running now will be cut off and only the conversation up to it is kept. Ask for an explicit yes for this one session. Ask again for every further session; one yes never covers another.
4. Only after that yes, run the command the preview printed. It has this form, with `--force` only for a busy session:
   ```bash
   node "${CLAUDE_SKILL_DIR}/scripts/sessions.mjs" unload <pid> --expect=<session-id> --yes [--force]
   ```
   `--expect` makes the script refuse if the PID no longer belongs to the session you previewed.
5. Report the memory freed and how to continue, which the script prints:
   - Claude desktop app: click the session in the sidebar and send a message; the app restarts it from the transcript with the same conversation.
   - Terminal: `claude --resume <session-id>` in the session's folder.

Pass `--force` only for a busy session the user explicitly agreed to interrupt after hearing the warning in step 3. Never stop Claude desktop app processes, and never kill processes by hand instead of using the script.
