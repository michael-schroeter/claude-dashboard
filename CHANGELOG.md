# Changelog

## 0.6.3 – 2026-11-23

- **Colored windows (optional):** each project window can take on its
  dashboard color: title bar, activity bar and status bar in the full color,
  editor, side bars, tabs and terminal in a dark tint of it. Per project: tick
  "Color the VS Code window too" in the color picker (dashboard, or the menu
  bar app's edit mode). All projects at once: gear menu of the menu bar app,
  or the "…" menu of the Projects view in VS Code. There you also choose
  "Frame only" or "Whole window" (the default). A color changed in either
  place shows up in open windows right away. VS Code stores the colors in the
  project's `.vscode/settings.json`, so they are there again when the project
  opens; turning the option off removes them.

## 0.5.0 – 2026-11-17

- **Now on the VS Code Marketplace.** Install it from the Extensions view and
  updates arrive on their own. The extension ID is now
  `michael-schroeter.claude-sessions-dashboard`.
- **Coming from a .vsix (0.4 or older)?** The new version notices the older
  copy and offers to remove it. Your colors, titles and archive are taken over.
- The menu bar app (0.5.0) uses the settings of the new version, and those of
  the older copy until the new one has started once.
- New icon and a short demo in the README.

## 0.4.0 – 2026-11-15

- **One download for everything:** the menu bar app comes inside the
  extension. Open the dashboard and a note offers to install it with one click;
  later versions offer to update it once. Nothing is downloaded.
- Menu bar app: its own app icon, and tiles can be placed freely in edit mode
  (gaps stay, each number of columns keeps its own layout).

## 0.3.3 – 2026-11-13

- Menu bar app: a **"+" tile** starts a new project in a folder you choose; the
  gear menu sets the folder in which the chooser starts.

## 0.3.2 – 2026-11-13

- **24 project colors**, the same in the dashboard and the menu bar app.
- Menu bar app: own project titles (also shown in the dashboard), about 270
  symbols, tiles keep their place.

## 0.3.1 – 2026-11-13

- Menu bar app: clear glass with a soft blur like Control Center, new menu bar
  icon, several layout fixes.

## 0.3.0 – 2026-11-13

- **Menu bar app for macOS** (optional): sessions that are working or waiting
  for you, project tiles, edit mode, 2 to 5 columns.

## 0.2.0 – 2026-11-12

- First public version: dashboard tab with cards per session, "Now" section,
  status (working · waiting for you · done), project colors and archive,
  sidebar view, jump into the right window and session. English and German UI.
