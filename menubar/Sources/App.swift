// Claude Dashboard for the macOS menu bar.
// Shows all Claude Code sessions across all projects and jumps into the right
// VS Code window. Reads ~/.claude/projects locally only. No network access.
//
// Extra modes for development:
//   --check [text]   scan and print counts; details only for project folders
//                    whose name contains <text>
//   --demo           run with made-up data instead of the real sessions
//   --columns <n>    with --demo: number of tile columns
//   --edit           with --demo: start in edit mode
//   --tall           with --demo: make two tiles large
//   --open           open the panels right away and keep running (real look)
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
    if delegate.demo {
      for (name, symbol) in [
        ("weather-station", "cloud.fill"), ("recipe-book", "book.fill"), ("garden-plan", "leaf.fill"),
        ("home-budget", "banknote.fill"),
      ] {
        delegate.settings.setIcon("-demo-" + name, symbol)
      }
      if let index = args.firstIndex(of: "--columns"), args.count > index + 1, let columns = Int(args[index + 1]),
        Settings.columnRange.contains(columns)
      {
        delegate.settings.columns = columns
      }
      if args.contains("--tall") {
        delegate.settings.toggleTall("-demo-weather-station")
        delegate.settings.toggleTall("-demo-garden-plan")
      }
      delegate.settings.editing = args.contains("--edit")
      if args.contains("--pick") { delegate.settings.pickingIcon = "-demo-weather-station" }
    }
    self.delegate = delegate
    app.delegate = delegate
    app.run()
  }
}

/// The menu bar icon: a small agent drawn in outlines only (an own design).
/// A template image, so macOS colors it for light and dark menu bars.
func agentIcon(scale: CGFloat = 1) -> NSImage {
  let image = NSImage(size: NSSize(width: 18 * scale, height: 18 * scale), flipped: false) { _ in
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    NSColor.black.setStroke()
    func stroke(_ path: NSBezierPath, _ width: CGFloat = 1.35) {
      path.lineWidth = width
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      path.stroke()
    }
    func line(_ from: NSPoint, _ to: NSPoint) -> NSBezierPath {
      let path = NSBezierPath()
      path.move(to: from)
      path.line(to: to)
      return path
    }
    // Body
    stroke(NSBezierPath(roundedRect: NSRect(x: 2.7, y: 4.6, width: 12.6, height: 8.2), xRadius: 2.6, yRadius: 2.6))
    // Antenna
    stroke(line(NSPoint(x: 9, y: 12.8), NSPoint(x: 9, y: 14.6)))
    stroke(NSBezierPath(ovalIn: NSRect(x: 8.05, y: 14.6, width: 1.9, height: 1.9)), 1.1)
    // Eyes
    stroke(line(NSPoint(x: 6.6, y: 7.9), NSPoint(x: 6.6, y: 9.7)), 1.5)
    stroke(line(NSPoint(x: 11.4, y: 7.9), NSPoint(x: 11.4, y: 9.7)), 1.5)
    // Legs
    stroke(line(NSPoint(x: 6, y: 4.6), NSPoint(x: 6, y: 2.4)))
    stroke(line(NSPoint(x: 12, y: 4.6), NSPoint(x: 12, y: 2.4)))
    return true
  }
  image.isTemplate = true
  image.accessibilityDescription = "Claude Dashboard"
  return image
}

// Blur of what lies behind a window, with a freely chosen strength – the way
// Control Center looks. macOS offers this only through two window server
// functions that are not part of the documented API (terminal apps have used
// them for many years). If a future macOS drops them, the panel still works,
// just without the soft blur.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func CGSSetWindowBackgroundBlurRadius(_ connection: Int32, _ window: Int32, _ radius: Int32) -> Int32

/// A borderless panel that can still take the keyboard (for the search field).
private final class Panel: NSPanel {
  override var canBecomeKey: Bool { true }
}

private func makePanel() -> Panel {
  let panel = Panel(
    contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  panel.isOpaque = false
  panel.backgroundColor = .clear
  panel.hasShadow = false
  panel.level = .popUpMenu
  panel.hidesOnDeactivate = false
  panel.isMovable = false
  panel.animationBehavior = .none
  panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
  return panel
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let store: Store
  private let selection = Selection()
  let settings: Settings
  private let sizes = PanelSizes()
  private let showAtLaunch: Bool
  private var statusItem: NSStatusItem!
  // Both parts (overview and one project's sessions) live in one window:
  // glass turns into an opaque gray in a window that is not the key window,
  // and of two windows only one can be key.
  private var panel: Panel!
  private var monitors: [Any] = []
  private var subscriptions = Set<AnyCancellable>()
  private var actions = Actions()

  // Distance to the menu bar and screen edges. Small, because the cards
  // already keep `Settings.padding` from the panel's edge.
  private let gap: CGFloat = 2

  init(demo: Bool, showAtLaunch: Bool) {
    let now = Date().timeIntervalSince1970 * 1000
    store = demo ? Store(demo: demoProjects(now: now), now: now) : Store()
    settings = Settings(persistent: !demo)
    // Real glass cannot be drawn into a picture, so --show uses a flat stand-in.
    GlassStyle.flat = showAtLaunch
    self.showAtLaunch = showAtLaunch
    self.demo = demo
  }
  let demo: Bool

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      button.image = agentIcon()
      button.imagePosition = .imageLeading
      button.toolTip = Strings.current.tooltip
      button.target = self
      button.action = #selector(toggle)
    }

    // macOS remembers a hidden menu bar icon. Without the icon the app cannot
    // be reached at all, so always bring it back at launch.
    statusItem.isVisible = true

    actions = Actions(
      openProject: { [weak self] project in
        self?.close()
        if !Opener.openProject(project) { self?.codeMissing() }
      },
      openSession: { [weak self] project, session in
        self?.close()
        if !Opener.openSession(project, session) { self?.codeMissing() }
      },
      select: { [weak self] project in self?.select(project.dir) },
      deselect: { [weak self] in self?.hideDetail() },
      setArchived: { [weak self] project, value in
        if self?.selection.dir == project.dir { self?.hideDetail() }
        self?.store.setArchived(project.dir, value)
      },
      newProject: { [weak self] in self?.newProject() },
      quit: { NSApp.terminate(nil) })

    panel = makePanel()

    // The number of working sessions sits next to the icon.
    store.onBadge = { [weak self] working in
      self?.statusItem.button?.title = working > 0 ? " \(working)" : ""
    }

    // New projects get a place at the end of the tiles.
    store.$projects
      .receive(on: DispatchQueue.main)
      .sink { [weak self] projects in self?.settings.adopt(projects.map(\.dir)) }
      .store(in: &subscriptions)

    // More or fewer columns change the panel's width.
    settings.$columns
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.layout() }
      .store(in: &subscriptions)

    if !demo { store.start() }
    // --open: show the panel right away with the real look and keep running.
    if CommandLine.arguments.contains("--open") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
        open()
        if let first = store.visibleProjects.first { select(first.dir) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in printCaptureRect() }
      }
    }
    if showAtLaunch {
      panel.appearance = NSAppearance(named: .darkAqua)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
        open()
        if !settings.editing, let first = store.visibleProjects.first { select(first.dir) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in printFrames() }
      }
    }
  }

  /// The views exist only while the panel is open. Closed, the app keeps
  /// neither the views nor their glass layers around.
  private func attachViews() {
    // Not during SwiftUI's layout pass, or the panel's content keeps a stale size.
    let report: (ReferenceWritableKeyPath<PanelSizes, CGFloat>) -> (CGFloat) -> Void = { [weak self] key in
      { height in
        DispatchQueue.main.async {
          guard let self, self.sizes[keyPath: key] != height else { return }
          self.sizes[keyPath: key] = height
          self.layout()
        }
      }
    }
    let root = PanelView(
      store: store, selection: selection, settings: settings, sizes: sizes, actions: actions,
      onMainHeight: report(\.main), onDetailHeight: report(\.detail))
    // No window background: everything inside is glass, like in Control Center.
    let host = NSHostingView(rootView: root)
    host.sizingOptions = []  // the panel's size is decided in layout()
    panel.contentView = host
  }

  // MARK: Showing and hiding

  @objc private func toggle() {
    if panel.isVisible { close() } else { open() }
  }

  private func open() {
    store.foreground = true
    if !demo { store.refresh() }
    attachViews()
    layout()
    // The self-test (--show) must not take the keyboard away from the user.
    if showAtLaunch { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
    // Soft blur behind the glass, as in Control Center (strength chosen by
    // comparing captures). It only shows where the panel draws glass.
    CGSSetWindowBackgroundBlurRadius(CGSMainConnectionID(), Int32(panel.windowNumber), 18)

    // A click anywhere else or Escape closes the panel (with --open it
    // stays, so the look can be compared at leisure).
    if !CommandLine.arguments.contains("--open"), let monitor = NSEvent.addGlobalMonitorForEvents(
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
    store.foreground = false
    settings.editing = false
    selection.dir = nil
    panel.orderOut(nil)
    panel.contentView = NSView()
  }

  /// The "+" tile: choose or create a folder and open it in VS Code. The
  /// project gets its own tile once a Claude session exists in that folder.
  private func newProject() {
    close()
    let picker = NSOpenPanel()
    picker.canChooseDirectories = true
    picker.canChooseFiles = false
    picker.canCreateDirectories = true
    picker.allowsMultipleSelection = false
    picker.message = Strings.current.newProjectMessage
    picker.prompt = Strings.current.openInCode
    // Start where the other projects are.
    let usual = URL(fileURLWithPath: Paths.home + "/Claude Projects", isDirectory: true)
    if FileManager.default.fileExists(atPath: usual.path) { picker.directoryURL = usual }
    NSApp.activate(ignoringOtherApps: true)
    guard picker.runModal() == .OK, let folder = picker.url else { return }
    if !Opener.openFolder(folder) { codeMissing() }
  }

  /// Clicking a tile opens that project's sessions next to the overview;
  /// clicking it again closes them.
  private func select(_ dir: String) {
    selection.dir = selection.dir == dir ? nil : dir
    layout()
  }

  private func hideDetail() {
    selection.dir = nil
    layout()
  }

  // MARK: Placement

  /// The panel hangs below the menu bar with a small gap, like Control Center.
  /// The overview sits under the menu bar icon; a project's sessions appear to
  /// its left (to its right if there is no room). Each part is only as tall as
  /// its content.
  private func layout() {
    guard let button = statusItem.button, let anchor = button.window,
      let screen = anchor.screen ?? NSScreen.main
    else { return }
    let area = screen.visibleFrame
    // With an auto-hidden menu bar the visible area reaches the top of the
    // screen, so also stay below the menu bar item itself.
    let top = min(area.maxY, anchor.frame.minY) - gap
    let maxHeight = top - area.minY - gap
    let mainWidth = settings.mainWidth

    var x = anchor.frame.midX - mainWidth / 2
    x = max(area.minX + gap, min(x, area.maxX - gap - mainWidth))
    var width = mainWidth
    var height = min(sizes.main, maxHeight)
    var onRight = false
    if selection.dir != nil {
      width += Layout.detailWidth
      height = max(height, min(sizes.detail, maxHeight))
      if x - Layout.detailWidth >= area.minX + gap { x -= Layout.detailWidth } else { onRight = true }
    }
    if sizes.maxHeight != maxHeight { sizes.maxHeight = maxHeight }
    if sizes.detailOnRight != onRight { sizes.detailOnRight = onRight }

    let frame = NSRect(x: x, y: top - height, width: width, height: height)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
  }

  /// For `--show`: where the panel ended up, and a picture of it in the
  /// current folder (drawn by the app itself with the flat stand-in look).
  private func printFrames() {
    guard let button = statusItem.button, let anchor = button.window, let screen = anchor.screen else { return }
    print("screen \(screen.frame) visible \(screen.visibleFrame)")
    print("menu bar item \(anchor.frame)")
    print("panel \(panel.frame) main \(sizes.main) detail \(sizes.detail)")
    print("gap below menu bar: \(min(screen.visibleFrame.maxY, anchor.frame.minY) - panel.frame.maxY)")
    fflush(stdout)
    if let tiff = agentIcon(scale: 12).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "icon.png"))
    }
    snapshot(panel, "panel.png")
    NSApp.terminate(nil)
  }

  /// For `--open`: the panel's area as "x,y,w,h" for `screencapture -R`.
  private func printCaptureRect() {
    guard let primary = NSScreen.screens.first else { return }
    let rect = panel.frame.insetBy(dx: -24, dy: -24).intersection(primary.frame)
    print("\(Int(rect.minX)),\(Int(primary.frame.maxY - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))")
    fflush(stdout)
  }

  private func snapshot(_ panel: NSPanel, _ name: String) {
    guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = NSImage(size: view.bounds.size)
    image.lockFocus()
    // Stands in for the desktop behind the panels.
    NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.19, alpha: 1).setFill()
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
