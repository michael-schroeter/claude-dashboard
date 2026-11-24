// Project colors. Used by the dashboard (webview) and by the extension itself,
// which colors each project window to match. The menu bar app has the same list
// in menubar/Sources/Store.swift – keep both in sync, and only ever add colors
// at the end: a project's color is stored as its position.

(function (root) {
  'use strict';

  // Muted tones that work in both light and dark themes.
  const PALETTE = [
    '#d97757', '#d9a441', '#7fb069', '#45a89f',
    '#4f9be0', '#8a7fe0', '#cf6fae', '#8b95a1',
    '#d65c5c', '#e08a3c', '#b5c24a', '#5fb878',
    '#4cb38a', '#3aa3c4', '#6c78e0', '#a56fe0',
    '#c964d6', '#e0668f', '#b5836a', '#9a8f7a',
    '#6f8f8a', '#5f6b7a', '#a9b0ba', '#b89f5a',
  ];
  // Projects without a chosen color get one of the first eight, by name.
  const DEFAULT_COLORS = 8;

  function hash(text) {
    let h = 0;
    for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) >>> 0;
    return h;
  }

  // dir: the project's folder name under ~/.claude/projects.
  // index: the chosen position in PALETTE, or null/undefined for the default.
  function projectColor(dir, index) {
    return Number.isInteger(index)
      ? PALETTE[index % PALETTE.length]
      : PALETTE[hash(dir) % DEFAULT_COLORS];
  }

  const api = { PALETTE, projectColor };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.ClaudePalette = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
