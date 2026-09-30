---
description: Set up RAM Sleeper - check requirements, start the tray or menu bar icon, and read the FAQ on one local page
---

Start the RAM Sleeper dashboard on its setup page, in the background:

```bash
node "${CLAUDE_PLUGIN_ROOT}/skills/ramsleeper/scripts/sessions.mjs" serve --setup
```

It opens a local page (127.0.0.1 only) that checks Node.js, lists the plugin's commands, offers to start the Windows tray icon and turn on start at sign-in, gives the menu bar commands on macOS and Linux, and answers common questions. Give the user the printed link in case the window did not open, and say in one sentence what the page is for.
