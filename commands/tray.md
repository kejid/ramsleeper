---
description: Start the RAM Sleeper icon in the Windows notification area (or explain the menu bar setup on macOS and Linux)
---

On Windows, start the tray icon so it keeps running after this session ends:

```bash
powershell.exe -NoProfile -Command "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File','\"${CLAUDE_PLUGIN_ROOT}/companion/windows-tray/ramsleeper-tray.ps1\"'"
```

A second copy exits by itself, so running this again is harmless. Tell the user: the number on the icon is how many sessions have been idle for a few minutes (3 by default, changeable on the setup page), and its color is how much of the RAM all Claude Code sessions hold (green, amber, red); hovering shows the exact figures; left-click lists the sessions with Unload buttons; right-click has "Start at Windows sign-in". After a plugin update, that option should be switched off and on again so it points at the new version.

On macOS or Linux, don't run anything. Explain that the menu bar item needs xbar or SwiftBar (macOS), or Argos (GNOME) or Kargos (KDE), and give this command to link it, with the plugin folder of the app they use:

```bash
ln -s "${CLAUDE_PLUGIN_ROOT}/companion/menubar/ramsleeper.30s.sh" "<plugin folder>/ramsleeper.30s.sh"
```
