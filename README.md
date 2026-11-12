# Claude Dashboard

A VS Code extension that shows all your **Claude Code** sessions from every
project in one place. No more hunting through a dozen VS Code windows: click a
session and the right project window comes to the front with that session open.

> Unofficial community project – not affiliated with or endorsed by Anthropic.

## Features

- **Dashboard tab:** compact cards for every session, grouped by project, with
  title, last activity and Claude's latest message.
- **"Now" at the top:** sessions that are working or waiting for you, plus the
  ones you used recently – across all projects.
- **Status:** working · waiting for you · done (estimated from the session files).
- **Organize:** give each project a color (click its color dot), archive
  projects you don't need right now and restore them later.
- **Sidebar view "Claude Projects"** listing all projects and sessions.
- Follows your VS Code theme, light and dark. English and German UI (follows
  the VS Code display language).

## Requirements

- VS Code 1.94 or newer
- The **Claude Code** extension by Anthropic, signed in and in use. The
  dashboard reads its sessions.

## Install

1. Download `claude-dashboard-<version>.vsix` from the
   [Releases](https://github.com/michael-schroeter/claude-dashboard/releases) page.
2. In VS Code open **Extensions** → **"…"** (top right) →
   **"Install from VSIX…"** and pick the file.
3. Reload every open VS Code window once
   (`Cmd/Ctrl+Shift+P` → "Developer: Reload Window").
4. Click **"Claude Dashboard"** in the status bar (bottom left).

Updates are not automatic: to update, install the newer `.vsix` the same way.

## Privacy

The extension reads Claude Code's session files (`~/.claude/projects`)
**locally only**. It has no network access, sends nothing anywhere and loads no
third-party scripts. Colors and the archive are stored locally in the
extension's own storage folder.

## Good to know

- Opening a session relies on an **undocumented** command of the Claude Code
  extension. An update of Claude Code may break jumping into the session; the
  project window still opens.
- "waiting for you" is an estimate: Claude is in the middle of a turn but
  hasn't written anything for 3 minutes (usually a question or a permission
  prompt).
- So far only tested on macOS.

## Uninstall

In VS Code: **Extensions** → "Claude Dashboard" → **Uninstall**.

## Build it yourself

No Node or npm required, just Python 3:

```sh
python3 tools/package.py
```

The package ends up in `dist/`.

## License

[MIT](LICENSE)
