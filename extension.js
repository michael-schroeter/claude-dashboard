// Claude Dashboard – all Claude Code sessions across all projects in one place.
// Reads ~/.claude/projects locally only. No network access.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { scanProjects, isActive } = require('./lib/sessions');
const i18n = require('./lib/i18n');

const LANG = i18n.pickLanguage(vscode.env.language);
const T = i18n.strings(LANG);
const relTime = (ts) => i18n.relTime(ts, LANG);

const ROOT = path.join(os.homedir(), '.claude', 'projects');
const CLAUDE_OPEN_COMMAND = 'claude-vscode.primaryEditor.open';
const PANEL_TYPE = 'claudeDashboard.panel';
const REQUEST_MAX_AGE_MS = 60 * 1000;
const TREE_SESSION_LIMIT = 25;

function activate(context) {
  const prefs = new Prefs(context);
  const store = new Store();
  const tree = new ProjectTree(store, prefs);
  const dashboard = new Dashboard(context, store, prefs);
  const opener = new SessionOpener(context);
  prefs.onDidChange(() => {
    tree.redraw();
    dashboard.post();
  });

  const view = vscode.window.createTreeView('claudeDashboard.projects', {
    treeDataProvider: tree,
    showCollapseAll: true,
  });

  // Only rescan while someone is looking; otherwise remember and catch up later.
  const isWatched = () => view.visible || dashboard.visible;
  let dirty = true;
  let timer;
  const refreshSoon = (delay = 600) => {
    if (!isWatched()) {
      dirty = true;
      return;
    }
    clearTimeout(timer);
    timer = setTimeout(() => {
      dirty = false;
      store.refresh();
    }, delay);
  };
  const catchUp = () => {
    if (dirty && isWatched()) refreshSoon(0);
  };

  let watcher;
  try {
    watcher = fs.watch(ROOT, { recursive: true }, (_event, file) => {
      // Only <project>/<session>.jsonl, not the subfolders (subagents, tool results).
      if (!file || !file.endsWith('.jsonl') || file.split(path.sep).length !== 2) return;
      refreshSoon();
    });
    watcher.on('error', () => {});
  } catch {
    // Folder does not exist yet – manual refresh still works.
  }

  // Redraw every minute so relative times and activity stay accurate.
  const minuteTick = setInterval(() => {
    if (view.visible) tree.redraw();
  }, 60 * 1000);

  // The dashboard should be easy to find: it opens together with the sidebar view
  // and is always one click away in the status bar.
  const autoOpen = view.onDidChangeVisibility((event) => {
    if (event.visible) dashboard.show();
  });
  const statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
  statusItem.text = '$(layout) Claude Dashboard';
  statusItem.tooltip = T.statusTooltip;
  statusItem.command = 'claudeDashboard.open';
  statusItem.show();
  context.subscriptions.push(autoOpen, statusItem);

  const findProject = (dir) => store.projects.find((p) => p.dir === dir);

  const openProject = async (project) => {
    if (!project || !project.path) return;
    if (project.missing) {
      vscode.window.showWarningMessage(T.folderMissing(project.path));
      return;
    }
    if (ownsFolder(project.path)) {
      vscode.window.setStatusBarMessage(T.thisWindow(project.name), 3000);
      return;
    }
    // If the folder is already open in a window, VS Code focuses that window.
    await vscode.commands.executeCommand('vscode.openFolder', vscode.Uri.file(project.path), {
      forceNewWindow: true,
    });
  };

  const openSession = async (project, sessionId) => {
    if (!project || !project.path || !sessionId) return;
    if (project.missing) {
      vscode.window.showWarningMessage(T.folderMissing(project.path));
      return;
    }
    if (ownsFolder(project.path)) {
      await opener.openHere(sessionId);
      return;
    }
    // The session has to open in the project's own window: leave a request,
    // then bring that window to the front. The instance there picks it up.
    await opener.request(project.path, sessionId);
    await openProject(project);
  };

  dashboard.onMessage = (message) => {
    if (message.type === 'openProject') openProject(findProject(message.dir));
    else if (message.type === 'openSession') openSession(findProject(message.dir), message.id);
    else if (message.type === 'setColor') prefs.setColor(message.dir, message.color);
    else if (message.type === 'setArchived') prefs.setArchived(message.dir, !!message.value);
  };

  context.subscriptions.push(
    view,
    opener,
    prefs,
    { dispose: () => watcher && watcher.close() },
    { dispose: () => clearInterval(minuteTick) },
    { dispose: () => clearTimeout(timer) },
    view.onDidChangeVisibility(catchUp),
    dashboard.onDidChangeVisibility(catchUp),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration('claudeDashboard')) store.refresh();
    }),
    vscode.commands.registerCommand('claudeDashboard.open', () => dashboard.show()),
    vscode.commands.registerCommand('claudeDashboard.refresh', () => store.refresh()),
    vscode.commands.registerCommand('claudeDashboard.openProject', (node) =>
      openProject(node && node.project)
    ),
    vscode.commands.registerCommand('claudeDashboard.archiveProject', (node) => {
      if (node && node.project) prefs.setArchived(node.project.dir, true);
    }),
    vscode.commands.registerCommand('claudeDashboard.openSession', (node) =>
      openSession(node && node.project, node && node.session && node.session.id)
    ),
    vscode.window.registerWebviewPanelSerializer(PANEL_TYPE, {
      deserializeWebviewPanel: async (panel) => dashboard.attach(panel),
    })
  );

  prefs.start();
  opener.start();
}

function deactivate() {}

function ownsFolder(folder) {
  return (vscode.workspace.workspaceFolders || []).some((f) => f.uri.fsPath === folder);
}

// ---------------------------------------------------------------------------
// User preferences (colors, archive)
//
// Stored as a small file in the extension's global storage so that every
// VS Code window sees the same state. Keyed by the project's folder name
// under ~/.claude/projects.

class Prefs {
  constructor(context) {
    this.dir = context.globalStorageUri.fsPath;
    this.file = path.join(this.dir, 'prefs.json');
    this.data = { colors: {}, archived: [] };
    this.raw = '';
    this.watcher = null;
    this.emitter = new vscode.EventEmitter();
    this.onDidChange = this.emitter.event;
  }

  start() {
    this.load();
    try {
      fs.mkdirSync(this.dir, { recursive: true });
      this.watcher = fs.watch(this.dir, (_event, file) => {
        if (!file || file === path.basename(this.file)) this.load();
      });
      this.watcher.on('error', () => {});
    } catch {
      // Changes from other windows then apply after a reload.
    }
  }

  dispose() {
    if (this.watcher) this.watcher.close();
  }

  load() {
    let raw;
    try {
      raw = fs.readFileSync(this.file, 'utf8');
    } catch {
      return;
    }
    if (raw === this.raw) return;
    try {
      const parsed = JSON.parse(raw);
      this.data = {
        colors: parsed && typeof parsed.colors === 'object' && parsed.colors ? parsed.colors : {},
        archived: parsed && Array.isArray(parsed.archived) ? parsed.archived : [],
      };
      this.raw = raw;
      this.emitter.fire();
    } catch {
      // Half-written file – the next event reads it completely.
    }
  }

  save() {
    this.raw = JSON.stringify(this.data, null, 2);
    try {
      fs.mkdirSync(this.dir, { recursive: true });
      fs.writeFileSync(this.file, this.raw, 'utf8');
    } catch {
      // Then the change only lasts until restart.
    }
    this.emitter.fire();
  }

  color(dir) {
    const value = this.data.colors[dir];
    return Number.isInteger(value) ? value : null;
  }

  isArchived(dir) {
    return this.data.archived.includes(dir);
  }

  setColor(dir, color) {
    if (typeof dir !== 'string' || !Number.isInteger(color) || color < 0 || color > 31) return;
    this.data.colors[dir] = color;
    this.save();
  }

  setArchived(dir, value) {
    if (typeof dir !== 'string') return;
    const without = this.data.archived.filter((d) => d !== dir);
    this.data.archived = value ? [...without, dir] : without;
    this.save();
  }
}

// ---------------------------------------------------------------------------
// Data

class Store {
  constructor() {
    this.projects = [];
    this.loaded = false;
    this.cache = new Map();
    this.emitter = new vscode.EventEmitter();
    this.onDidChange = this.emitter.event;
    this.running = null;
    this.again = false;
  }

  refresh() {
    if (this.running) {
      this.again = true;
      return this.running;
    }
    this.running = (async () => {
      do {
        this.again = false;
        const all = await scanProjects(ROOT, this.cache);
        const showMissing = vscode.workspace
          .getConfiguration('claudeDashboard')
          .get('showMissingFolders', false);
        this.projects = showMissing ? all : all.filter((p) => !p.missing);
        this.loaded = true;
        this.emitter.fire();
      } while (this.again);
    })().finally(() => {
      this.running = null;
    });
    return this.running;
  }
}

// ---------------------------------------------------------------------------
// Sidebar

class ProjectTree {
  constructor(store, prefs) {
    this.store = store;
    this.prefs = prefs;
    this.emitter = new vscode.EventEmitter();
    this.onDidChangeTreeData = this.emitter.event;
    store.onDidChange(() => this.redraw());
  }

  redraw() {
    this.emitter.fire();
  }

  async getChildren(node) {
    if (!node) {
      if (!this.store.loaded) await this.store.refresh();
      return this.store.projects
        .filter((project) => !this.prefs.isArchived(project.dir))
        .map((project) => ({ project }));
    }
    if (node.session) return [];
    return node.project.sessions
      .slice(0, TREE_SESSION_LIMIT)
      .map((session) => ({ project: node.project, session }));
  }

  getTreeItem(node) {
    const { project, session } = node;
    if (!session) {
      const current = project.path && ownsFolder(project.path);
      const item = new vscode.TreeItem(
        project.name,
        current
          ? vscode.TreeItemCollapsibleState.Expanded
          : vscode.TreeItemCollapsibleState.Collapsed
      );
      item.id = project.dir;
      item.description = relTime(project.lastTs);
      item.tooltip = project.path || project.dir;
      item.contextValue = 'project';
      const active = project.sessions.some((s) => isActive(s));
      item.iconPath = active
        ? new vscode.ThemeIcon('folder-active', new vscode.ThemeColor('charts.green'))
        : new vscode.ThemeIcon(current ? 'folder-opened' : 'folder');
      return item;
    }
    const title = session.title || T.untitled;
    const item = new vscode.TreeItem(title, vscode.TreeItemCollapsibleState.None);
    item.id = `${project.dir}/${session.id}`;
    item.description = relTime(session.lastTs);
    item.tooltip = session.excerpt ? `${title}\n\n${session.excerpt}` : title;
    item.contextValue = 'session';
    item.iconPath = isActive(session)
      ? new vscode.ThemeIcon('circle-filled', new vscode.ThemeColor('charts.green'))
      : new vscode.ThemeIcon('comment');
    item.command = {
      command: 'claudeDashboard.openSession',
      title: T.openSession,
      arguments: [node],
    };
    return item;
  }
}

// ---------------------------------------------------------------------------
// Dashboard (editor tab)

class Dashboard {
  constructor(context, store, prefs) {
    this.context = context;
    this.store = store;
    this.prefs = prefs;
    this.panel = null;
    this.onMessage = () => {};
    this.visibility = new vscode.EventEmitter();
    this.onDidChangeVisibility = this.visibility.event;
    store.onDidChange(() => this.post());
  }

  get visible() {
    return !!this.panel && this.panel.visible;
  }

  get mediaRoot() {
    return vscode.Uri.joinPath(this.context.extensionUri, 'media');
  }

  show() {
    if (this.panel) {
      this.panel.reveal();
      return;
    }
    const panel = vscode.window.createWebviewPanel(
      PANEL_TYPE,
      'Claude Dashboard',
      vscode.ViewColumn.Active,
      { enableScripts: true, localResourceRoots: [this.mediaRoot] }
    );
    this.attach(panel);
  }

  attach(panel) {
    this.panel = panel;
    panel.iconPath = vscode.Uri.joinPath(this.mediaRoot, 'tab.svg');
    panel.webview.options = { enableScripts: true, localResourceRoots: [this.mediaRoot] };
    panel.webview.onDidReceiveMessage((message) => {
      if (!message || typeof message.type !== 'string') return;
      if (message.type === 'ready') {
        if (this.store.loaded) this.post();
        this.store.refresh();
      } else {
        this.onMessage(message);
      }
    });
    panel.onDidChangeViewState(() => this.visibility.fire());
    panel.onDidDispose(() => {
      this.panel = null;
      this.visibility.fire();
    });
    panel.webview.html = this.html(panel.webview);
    this.visibility.fire();
  }

  post() {
    if (!this.panel || !this.store.loaded) return;
    const home = os.homedir();
    this.panel.webview.postMessage({
      type: 'data',
      lang: LANG,
      projects: this.store.projects.map((p) => ({
        dir: p.dir,
        name: p.name,
        path: p.path && p.path.startsWith(home) ? '~' + p.path.slice(home.length) : p.path,
        missing: p.missing,
        color: this.prefs.color(p.dir),
        archived: this.prefs.isArchived(p.dir),
        current: !!p.path && ownsFolder(p.path),
        lastTs: p.lastTs,
        sessions: p.sessions.map((s) => ({
          id: s.id,
          title: s.title,
          excerpt: s.excerpt,
          lastTs: s.lastTs,
          openTurn: s.openTurn,
        })),
      })),
    });
  }

  html(webview) {
    const nonce = crypto.randomBytes(16).toString('base64');
    const css = webview.asWebviewUri(vscode.Uri.joinPath(this.mediaRoot, 'dashboard.css'));
    const js = webview.asWebviewUri(vscode.Uri.joinPath(this.mediaRoot, 'dashboard.js'));
    // Strict Content Security Policy: only our own local files, no network.
    const csp = [
      "default-src 'none'",
      `style-src ${webview.cspSource}`,
      `script-src 'nonce-${nonce}'`,
    ].join('; ');
    return `<!DOCTYPE html>
<html lang="${LANG}">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="${css}">
<title>Claude Dashboard</title>
</head>
<body>
<div id="app"></div>
<script nonce="${nonce}" src="${js}"></script>
</body>
</html>`;
  }
}

// ---------------------------------------------------------------------------
// Open a session in the right window
//
// One window cannot reach into another. So the dashboard drops a small request
// file; every instance of this extension watches it, and the instance whose
// workspace folder matches opens the session itself.

class SessionOpener {
  constructor(context) {
    this.dir = context.globalStorageUri.fsPath;
    this.file = path.join(this.dir, 'open-request.json');
    this.watcher = null;
  }

  start() {
    try {
      fs.mkdirSync(this.dir, { recursive: true });
      this.watcher = fs.watch(this.dir, (_event, file) => {
        if (!file || file === path.basename(this.file)) this.check();
      });
      this.watcher.on('error', () => {});
    } catch {
      // Without a watcher, "Open window" still works.
    }
    // Was this window just opened for a pending request?
    this.check();
  }

  dispose() {
    if (this.watcher) this.watcher.close();
  }

  async request(folder, sessionId) {
    const payload = JSON.stringify({ folder, sessionId, ts: Date.now() });
    try {
      await fs.promises.mkdir(this.dir, { recursive: true });
      await fs.promises.writeFile(this.file, payload, 'utf8');
    } catch {
      // Then only the window opens, without the session.
    }
  }

  async check() {
    let request;
    try {
      request = JSON.parse(await fs.promises.readFile(this.file, 'utf8'));
    } catch {
      return;
    }
    if (!request || typeof request.folder !== 'string' || typeof request.sessionId !== 'string') return;
    if (Date.now() - request.ts > REQUEST_MAX_AGE_MS) return;
    if (!ownsFolder(request.folder)) return;
    try {
      // Whoever deletes the file owns the request, so only one window opens it.
      await fs.promises.unlink(this.file);
    } catch {
      return;
    }
    await this.openHere(request.sessionId);
  }

  async openHere(sessionId) {
    if (!/^[0-9a-f-]{8,64}$/i.test(sessionId)) return;
    // In a freshly opened window Claude Code may not be ready yet.
    for (let attempt = 0; attempt < 30; attempt++) {
      const commands = await vscode.commands.getCommands(true);
      if (commands.includes(CLAUDE_OPEN_COMMAND)) {
        try {
          await vscode.commands.executeCommand(CLAUDE_OPEN_COMMAND, sessionId);
        } catch (error) {
          vscode.window.showWarningMessage(
            T.openFailed(error && error.message ? error.message : String(error))
          );
        }
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    vscode.window.showWarningMessage(T.claudeInactive);
  }
}

module.exports = { activate, deactivate };
