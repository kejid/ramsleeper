---
description: List Claude Code sessions with their memory use, or unload one ("unload <number>")
argument-hint: "[unload <number|title>]"
---

Use the ramsleeper skill.

Arguments: $ARGUMENTS

- No arguments: list the running sessions with their memory use.
- `unload <number or title>`: follow the skill's unload steps for that session, including the preview and the user's explicit confirmation before anything is stopped. A number refers to the row in the list you showed last; take that row's PID. If no list was shown in this conversation, run `list` first and ask which one. The preview prints the title, so check it matches what the user meant.
