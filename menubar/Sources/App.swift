// Claude Dashboard for the macOS menu bar.
// Shows all Claude Code sessions across all projects and jumps into the right
// VS Code window. Reads ~/.claude/projects locally only. No network access.
//
// Extra modes for development:
//   --check [text]   scan and print counts; details only for project folders
//                    whose name contains <text>
//   --demo           run with made-up data instead of the real sessions
//   --show           open the panels right away, print where they are, write
//                    panel-main.png and panel-detail.png into the current
//                    folder, and quit

import AppKit
import Combine
import SwiftUI

@main
enum Main {
  private static var delegate: AppDelegate?

  static func main() {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--check") {
      check(filter: args.count > index + 1 ? args[index + 1] : nil)
      return
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(demo: args.contains("--demo"), showAtLaunch: args.contains("--show"))
    self.delegate = delegate
    app.delegate = delegate
    app.run()
  }
}

/// A borderless panel that can still take the keyboard (for the search field).
private final class Panel: NSPanel {
  override var canBecomeKey: Bool { true }
}

private func makePanel<Content: View>(_ root: Content) -> Panel {
  let panel = Panel(
    contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  panel.isOpaque = false
  panel.backgroundColor = .clear
  panel.hasShadow = true
  panel.level = .popUpMenu
  panel.hidesOnDeactivate = false
  panel.isMovable = false
  panel.animationBehavior = .none
  panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

  let effect = NSVisualEffectView()
  effect.material = .popover
  effect.blendingMode = .behindWindow
  effect.state = .active
  effect.wantsLayer = true
  effect.layer?.cornerRadius = 14
  effect.layer?.cornerCurve = .continuous
  effect.layer?.masksToBounds = true

  let host = NSHostingView(rootView: root)
  host.sizingOptions = []  // the panel decides the size, see PanelController
  host.translatesAutoresizingMaskIntoConstraints = false
  effect.addSubview(host)
  NSLayoutConstraint.activate([
    host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
    host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
    host.topAnchor.constraint(equalTo: effect.topAnchor),
    host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
  ])
  panel.contentView = effect
  return panel
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let store: Store
  private let selection = Selection()
  private let showAtLaunch: Bool
  private var statusItem: NSStatusItem!
  private var mainPanel: Panel!
  private var detailPanel: Panel!
  private var mainHeight: CGFloat = 420
  private var detailHeight: CGFloat = 300
  private var monitors: [Any] = []
  private var subscriptions = Set<AnyCancellable>()

  // Distance between the panels and to the menu bar and screen edges.
  private let gap: CGFloat = 8

  init(demo: Bool, showAtLaunch: Bool) {
    let now = Date().timeIntervalSince1970 * 1000
    store = demo ? Store(demo: demoProjects(now: now), now: now) : Store()
    self.showAtLaunch = showAtLaunch
    self.demo = demo
  }
  private let demo: Bool

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Claude Dashboard")
      image?.isTemplate = true
      button.image = image
      button.imagePosition = .imageLeading
      button.toolTip = Strings.current.tooltip
      button.target = self
      button.action = #selector(toggle)
    }

    let actions = Actions(
      openProject: { [weak self] project in
        self?.close()
        if !Opener.openProject(project) { self?.codeMissing() }
      },
      openSession: { [weak self] project, session in
        self?.close()
        if !Opener.openSession(project, session) { self?.codeMissing() }
      },
      select: { [weak self] project in self?.select(project.dir) },
      quit: { NSApp.terminate(nil) })

    mainPanel = makePanel(
      MainView(store: store, selection: selection, actions: actions) { [weak self] height in
        // Not during SwiftUI's layout pass, or the panel's content keeps a stale size.
        DispatchQueue.main.async {
          self?.mainHeight = height
          self?.layout()
        }
      })
    detailPanel = makePanel(
      DetailView(store: store, selection: selection, actions: actions) { [weak self] height in
        // Not during SwiftUI's layout pass, or the panel's content keeps a stale size.
        DispatchQueue.main.async {
          self?.detailHeight = height
          self?.layout()
        }
      })

    // The number of working sessions sits next to the icon.
    store.$projects.combineLatest(store.$now, store.$prefs)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.updateTitle() }
      .store(in: &subscriptions)

    if !demo { store.start() }
    if showAtLaunch {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
        open()
        if let first = store.visibleProjects.first { select(first.dir) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in printFrames() }
      }
    }
  }

  private func updateTitle() {
    let working = store.workingCount
    statusItem.button?.title = working > 0 ? " \(working)" : ""
  }

  // MARK: Showing and hiding

  @objc private func toggle() {
    if mainPanel.isVisible { close() } else { open() }
  }

  private func open() {
    if !demo { store.refresh() }
    layout()
    // The self-test (--show) must not take the keyboard away from the user.
    if showAtLaunch { mainPanel.orderFrontRegardless() } else { mainPanel.makeKeyAndOrderFront(nil) }

    // A click anywhere else or Escape closes the panels.
    if let monitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in self?.close() })
    {
      monitors.append(monitor)
    }
    if let monitor = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown,
      handler: { [weak self] event in
        guard event.keyCode == 53 else { return event }
        self?.close()
        return nil
      })
    {
      monitors.append(monitor)
    }
  }

  private func close() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    hideDetail()
    mainPanel.orderOut(nil)
  }

  /// Clicking a tile opens that project's sessions next to the main panel;
  /// clicking it again closes them.
  private func select(_ dir: String) {
    if selection.dir == dir {
      hideDetail()
      return
    }
    selection.dir = dir
    layout()
    if detailPanel.parent == nil { mainPanel.addChildWindow(detailPanel, ordered: .above) }
    detailPanel.orderFront(nil)
  }

  private func hideDetail() {
    selection.dir = nil
    if detailPanel.parent != nil { mainPanel.removeChildWindow(detailPanel) }
    detailPanel.orderOut(nil)
  }

  // MARK: Placement

  /// The panels hang below the menu bar with a small gap, like Control Center,
  /// and are only as tall as their content.
  private func layout() {
    guard let button = statusItem.button, let anchor = button.window,
      let screen = anchor.screen ?? NSScreen.main
    else { return }
    let area = screen.visibleFrame
    // With an auto-hidden menu bar the visible area reaches the top of the
    // screen, so also stay below the menu bar item itself.
    let top = min(area.maxY, anchor.frame.minY) - gap
    let maxHeight = top - area.minY - gap

    let mainSize = NSSize(width: Layout.mainWidth, height: min(mainHeight, maxHeight))
    var x = anchor.frame.midX - mainSize.width / 2
    x = max(area.minX + gap, min(x, area.maxX - gap - mainSize.width))
    let mainFrame = NSRect(x: x, y: top - mainSize.height, width: mainSize.width, height: mainSize.height)
    setFrame(mainPanel, mainFrame)

    let detailSize = NSSize(width: Layout.detailWidth, height: min(detailHeight, maxHeight))
    // To the left of the main panel; to the right if there is no room.
    var detailX = mainFrame.minX - gap - detailSize.width
    if detailX < area.minX + gap { detailX = mainFrame.maxX + gap }
    setFrame(
      detailPanel,
      NSRect(x: detailX, y: top - detailSize.height, width: detailSize.width, height: detailSize.height))
  }

  private func setFrame(_ panel: NSPanel, _ frame: NSRect) {
    guard panel.frame != frame else { return }
    panel.setFrame(frame, display: true)
    panel.invalidateShadow()
  }

  /// For `--show`: where the panels ended up, and a picture of each one next to
  /// the executable's working directory (drawn by the app itself, so it needs
  /// no screen recording permission; the blurred background is not included).
  private func printFrames() {
    guard let button = statusItem.button, let anchor = button.window, let screen = anchor.screen else { return }
    print("screen \(screen.frame) visible \(screen.visibleFrame)")
    print("menu bar item \(anchor.frame)")
    print("main \(mainPanel.frame) visible \(mainPanel.isVisible)")
    print("detail \(detailPanel.frame) visible \(detailPanel.isVisible)")
    print("gap below menu bar: \(min(screen.visibleFrame.maxY, anchor.frame.minY) - mainPanel.frame.maxY)")
    fflush(stdout)
    snapshot(mainPanel, "panel-main.png")
    snapshot(detailPanel, "panel-detail.png")
    NSApp.terminate(nil)
  }

  private func snapshot(_ panel: NSPanel, _ name: String) {
    guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = NSImage(size: view.bounds.size)
    image.lockFocus()
    panel.effectiveAppearance.performAsCurrentDrawingAppearance {
      NSColor.windowBackgroundColor.setFill()
    }
    NSRect(origin: .zero, size: view.bounds.size).fill()
    rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff),
      let data = out.representation(using: .png, properties: [:])
    else { return }
    try? data.write(to: URL(fileURLWithPath: name))
  }

  private func codeMissing() {
    let alert = NSAlert()
    alert.messageText = Strings.current.codeMissing
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}

// MARK: Development modes

private func check(filter: String?) {
  let started = Date()
  let projects = SessionScanner().scan(root: Paths.sessions)
  let seconds = Date().timeIntervalSince(started)
  let now = Date().timeIntervalSince1970 * 1000
  let sessions = projects.flatMap(\.sessions)
  func count(_ kind: Status) -> Int { sessions.filter { status($0, now) == kind }.count }
  print("projects: \(projects.count) (folder missing: \(projects.filter(\.missing).count))")
  print("sessions: \(sessions.count), without title: \(sessions.filter { $0.title.isEmpty }.count),"
    + " without excerpt: \(sessions.filter { $0.excerpt.isEmpty }.count)")
  print("working: \(count(.working)), waiting: \(count(.waiting)), done: \(count(.done))")
  print(String(format: "scan: %.2f s", seconds))
  guard let filter else { return }
  let t = Strings.current
  for project in projects where project.dir.localizedCaseInsensitiveContains(filter) {
    print("\n\(project.name)  [\(project.path ?? "?")]")
    for session in project.sessions {
      print("  \(t.status(status(session, now))) · \(t.relTime(session.lastTs, now: now)) · \(session.title)")
      print("    \(session.excerpt.prefix(120))")
    }
  }
}

private func demoProjects(now: Double) -> [Project] {
  func session(_ id: String, _ title: String, _ excerpt: String, minutes: Double, open: Bool = false) -> Session {
    Session(id: id, cwd: nil, title: title, excerpt: excerpt, lastTs: now - minutes * 60000, openTurn: open)
  }
  func project(_ name: String, _ sessions: [Session]) -> Project {
    Project(dir: "-demo-" + name, path: "/demo/" + name, name: name, missing: false,
      lastTs: sessions[0].lastTs, sessions: sessions)
  }
  return [
    project("weather-station", [
      session("a1", "Add humidity sensor to the dashboard", "The chart now shows both series.", minutes: 1, open: true),
      session("a2", "Fix time zone in the export", "Should the export use local time or UTC?", minutes: 25, open: true),
      session("a3", "Write the README", "The README covers setup, usage and removal.", minutes: 300),
      session("a4", "Set up the project", "Done. The folder structure is in place.", minutes: 3000),
    ]),
    project("recipe-book", [
      session("b1", "Import recipes from a text file with a very long title that gets cut", "All 42 recipes were imported.", minutes: 90),
      session("b2", "", "", minutes: 1500),
    ]),
    project("garden-plan", [
      session("c1", "Draw the bed layout", "The plan is saved as plan.svg.", minutes: 60 * 24 * 3),
    ]),
    project("a-project-with-a-rather-long-name", [
      session("d1", "Compare the two offers", "Which of the two should I look at first?", minutes: 200, open: true),
      session("d2", "Collect the documents", "All documents are in the folder.", minutes: 60 * 24 * 9),
    ]),
    project("home-budget", [
      session("e1", "Monthly overview", "The overview for October is ready.", minutes: 60 * 24 * 30),
    ]),
  ]
}
