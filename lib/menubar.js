// The macOS menu bar app ships inside the extension (folder menubar-app).
// One command copies it to the Applications folder and starts it; later
// versions of the extension offer to update it. Local copies only, no download.

'use strict';

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

const APP_NAME = 'Claude Dashboard.app';
const EXECUTABLE = 'ClaudeDashboard';
const HINT_KEY = 'menubar.hintShown';
const UPDATE_KEY = 'menubar.updateOffered';

function run(file, args) {
  return new Promise((resolve, reject) =>
    execFile(file, args, (error, _stdout, stderr) => (error ? reject(new Error(stderr || error.message)) : resolve()))
  );
}

function appVersion(app) {
  try {
    const plist = fs.readFileSync(path.join(app, 'Contents', 'Info.plist'), 'utf8');
    const match = plist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]*)<\/string>/);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

function newer(a, b) {
  const pa = String(a).split('.').map(Number);
  const pb = String(b).split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d > 0;
  }
  return false;
}

function writable(dir) {
  try {
    fs.accessSync(dir, fs.constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

class MenubarApp {
  constructor(context, T) {
    this.context = context;
    this.T = T;
    this.source = path.join(context.extensionPath, 'menubar-app', APP_NAME);
    this.candidates = [path.join('/Applications', APP_NAME), path.join(os.homedir(), 'Applications', APP_NAME)];
  }

  get available() {
    return process.platform === 'darwin' && fs.existsSync(this.source);
  }

  installed() {
    return this.candidates.find((app) => fs.existsSync(app)) || null;
  }

  /// Where a new copy goes: /Applications if we may write there, else ~/Applications.
  target() {
    return this.installed() || (writable('/Applications') ? this.candidates[0] : this.candidates[1]);
  }

  /// Once per installation: mention the app; later, offer each newer version once.
  async greet() {
    if (!this.available || this.greeted) return;
    this.greeted = true;
    const state = this.context.globalState;
    const bundled = appVersion(this.source);
    const installed = this.installed();
    if (!installed) {
      if (state.get(HINT_KEY)) return;
      await state.update(HINT_KEY, true);
      const choice = await vscode.window.showInformationMessage(this.T.menubarHint, this.T.menubarInstallButton);
      if (choice) this.install();
      return;
    }
    const current = appVersion(installed);
    if (!bundled || !current || !newer(bundled, current) || state.get(UPDATE_KEY) === bundled) return;
    await state.update(UPDATE_KEY, bundled);
    const choice = await vscode.window.showInformationMessage(
      this.T.menubarUpdateHint(bundled),
      this.T.menubarUpdateButton
    );
    if (choice) this.install(true);
  }

  async install(confirmed = false) {
    const T = this.T;
    if (!this.available) {
      vscode.window.showWarningMessage(T.menubarUnavailable);
      return;
    }
    const target = this.target();
    if (!confirmed) {
      const choice = await vscode.window.showInformationMessage(
        T.menubarConfirm(path.dirname(target)),
        { modal: true, detail: T.menubarConfirmDetail },
        T.menubarInstallButton
      );
      if (!choice) return;
    }
    try {
      // A running copy would keep the old version: quit it first. (A signal,
      // not an Apple event, so macOS does not ask for automation rights.)
      await run('/usr/bin/pkill', ['-x', EXECUTABLE]).catch(() => {});
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.rmSync(target, { recursive: true, force: true });
      await run('/usr/bin/ditto', [this.source, target]);
      await run('/usr/bin/open', [target]);
      vscode.window.showInformationMessage(T.menubarInstalled(path.dirname(target)));
    } catch (error) {
      vscode.window.showErrorMessage(T.menubarFailed(error.message));
    }
  }
}

module.exports = { MenubarApp };
