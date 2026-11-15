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
    menubarHint: 'Claude Dashboard is also available as a menu bar app for your Mac.',
    menubarInstallButton: 'Install',
    menubarUpdateHint: (v) => `A new version of the menu bar app is included (${v}).`,
    menubarUpdateButton: 'Update',
    menubarConfirm: (dir) => `Install the menu bar app in “${dir}”?`,
    menubarConfirmDetail:
      'It comes with this extension, nothing is downloaded. It shows your sessions in the menu bar and reads them locally only. To remove it, quit it from its gear menu and delete it from the folder.',
    menubarInstalled: (dir) => `The menu bar app is installed in “${dir}” and running. Look for the small agent in the menu bar.`,
    menubarFailed: (reason) => `Could not install the menu bar app: ${reason}`,
    menubarUnavailable: 'The menu bar app is only available on macOS.',
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
    menubarHint: 'Claude Dashboard gibt es auch als App für die Menüleiste deines Macs.',
    menubarInstallButton: 'Installieren',
    menubarUpdateHint: (v) => `Eine neue Version der Menüleisten-App ist dabei (${v}).`,
    menubarUpdateButton: 'Aktualisieren',
    menubarConfirm: (dir) => `Die Menüleisten-App in „${dir}“ installieren?`,
    menubarConfirmDetail:
      'Sie ist in dieser Erweiterung enthalten, es wird nichts heruntergeladen. Sie zeigt deine Sitzungen in der Menüleiste und liest sie nur lokal. Entfernen: im Zahnrad-Menü der App beenden und die App aus dem Ordner löschen.',
    menubarInstalled: (dir) => `Die Menüleisten-App ist in „${dir}“ installiert und läuft. Du findest sie als kleinen Agenten oben in der Menüleiste.`,
    menubarFailed: (reason) => `Die Menüleisten-App ließ sich nicht installieren: ${reason}`,
    menubarUnavailable: 'Die Menüleisten-App gibt es nur für macOS.',
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
