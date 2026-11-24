// Colors this window in the project's dashboard color, so project windows are
// easy to tell apart: title bar, activity bar and status bar in the full color,
// the backgrounds (editor, side bars, tabs, panel) in a dark tint of it.
//
// VS Code has no API to color a single window. The only way is the setting
// workbench.colorCustomizations in the workspace, i.e. the project's
// .vscode/settings.json. That is also why the color is back right away when the
// project opens again. Because it writes into the project folder, it is opt-in
// (per project in the color picker of the dashboard or the menu bar app, for
// all projects at once in the app's gear menu; stored in prefs.json), and only
// the keys below are ever touched.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const { PALETTE, projectColor } = require('../media/palette');

const SETTING = 'workbench.colorCustomizations';
const LIGHT_TEXT = '#ffffff';
const DARK_TEXT = '#1e1e1e';

function luminance(hex) {
  const channel = (i) => {
    const c = parseInt(hex.slice(i, i + 2), 16) / 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5);
}

// White or dark text, whichever contrasts more with the color.
function textOn(hex) {
  const l = luminance(hex);
  const onLight = (l + 0.05) / (luminance(DARK_TEXT) + 0.05);
  const onDark = 1.05 / (l + 0.05);
  return onDark >= onLight ? LIGHT_TEXT : DARK_TEXT;
}

// The backgrounds take on the color too, mixed into dark (or light) base tones
// so that text and syntax colors stay readable. The extension API cannot read
// the theme's real colors, so the bases are those of VS Code's default themes
// ("Dark Modern" / "Light Modern"); every surface gets mixed the same way, so
// the window looks consistent with other themes too.
const BASES = {
  dark: { editor: '#1f1f1f', side: '#181818' },
  light: { editor: '#ffffff', side: '#f8f8f8' },
};
// Share of the project color in the backgrounds.
const TINT = { dark: 0.24, light: 0.14 };

function mix(base, hex, amount) {
  let out = '#';
  for (const i of [1, 3, 5]) {
    const value = parseInt(base.slice(i, i + 2), 16) * (1 - amount) + parseInt(hex.slice(i, i + 2), 16) * amount;
    out += Math.round(value).toString(16).padStart(2, '0');
  }
  return out;
}

// 'dark', 'light', or 'contrast' (high-contrast themes: only the frame).
function themeKind() {
  const theme = vscode.window.activeColorTheme;
  if (theme && theme.kind === vscode.ColorThemeKind.Light) return 'light';
  if (theme && theme.kind === vscode.ColorThemeKind.Dark) return 'dark';
  return 'contrast';
}

function backgroundKeys(hex, kind) {
  const base = BASES[kind];
  if (!base) return {};
  const editor = mix(base.editor, hex, TINT[kind]);
  const side = mix(base.side, hex, TINT[kind]);
  return {
    'editor.background': editor,
    'editorGutter.background': editor,
    'editorPane.background': editor,
    'editorStickyScroll.background': editor,
    'editorGroupHeader.noTabsBackground': editor,
    'breadcrumb.background': editor,
    'welcomePage.background': editor,
    'tab.activeBackground': editor,
    'tab.unfocusedActiveBackground': editor,
    'editorGroupHeader.tabsBackground': side,
    'tab.inactiveBackground': side,
    'tab.unfocusedInactiveBackground': side,
    'sideBar.background': side,
    'sideBarTitle.background': side,
    'sideBarSectionHeader.background': side,
    'sideBarStickyScroll.background': side,
    'panel.background': side,
    'panelStickyScroll.background': side,
    'terminal.background': side,
    // The thin accent lines (active tab, active panel) in the project color.
    'tab.activeBorderTop': hex,
    'panelTitle.activeBorder': hex,
  };
}

// Everything this feature sets for one color and kind of theme ('frame' or
// 'contrast': the frame only).
function colorKeys(hex, kind = 'frame') {
  return { ...frameKeys(hex), ...backgroundKeys(hex, kind) };
}

// Title bar, activity bar and status bar in the full color.
function frameKeys(hex) {
  const text = textOn(hex);
  return {
    'titleBar.activeBackground': hex,
    'titleBar.activeForeground': text,
    // Windows in the background keep their color, slightly muted.
    'titleBar.inactiveBackground': hex + 'cc',
    'titleBar.inactiveForeground': text + '99',
    'activityBar.background': hex,
    'activityBar.foreground': text,
    'activityBar.inactiveForeground': text + '99',
    'activityBar.activeBorder': text,
    'activityBarBadge.background': text,
    'activityBarBadge.foreground': hex,
    'statusBar.background': hex,
    'statusBar.foreground': text,
    'statusBarItem.remoteBackground': hex,
    'statusBarItem.remoteForeground': text,
  };
}

// Removes the keys this feature set earlier (recognized by their values), so
// colors someone set by hand stay untouched.
function withoutOurs(values) {
  const background = values['titleBar.activeBackground'];
  const hex = typeof background === 'string' && PALETTE.find((c) => c === background.toLowerCase());
  if (!hex) return values;
  const rest = { ...values };
  // Written under any kind of theme (the theme may have changed since).
  for (const kind of ['dark', 'light', 'contrast']) {
    for (const [key, value] of Object.entries(colorKeys(hex, kind))) {
      if (typeof rest[key] === 'string' && rest[key].toLowerCase() === value) delete rest[key];
    }
  }
  return rest;
}

function sameValues(a, b) {
  const keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every((key) => a[key] === b[key]);
}

class WindowColor {
  constructor({ root, store, prefs }) {
    this.root = root;
    this.store = store;
    this.prefs = prefs;
    this.queue = Promise.resolve();
  }

  // Only windows with exactly one folder: that is one project.
  get folder() {
    const folders = vscode.workspace.workspaceFolders || [];
    return folders.length === 1 && folders[0].uri.scheme === 'file' ? folders[0].uri.fsPath : null;
  }

  // Claude Code names the session folder after the project path, with every
  // character other than A–Z, a–z and 0–9 turned into "-".
  get encodedFolder() {
    const folder = this.folder;
    return folder ? folder.replace(/[^a-zA-Z0-9]/g, '-') : null;
  }

  // The project's folder name under ~/.claude/projects, or null if this window
  // is not a Claude project (yet).
  projectDir() {
    const folder = this.folder;
    if (!folder) return null;
    if (this.store.loaded) {
      const project = this.store.projects.find((p) => p.path === folder);
      if (project) return project.dir;
    }
    const encoded = this.encodedFolder;
    return fs.existsSync(path.join(this.root, encoded)) ? encoded : null;
  }

  // A session file changed: if it is the first one of this project, color now.
  noticeSessionFolder(name) {
    if (name === this.encodedFolder) this.update();
  }

  update() {
    this.queue = this.queue.then(() => this.apply()).catch(() => {});
    return this.queue;
  }

  async apply() {
    const folder = this.folder;
    if (!folder) return;
    const config = vscode.workspace.getConfiguration();
    const inspected = config.inspect(SETTING);
    const current = inspected && inspected.workspaceValue;
    const before = current && typeof current === 'object' && !Array.isArray(current) ? current : {};

    let after = withoutOurs(before);
    const dir = this.projectDir();
    if (dir && this.prefs.colorWindowFor(dir)) {
      // "Frame only" leaves the backgrounds to the theme.
      const kind = this.prefs.colorWindowsStyle === 'frame' ? 'frame' : themeKind();
      after = { ...after, ...colorKeys(projectColor(dir, this.prefs.color(dir)), kind) };
    }
    if (sameValues(before, after)) return;

    await config.update(
      SETTING,
      Object.keys(after).length ? after : undefined,
      vscode.ConfigurationTarget.Workspace
    );
    if (!Object.keys(after).length) this.removeEmptySettings(folder);
  }

  // Turned off: don't leave an empty .vscode/settings.json behind. Only a file
  // that holds nothing at all is removed, and the folder only if it is empty.
  removeEmptySettings(folder) {
    if (vscode.workspace.workspaceFile) return;
    const dir = path.join(folder, '.vscode');
    const file = path.join(dir, 'settings.json');
    try {
      if (fs.readFileSync(file, 'utf8').replace(/\s+/g, '') !== '{}') return;
      fs.unlinkSync(file);
      if (!fs.readdirSync(dir).length) fs.rmdirSync(dir);
    } catch {
      // Then the empty file simply stays.
    }
  }
}

module.exports = { WindowColor, colorKeys, withoutOurs, textOn, mix };
