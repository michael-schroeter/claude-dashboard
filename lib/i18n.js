// Strings shown by the extension host (tree view, notifications).
// The dashboard webview has its own copy in media/dashboard.js.
// English is the default; German is used when VS Code runs in German.

'use strict';

const STRINGS = {
  en: {
    folderMissing: (folder) => `The folder “${folder}” no longer exists.`,
    thisWindow: (name) => `“${name}” is this window.`,
    statusTooltip: 'All Claude Code sessions across all projects',
    openSession: 'Open session',
    untitled: 'Untitled',
    openFailed: (reason) => `Could not open the session: ${reason}`,
    claudeInactive:
      'The Claude Code extension is not active in this window, so the session could not be opened.',
    justNow: 'just now',
    minutesAgo: (n) => `${n} min ago`,
    hoursAgo: (n) => `${n} h ago`,
    yesterday: 'yesterday',
    daysAgo: (n) => `${n} days ago`,
  },
  de: {
    folderMissing: (folder) => `Der Ordner „${folder}“ existiert nicht mehr.`,
    thisWindow: (name) => `„${name}“ ist dieses Fenster.`,
    statusTooltip: 'Alle Claude-Code-Sitzungen aller Projekte',
    openSession: 'Sitzung öffnen',
    untitled: 'Ohne Titel',
    openFailed: (reason) => `Die Sitzung ließ sich nicht öffnen: ${reason}`,
    claudeInactive:
      'Die Claude-Code-Erweiterung ist in diesem Fenster nicht aktiv. Die Sitzung wurde nicht geöffnet.',
    justNow: 'gerade eben',
    minutesAgo: (n) => `vor ${n} Min.`,
    hoursAgo: (n) => `vor ${n} Std.`,
    yesterday: 'gestern',
    daysAgo: (n) => `vor ${n} Tagen`,
  },
};

function pickLanguage(language) {
  return typeof language === 'string' && language.toLowerCase().startsWith('de') ? 'de' : 'en';
}

function strings(lang) {
  return STRINGS[lang] || STRINGS.en;
}

function relTime(ts, lang, now = Date.now()) {
  const t = strings(lang);
  const min = Math.floor(Math.max(0, now - ts) / 60000);
  if (min < 1) return t.justNow;
  if (min < 60) return t.minutesAgo(min);
  const hours = Math.floor(min / 60);
  if (hours < 24) return t.hoursAgo(hours);
  const days = Math.floor(hours / 24);
  if (days === 1) return t.yesterday;
  if (days < 7) return t.daysAgo(days);
  const date = new Date(ts);
  const sameYear = date.getFullYear() === new Date(now).getFullYear();
  return date.toLocaleDateString(lang === 'de' ? 'de-DE' : 'en-US', {
    day: 'numeric',
    month: 'short',
    year: sameYear ? undefined : 'numeric',
  });
}

module.exports = { pickLanguage, strings, relTime };
