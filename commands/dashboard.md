---
description: Open a local web dashboard with every Claude Code session's memory use and an Unload button
---

Start the RAM Sleeper dashboard in the background (it keeps running after this turn and stops by itself 15 minutes after the page is closed):

```bash
node "${CLAUDE_PLUGIN_ROOT}/skills/ramsleeper/scripts/sessions.mjs" serve
```

It opens the page in the default browser and prints its link, which carries a one-time token. Give the user that link in case the browser did not open. The page lists the sessions and asks for confirmation in the page before each unload; the session you are running in is marked and cannot be unloaded from it.
