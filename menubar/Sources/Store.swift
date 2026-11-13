// Data for the menu bar app: projects, preferences shared with the VS Code
// extension, status, and the file watcher. No network access anywhere.

import Combine
import Foundation
import SwiftUI

enum Paths {
  static let home = NSHomeDirectory()
  static let sessions = home + "/.claude/projects"
  /// Global storage of the VS Code extension (prefs.json, open-request.json).
  static let extensionStorage =
    home + "/Library/Application Support/Code/User/globalStorage/local.claude-dashboard"
}

// Derived from the session files, so it is an estimate:
//   working – Claude is mid-turn and wrote something just now
//   waiting – the turn is open but nothing has happened for a while (question, permission)
//   done    – Claude finished its turn
enum Status: Int {
  case working, waiting, done

  var color: Color {
    switch self {
    case .working: return Color(red: 0.25, green: 0.73, blue: 0.36)
    case .waiting: return Color(red: 0.90, green: 0.60, blue: 0.16)
    case .done: return .secondary
    }
  }
}

let workingMs = 3.0 * 60 * 1000  // open turn, last write less than 3 min ago
let recentMs = 12.0 * 60 * 60 * 1000  // "recent" = last 12 hours

func status(_ session: Session, _ now: Double) -> Status {
  if !session.openTurn { return .done }
  return now - session.lastTs < workingMs ? .working : .waiting
}

// Colors and archive are set in the VS Code dashboard; the app only reads them.
struct Prefs: Equatable {
  var colors: [String: Int] = [:]
  var archived: Set<String> = []

  static func load() -> Prefs {
    var prefs = Prefs()
    guard let data = FileManager.default.contents(atPath: Paths.extensionStorage + "/prefs.json"),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return prefs }
    if let colors = json["colors"] as? [String: Any] {
      for (dir, value) in colors {
        if let index = value as? Int, index >= 0 { prefs.colors[dir] = index }
      }
    }
    if let archived = json["archived"] as? [String] { prefs.archived = Set(archived) }
    return prefs
  }

  /// Changes the extension's prefs.json, so the VS Code dashboard shows the
  /// same colors and archive. Everything else in the file is kept.
  private static func update(_ change: (inout [String: Any]) -> Void) {
    let dir = Paths.extensionStorage
    let file = dir + "/prefs.json"
    var json: [String: Any] = [:]
    if let data = FileManager.default.contents(atPath: file) {
      // Never overwrite a file we cannot read.
      guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
      json = parsed
    }
    if json["colors"] == nil { json["colors"] = [String: Any]() }
    if json["archived"] == nil { json["archived"] = [String]() }
    change(&json)
    guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
  }

  static func saveArchived(_ archived: Set<String>) {
    update { json in
      let before = json["archived"] as? [String] ?? []
      let kept = before.filter(archived.contains)
      json["archived"] = kept + archived.subtracting(kept).sorted()
    }
  }

  static func saveColor(_ dir: String, _ index: Int) {
    update { json in
      var colors = json["colors"] as? [String: Any] ?? [:]
      colors[dir] = index
      json["colors"] = colors
    }
  }
}

// Same palette and fallback hash as media/dashboard.js, so colors match. Keep
// both in sync, and only ever add colors at the end: a project's color is
// stored as its position in this list.
let palette: [Color] = [
  0xd97757, 0xd9a441, 0x7fb069, 0x45a89f, 0x4f9be0, 0x8a7fe0, 0xcf6fae, 0x8b95a1,
  0xd65c5c, 0xe08a3c, 0xb5c24a, 0x5fb878, 0x4cb38a, 0x3aa3c4, 0x6c78e0, 0xa56fe0,
  0xc964d6, 0xe0668f, 0xb5836a, 0x9a8f7a, 0x6f8f8a, 0x5f6b7a, 0xa9b0ba, 0xb89f5a,
].map { hex in
  Color(
    red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
    blue: Double(hex & 0xff) / 255)
}
/// Projects without a chosen color get one of the first eight, by name.
private let defaultColors: UInt32 = 8

/// Position in `palette`: the chosen color, otherwise one derived from the name.
func projectColorIndex(_ project: Project, _ prefs: Prefs) -> Int {
  if let index = prefs.colors[project.dir] { return index % palette.count }
  var hash: UInt32 = 0
  for unit in project.dir.utf16 { hash = hash &* 31 &+ UInt32(unit) }
  return Int(hash % defaultColors)
}

func projectColor(_ project: Project, _ prefs: Prefs) -> Color {
  palette[projectColorIndex(project, prefs)]
}

final class Store: ObservableObject {
  @Published private(set) var projects: [Project] = []
  @Published private(set) var prefs = Prefs()
  @Published private(set) var loaded = false
  @Published private(set) var now = Date().timeIntervalSince1970 * 1000

  private let scanner = SessionScanner()
  private let queue = DispatchQueue(label: "claude-dashboard.scan", qos: .utility)
  private var watcher: FolderWatcher?
  private var debounce: DispatchWorkItem?
  private var timer: Timer?
  private var running = false
  private var again = false
  private let demo: Bool

  init() {
    demo = false
  }

  /// Fixed content for the layout preview (`--preview`), nothing is read from disk.
  init(demo projects: [Project], now: Double) {
    self.projects = projects
    self.now = now
    latestProjects = projects
    demo = true
    loaded = true
  }

  /// Archiving hides a project from the overview; it deletes nothing.
  func setArchived(_ dir: String, _ value: Bool) {
    if value { prefs.archived.insert(dir) } else { prefs.archived.remove(dir) }
    latestPrefs = prefs
    if !demo { Prefs.saveArchived(prefs.archived) }
    updateBadge()
  }

  /// The color is shared with the VS Code dashboard.
  func setColor(_ dir: String, _ index: Int) {
    prefs.colors[dir] = index
    latestPrefs = prefs
    if !demo { Prefs.saveColor(dir, index) }
  }

  var visibleProjects: [Project] { projects.filter { !prefs.archived.contains($0.dir) } }
  var archivedProjects: [Project] { projects.filter { prefs.archived.contains($0.dir) } }

  var workingCount: Int {
    visibleProjects.reduce(0) { sum, project in
      sum + project.sessions.filter { status($0, now) == .working }.count
    }
  }

  // What the last scan found. The published copies above (which the views
  // watch) are only brought up to date while the panel is open, so a closed
  // panel causes no drawing work at all.
  private var latestProjects: [Project] = []
  private var latestPrefs = Prefs()

  /// Called with the number of working sessions whenever it changes; this is
  /// the number next to the menu bar icon.
  var onBadge: ((Int) -> Void)?
  private var badge = -1

  /// True while the panel is open. While it is closed, only the number next to
  /// the menu bar icon matters, so the app looks at the files far less often.
  var foreground = false {
    didSet { if foreground { publish() } }
  }

  func start() {
    refresh()
    watcher = FolderWatcher(root: Paths.sessions) { [weak self] in self?.refreshSoon() }
    // Status and relative times change with time alone. The tolerance lets
    // macOS run this together with other timers instead of waking up for it.
    let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
    timer.tolerance = 10
    self.timer = timer
  }

  private func tick() {
    if foreground { touch() }
    // A working session turns into a waiting one by time alone.
    if badge > 0 { updateBadge() }
  }

  private func publish() {
    if latestProjects != projects { projects = latestProjects }
    if latestPrefs != prefs { prefs = latestPrefs }
    if !loaded { loaded = true }
    touch()
  }

  private func updateBadge() {
    let now = Date().timeIntervalSince1970 * 1000
    var count = 0
    for project in latestProjects where !latestPrefs.archived.contains(project.dir) {
      for session in project.sessions where status(session, now) == .working { count += 1 }
    }
    guard count != badge else { return }
    badge = count
    onBadge?(count)
  }

  func touch() {
    now = Date().timeIntervalSince1970 * 1000
  }

  /// Sessions that are working write to their file all the time. Collect those
  /// changes and look once: quickly while the panel is open, rarely otherwise.
  private func refreshSoon() {
    guard debounce == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      self?.debounce = nil
      self?.refresh()
    }
    debounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + (foreground ? 0.8 : 5), execute: work)
  }

  func refresh() {
    if running {
      again = true
      return
    }
    running = true
    queue.async { [scanner] in
      // Folders that no longer exist are hidden, like in the extension's default.
      let projects = scanner.scan(root: Paths.sessions).filter { !$0.missing }
      let prefs = Prefs.load()
      DispatchQueue.main.async {
        self.running = false
        self.latestProjects = projects
        self.latestPrefs = prefs
        if self.foreground || !self.loaded { self.publish() }
        self.updateBadge()
        if self.again {
          self.again = false
          self.refresh()
        }
      }
    }
  }
}

/// Watches ~/.claude/projects for changed session files (FSEvents, local only).
final class FolderWatcher {
  private var stream: FSEventStreamRef?
  private let root: String
  private let onChange: () -> Void

  init(root: String, onChange: @escaping () -> Void) {
    self.root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    self.onChange = onChange

    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
      let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
      watcher.handle(list)
    }
    let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, [self.root] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
    else { return }
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
    FSEventStreamStart(stream)
    self.stream = stream
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }

  private func handle(_ paths: [String]) {
    // Only <project>/<session>.jsonl, not the subfolders (subagents, tool results).
    let relevant = paths.contains { path in
      guard path.hasSuffix(".jsonl"), path.hasPrefix(root + "/") else { return false }
      return path.dropFirst(root.count + 1).split(separator: "/").count == 2
    }
    if relevant { onChange() }
  }
}
