// Dashboard UI. Runs inside the webview, without network access or third-party scripts.
// Content is only ever set via textContent, never as HTML.

(function () {
  'use strict';

  const vscode = acquireVsCodeApi();
  const app = document.getElementById('app');
  const saved = vscode.getState() || {};

  const WORKING_MS = 3 * 60 * 1000; // open turn, last write less than 3 min ago
  const RECENT_MS = 12 * 60 * 60 * 1000; // "recent" = last 12 hours
  const RECENT_MAX = 8;
  const CARD_MIN = 232; // must match .grid in dashboard.css
  const CARD_GAP = 8;

  // Muted tones that work in both light and dark themes. The menu bar app uses
  // the same list (menubar/Sources/Store.swift) – keep both in sync, and only
  // ever add colors at the end: a project's color is stored as its position.
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

  // --- Translations (English default, German when VS Code runs in German)

  const STRINGS = {
    en: {
      heading: 'Claude Projects',
      search: 'Search',
      searchLabel: 'Search projects and sessions',
      loading: 'Loading…',
      project: ['project', 'projects'],
      session: ['session', 'sessions'],
      workingCount: (n) => n + ' working',
      now: 'Now',
      nowWorking: (n) => n + (n === 1 ? ' session working' : ' sessions working'),
      nowRecent: 'recently used',
      working: 'working',
      waiting: 'waiting for you',
      done: 'done',
      untitled: 'Untitled',
      changeColor: 'Change color',
      chooseColor: 'Choose color',
      thisWindow: 'this window',
      folderMissing: 'folder missing',
      all: (n) => 'All ' + n,
      less: 'Show less',
      archive: 'Archive',
      restore: 'Restore',
      archiveHint: 'Move to the archive (deletes nothing)',
      restoreHint: 'Move back to the overview',
      openWindow: 'Open window',
      archiveToggle: (n) => 'Archive · ' + n + (n === 1 ? ' project' : ' projects'),
      emptyTitle: 'No sessions yet',
      emptyText: 'As soon as you work on a project with Claude Code, it shows up here.',
      noMatchTitle: 'Nothing found',
      noMatchText: (q) => 'No session matches “' + q + '”.',
      justNow: 'just now',
      minutesAgo: (n) => n + ' min ago',
      hoursAgo: (n) => n + ' h ago',
      yesterday: 'yesterday',
      daysAgo: (n) => n + ' days ago',
      dateLocale: 'en-US',
    },
    de: {
      heading: 'Claude Projekte',
      search: 'Suchen',
      searchLabel: 'Projekte und Sitzungen durchsuchen',
      loading: 'Lädt …',
      project: ['Projekt', 'Projekte'],
      session: ['Sitzung', 'Sitzungen'],
      workingCount: (n) => n + ' arbeitet',
      now: 'Aktuell',
      nowWorking: (n) => n + (n === 1 ? ' Sitzung arbeitet' : ' Sitzungen arbeiten'),
      nowRecent: 'zuletzt benutzt',
      working: 'arbeitet',
      waiting: 'wartet auf dich',
      done: 'fertig',
      untitled: 'Ohne Titel',
      changeColor: 'Farbe ändern',
      chooseColor: 'Farbe wählen',
      thisWindow: 'dieses Fenster',
      folderMissing: 'Ordner fehlt',
      all: (n) => 'Alle ' + n,
      less: 'Weniger',
      archive: 'Archivieren',
      restore: 'Wiederherstellen',
      archiveHint: 'Ins Archiv verschieben (löscht nichts)',
      restoreHint: 'Zurück in die Übersicht holen',
      openWindow: 'Fenster öffnen',
      archiveToggle: (n) => 'Archiv · ' + n + (n === 1 ? ' Projekt' : ' Projekte'),
      emptyTitle: 'Noch keine Sitzungen',
      emptyText: 'Sobald du in einem Projekt mit Claude Code arbeitest, erscheint es hier.',
      noMatchTitle: 'Nichts gefunden',
      noMatchText: (q) => 'Keine Sitzung passt zu „' + q + '“.',
      justNow: 'gerade eben',
      minutesAgo: (n) => 'vor ' + n + ' Min.',
      hoursAgo: (n) => 'vor ' + n + ' Std.',
      yesterday: 'gestern',
      daysAgo: (n) => 'vor ' + n + ' Tagen',
      dateLocale: 'de-DE',
    },
  };

  let T = STRINGS[document.documentElement.lang] || STRINGS.en;

  const state = {
    loaded: false,
    projects: [],
    query: saved.query || '',
    expanded: saved.expanded || {},
    showArchive: !!saved.showArchive,
    picker: null,
    lastData: '',
  };

  function persist() {
    vscode.setState({
      query: state.query,
      expanded: state.expanded,
      showArchive: state.showArchive,
    });
  }

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(className, text, title, onClick) {
    const node = el('button', className, text);
    node.type = 'button';
    if (title) node.title = title;
    node.addEventListener('click', (event) => {
      event.stopPropagation();
      onClick();
    });
    return node;
  }

  function count(n, forms) {
    return n + ' ' + (n === 1 ? forms[0] : forms[1]);
  }

  function relTime(ts, now) {
    const min = Math.floor(Math.max(0, now - ts) / 60000);
    if (min < 1) return T.justNow;
    if (min < 60) return T.minutesAgo(min);
    const hours = Math.floor(min / 60);
    if (hours < 24) return T.hoursAgo(hours);
    const days = Math.floor(hours / 24);
    if (days === 1) return T.yesterday;
    if (days < 7) return T.daysAgo(days);
    const date = new Date(ts);
    return date.toLocaleDateString(T.dateLocale, {
      day: 'numeric',
      month: 'short',
      year: date.getFullYear() === new Date(now).getFullYear() ? undefined : 'numeric',
    });
  }

  // Derived from the session files, so it is an estimate:
  //   working – Claude is mid-turn and wrote something just now
  //   waiting – the turn is open but nothing has happened for a while (question, permission)
  //   done    – Claude finished its turn
  function status(session, now) {
    if (!session.openTurn) return 'done';
    return now - session.lastTs < WORKING_MS ? 'working' : 'waiting';
  }

  const STATUS_ORDER = { working: 0, waiting: 1, done: 2 };

  function hash(text) {
    let h = 0;
    for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) >>> 0;
    return h;
  }

  function colorOf(project) {
    return Number.isInteger(project.color)
      ? PALETTE[project.color % PALETTE.length]
      : PALETTE[hash(project.dir) % DEFAULT_COLORS];
  }

  function titleOf(session) {
    return session.title || T.untitled;
  }

  // --- Frame (kept across renders so the search field keeps its focus)

  const header = el('header', 'top');
  const headText = el('div', 'top-text');
  const heading = el('h1');
  const stats = el('p', 'stats');
  headText.append(heading, stats);

  const searchWrap = el('label', 'search');
  const searchIcon = el('span', 'search-icon');
  searchIcon.setAttribute('aria-hidden', 'true');
  const search = el('input');
  search.type = 'search';
  search.spellcheck = false;
  search.value = state.query;
  searchWrap.append(searchIcon, search);

  const headInner = el('div', 'top-inner');
  headInner.append(headText, searchWrap);
  header.append(headInner);

  const main = el('main');
  app.append(header, main);

  search.addEventListener('input', () => {
    state.query = search.value;
    persist();
    render();
  });

  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    if (state.picker) {
      state.picker = null;
      render();
    } else if (document.activeElement === search && search.value) {
      search.value = '';
      state.query = '';
      persist();
      render();
    }
  });

  document.addEventListener('click', () => {
    if (state.picker) {
      state.picker = null;
      render();
    }
  });

  // How many cards fit in one row? Collapsed, every project shows exactly one row.
  function columns() {
    const style = getComputedStyle(main);
    const width = main.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    return Math.max(1, Math.floor((width + CARD_GAP) / (CARD_MIN + CARD_GAP)));
  }

  let lastColumns = 0;
  new ResizeObserver(() => {
    if (columns() !== lastColumns) render();
  }).observe(main);

  // --- Content

  function matches(text, words) {
    const hay = text.toLowerCase();
    return words.every((word) => hay.includes(word));
  }

  function filtered(projects, words) {
    if (!words.length) return projects.map((p) => ({ project: p, sessions: p.sessions }));
    const result = [];
    for (const project of projects) {
      if (matches(project.name, words)) {
        result.push({ project, sessions: project.sessions });
        continue;
      }
      const sessions = project.sessions.filter((s) =>
        matches(project.name + ' ' + titleOf(s) + ' ' + s.excerpt, words)
      );
      if (sessions.length) result.push({ project, sessions });
    }
    return result;
  }

  // Compact card: title and time on the first line, one line of context below.
  function card(project, session, now, withProject) {
    const kind = status(session, now);
    const recent = now - session.lastTs < RECENT_MS;
    const showStatus = kind === 'working' || (recent && (withProject || kind === 'waiting'));
    const title = titleOf(session);

    const node = el('button', 'card' + (showStatus ? ' is-' + kind : ''));
    node.type = 'button';
    node.style.setProperty('--pc', colorOf(project));
    node.title = title + (session.excerpt ? '\n\n' + session.excerpt : '');

    const first = el('div', 'card-row');
    if (showStatus) first.append(el('span', 'dot dot-' + kind));
    first.append(el('span', 'card-title', title), el('time', null, relTime(session.lastTs, now)));

    const second = el('div', 'card-row card-sub');
    if (withProject) second.append(el('span', 'tag', project.name));
    if (showStatus) second.append(el('span', 'state state-' + kind, T[kind]));
    if (session.excerpt) second.append(el('span', 'card-text', session.excerpt));

    node.append(first, second);
    node.addEventListener('click', () => {
      vscode.postMessage({ type: 'openSession', dir: project.dir, id: session.id });
    });
    return node;
  }

  // Top section: what is running right now, then what was used recently – across all projects.
  function nowSection(projects, now, cols) {
    const items = [];
    for (const project of projects) {
      for (const session of project.sessions) {
        const kind = status(session, now);
        if (kind === 'working' || now - session.lastTs < RECENT_MS) {
          items.push({ project, session, kind });
        }
      }
    }
    if (!items.length) return null;
    items.sort(
      (a, b) => STATUS_ORDER[a.kind] - STATUS_ORDER[b.kind] || b.session.lastTs - a.session.lastTs
    );
    const working = items.filter((i) => i.kind === 'working').length;
    const limit = Math.max(working, Math.min(RECENT_MAX, cols * 2));

    const node = el('section', 'now');
    const head = el('div', 'project-head');
    head.append(
      el('h2', 'now-title', T.now),
      el('span', 'meta', working ? T.nowWorking(working) : T.nowRecent)
    );
    node.append(head);
    const grid = el('div', 'grid');
    for (const item of items.slice(0, limit)) {
      grid.append(card(item.project, item.session, now, true));
    }
    node.append(grid);
    return node;
  }

  function colorPicker(project) {
    const node = el('div', 'picker');
    node.addEventListener('click', (event) => event.stopPropagation());
    PALETTE.forEach((color, index) => {
      const swatch = button(
        'swatch' + (colorOf(project) === color ? ' is-selected' : ''),
        '',
        T.chooseColor,
        () => {
          project.color = index;
          state.picker = null;
          vscode.postMessage({ type: 'setColor', dir: project.dir, color: index });
          render();
        }
      );
      swatch.style.setProperty('--pc', color);
      node.append(swatch);
    });
    return node;
  }

  function section(entry, now, searching, cols) {
    const { project, sessions } = entry;
    const node = el('section', 'project');
    node.style.setProperty('--pc', colorOf(project));

    const head = el('div', 'project-head');
    head.append(
      button('color-dot', '', T.changeColor, () => {
        state.picker = state.picker === project.dir ? null : project.dir;
        render();
      })
    );
    const name = el('h2', null, project.name);
    name.title = project.path || project.dir;
    head.append(name);
    if (state.picker === project.dir) head.append(colorPicker(project));
    if (project.current) head.append(el('span', 'pill', T.thisWindow));
    if (project.missing) head.append(el('span', 'pill pill-muted', T.folderMissing));
    head.append(
      el('span', 'meta', count(project.sessions.length, T.session) + ' · ' + relTime(project.lastTs, now))
    );
    head.append(el('span', 'spacer'));

    const showAll = searching || !!state.expanded[project.dir];
    if (!searching && sessions.length > cols) {
      head.append(
        button('link', showAll ? T.less : T.all(sessions.length), null, () => {
          state.expanded[project.dir] = !showAll;
          persist();
          render();
        })
      );
    }
    head.append(
      button(
        'link link-quiet',
        project.archived ? T.restore : T.archive,
        project.archived ? T.restoreHint : T.archiveHint,
        () => {
          project.archived = !project.archived;
          vscode.postMessage({ type: 'setArchived', dir: project.dir, value: project.archived });
          render();
        }
      )
    );
    if (!project.current && !project.missing) {
      const open = button('ghost', T.openWindow, null, () => {
        vscode.postMessage({ type: 'openProject', dir: project.dir });
      });
      open.append(el('span', 'arrow'));
      head.append(open);
    }
    node.append(head);

    const grid = el('div', 'grid');
    for (const session of showAll ? sessions : sessions.slice(0, cols)) {
      grid.append(card(project, session, now, false));
    }
    node.append(grid);
    return node;
  }

  function empty(title, text) {
    const node = el('div', 'empty');
    node.append(el('h2', null, title), el('p', null, text));
    return node;
  }

  function render() {
    const now = Date.now();
    const cols = columns();
    lastColumns = cols;

    heading.textContent = T.heading;
    search.placeholder = T.search;
    search.setAttribute('aria-label', T.searchLabel);

    const active = state.projects.filter((p) => !p.archived);
    const archived = state.projects.filter((p) => p.archived);
    const sessionCount = active.reduce((sum, p) => sum + p.sessions.length, 0);
    const workingCount = active.reduce(
      (sum, p) => sum + p.sessions.filter((s) => status(s, now) === 'working').length,
      0
    );

    stats.replaceChildren();
    if (state.loaded) {
      stats.append(
        el('span', null, count(active.length, T.project)),
        el('span', 'sep', '·'),
        el('span', null, count(sessionCount, T.session))
      );
      if (workingCount) {
        const live = el('span', 'live');
        live.append(el('span', 'dot dot-working'), el('span', null, T.workingCount(workingCount)));
        stats.append(el('span', 'sep', '·'), live);
      }
    } else {
      stats.append(el('span', null, T.loading));
    }

    const words = state.query.toLowerCase().split(/\s+/).filter(Boolean);
    const searching = words.length > 0;
    const nodes = [];

    if (!searching) {
      const top = nowSection(active, now, cols);
      if (top) nodes.push(top);
    }

    const entries = filtered(active, words);
    for (const entry of entries) nodes.push(section(entry, now, searching, cols));

    const archivedEntries = filtered(archived, words);
    if (archivedEntries.length) {
      const open = searching || state.showArchive;
      const toggle = button(
        'archive-toggle' + (open ? ' is-open' : ''),
        T.archiveToggle(archivedEntries.length),
        null,
        () => {
          state.showArchive = !state.showArchive;
          persist();
          render();
        }
      );
      toggle.prepend(el('span', 'arrow'));
      const wrap = el('div', 'archive');
      wrap.append(toggle);
      if (open) for (const entry of archivedEntries) wrap.append(section(entry, now, searching, cols));
      nodes.push(wrap);
    }

    if (state.loaded && !state.projects.length) {
      nodes.push(empty(T.emptyTitle, T.emptyText));
    } else if (state.loaded && searching && !entries.length && !archivedEntries.length) {
      nodes.push(empty(T.noMatchTitle, T.noMatchText(state.query.trim())));
    }
    main.replaceChildren(...nodes);
  }

  window.addEventListener('message', (event) => {
    const message = event.data;
    if (!message || message.type !== 'data') return;
    if (message.lang && STRINGS[message.lang]) T = STRINGS[message.lang];
    // Only redraw when something actually changed.
    const raw = JSON.stringify(message.projects || []);
    if (state.loaded && raw === state.lastData) return;
    state.lastData = raw;
    state.projects = message.projects || [];
    state.loaded = true;
    render();
  });

  // Keep relative times and status fresh even without new data.
  setInterval(() => {
    if (!document.hidden && !state.picker) render();
  }, 30 * 1000);

  render();
  vscode.postMessage({ type: 'ready' });
})();
