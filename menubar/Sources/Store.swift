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
}

// Same palette and fallback hash as media/dashboard.js, so colors match.
private let palette: [Color] = [
  0xd97757, 0xd9a441, 0x7fb069, 0x45a89f, 0x4f9be0, 0x8a7fe0, 0xcf6fae, 0x8b95a1,
].map { hex in
  Color(
    red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
    blue: Double(hex & 0xff) / 255)
}

func projectColor(_ project: Project, _ prefs: Prefs) -> Color {
  if let index = prefs.colors[project.dir] { return palette[index % palette.count] }
  var hash: UInt32 = 0
  for unit in project.dir.utf16 { hash = hash &* 31 &+ UInt32(unit) }
  return palette[Int(hash % UInt32(palette.count))]
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
  private var tick: Timer?
  private var running = false
  private var again = false

  init() {}

  /// Fixed content for the layout preview (`--preview`), nothing is read from disk.
  init(demo projects: [Project], now: Double) {
    self.projects = projects
    self.now = now
    loaded = true
  }

  var visibleProjects: [Project] { projects.filter { !prefs.archived.contains($0.dir) } }
  var archivedProjects: [Project] { projects.filter { prefs.archived.contains($0.dir) } }

  var workingCount: Int {
    visibleProjects.reduce(0) { sum, project in
      sum + project.sessions.filter { status($0, now) == .working }.count
    }
  }

  func start() {
    refresh()
    watcher = FolderWatcher(root: Paths.sessions) { [weak self] in self?.refreshSoon() }
    // Status and relative times change with time alone.
    tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.touch() }
  }

  func touch() {
    now = Date().timeIntervalSince1970 * 1000
  }

  private func refreshSoon() {
    debounce?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.refresh() }
    debounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
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
        if projects != self.projects { self.projects = projects }
        if prefs != self.prefs { self.prefs = prefs }
        if !self.loaded { self.loaded = true }
        self.touch()
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
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
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
