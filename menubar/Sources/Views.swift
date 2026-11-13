// What the two panels show.
//   MainView    – what needs attention now, then one tile per project
//   DetailView  – the sessions of the project whose tile was clicked
// Everything sits on separate glass cards without a window background, like
// Control Center. Both views report the height they need so the panels can fit
// their content.

import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct Actions {
  var openProject: (Project) -> Void = { _ in }
  var openSession: (Project, Session) -> Void = { _, _ in }
  var select: (Project) -> Void = { _ in }
  var deselect: () -> Void = {}
  var setArchived: (Project, Bool) -> Void = { _, _ in }
  var quit: () -> Void = {}
}

/// Which project's sessions are shown in the second panel (its folder name).
final class Selection: ObservableObject {
  @Published var dir: String?
}

enum Layout {
  static let detailWidth: CGFloat = 430
  static let nowMax = 5
  static let searchMax = 30
  static let tileHeight: CGFloat = 62
  /// A large tile covers two rows.
  static let tallTileHeight: CGFloat = 2 * tileHeight + Settings.spacing
  static let card = RoundedRectangle(cornerRadius: 22, style: .continuous)
  static let tile = RoundedRectangle(cornerRadius: 26, style: .continuous)
}

// MARK: - Glass

enum GlassStyle {
  /// Draw a flat stand-in instead of real glass (for pictures of the panels).
  static var flat = false

  // Like Control Center: clear glass, so what lies behind stays visible, and
  // a dark tint that keeps text readable. The cards are a little darker than
  // the pane they sit on. Chosen by comparing captures with Control Center.
  static let cardTint = Color.black.opacity(0.28)
  static let paneTint = Color.black.opacity(0.20)

  /// In pictures, this stands in for the desktop behind the panels.
  static var backdrop: Color {
    flat ? Color(red: 0.11, green: 0.14, blue: 0.21) : Color.clear
  }
}

@available(macOS 26.0, *)
private func liquidGlass(_ tint: Color?, _ interactive: Bool) -> Glass {
  // Clear glass like the controls in Control Center: what lies behind stays
  // visible. A slight dark tint keeps the text readable on bright backgrounds.
  var glass = Glass.clear.tint(tint ?? GlassStyle.cardTint)
  if interactive { glass = glass.interactive() }
  return glass
}

extension View {
  /// Liquid Glass on macOS 26 and newer, the system's blur material before that.
  /// The system draws both; nothing is animated or computed by the app.
  @ViewBuilder
  fileprivate func glass<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false)
    -> some View
  {
    if GlassStyle.flat {
      background(
        ZStack {
          shape.fill(Color.white.opacity(0.13))
          if let tint { shape.fill(tint) }
          shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        })
    } else if #available(macOS 26.0, *) {
      glassEffect(liquidGlass(tint, interactive), in: shape)
    } else {
      background(
        ZStack {
          shape.fill(.regularMaterial)
          if let tint { shape.fill(tint) }
        })
    }
  }
}

/// The area behind the cards: one large pane of clear glass, so the space
/// between the cards is glass too.
private struct Backdrop: View {
  private let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

  var body: some View {
    if GlassStyle.flat {
      GlassStyle.backdrop
    } else if #available(macOS 26.0, *) {
      Color.clear.glassEffect(Glass.clear.tint(GlassStyle.paneTint), in: shape)
    } else {
      shape.fill(.ultraThinMaterial)
    }
  }
}

// MARK: - Helpers

private struct HeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

extension View {
  /// Adds this view's height to the total reported through `HeightKey`.
  fileprivate func measured() -> some View {
    background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
  }
}

private func titleOf(_ session: Session, _ t: Strings) -> String {
  session.title.isEmpty ? t.untitled : session.title
}

// Long project names must not push the excerpt out of a session row.
private func shortTag(_ name: String) -> String {
  name.count > 20 ? name.prefix(19) + "…" : name
}

private func counts(_ project: Project, _ now: Double) -> (working: Int, waiting: Int) {
  var working = 0
  var waiting = 0
  for session in project.sessions {
    switch status(session, now) {
    case .working: working += 1
    // An open turn from days ago is no longer something to act on.
    case .waiting: if now - session.lastTs < recentMs { waiting += 1 }
    case .done: break
    }
  }
  return (working, waiting)
}

// Symbols offered for projects (SF Symbols, part of macOS). Names this macOS
// version does not know are left out when the list is first used.
private let symbolChoices: [String] = [
  "folder.fill", "folder.badge.gearshape", "tray.full.fill", "archivebox.fill", "doc.fill",
  "doc.text.fill", "doc.richtext.fill", "doc.on.doc.fill", "note.text", "list.bullet.clipboard.fill",
  "book.fill", "books.vertical.fill", "book.closed.fill", "bookmark.fill", "newspaper.fill",
  "text.book.closed.fill", "graduationcap.fill", "studentdesk", "pencil", "pencil.and.ruler.fill",
  "highlighter", "paintbrush.fill", "paintbrush.pointed.fill", "paintpalette.fill", "scribble.variable",
  "lasso", "ruler.fill", "scissors", "eyedropper.halffull", "wand.and.stars", "house.fill",
  "building.2.fill", "building.columns.fill", "storefront.fill", "bed.double.fill", "sofa.fill",
  "lamp.desk.fill", "lightbulb.fill", "door.left.hand.closed", "window.vertical.closed", "briefcase.fill",
  "case.fill", "suitcase.fill", "bag.fill", "cart.fill", "basket.fill", "creditcard.fill", "banknote.fill",
  "dollarsign.circle.fill", "eurosign.circle.fill", "chart.bar.fill", "chart.pie.fill",
  "chart.line.uptrend.xyaxis", "chart.xyaxis.line", "percent", "function", "sum", "number",
  "plusminus.circle.fill", "x.squareroot", "calendar", "clock.fill", "alarm.fill", "timer",
  "stopwatch.fill", "hourglass", "bell.fill", "flag.fill", "tag.fill", "ticket.fill", "envelope.fill",
  "paperplane.fill", "tray.fill", "bubble.left.fill", "bubble.left.and.bubble.right.fill", "phone.fill",
  "video.fill", "megaphone.fill", "mic.fill", "quote.bubble.fill", "person.fill", "person.2.fill",
  "person.3.fill", "person.crop.circle.fill", "figure.walk", "figure.run", "figure.wave",
  "hand.raised.fill", "hand.thumbsup.fill", "hands.clap.fill", "heart.fill", "star.fill", "sparkles",
  "bolt.fill", "flame.fill", "drop.fill", "snowflake", "sun.max.fill", "moon.fill", "cloud.fill",
  "cloud.rain.fill", "cloud.bolt.fill", "wind", "tornado", "rainbow", "thermometer.medium",
  "umbrella.fill", "leaf.fill", "tree.fill", "mountain.2.fill", "pawprint.fill", "tortoise.fill",
  "hare.fill", "bird.fill", "fish.fill", "ant.fill", "ladybug.fill", "lizard.fill", "dog.fill", "cat.fill",
  "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces", "curlybraces.square.fill",
  "cpu.fill", "memorychip.fill", "server.rack", "externaldrive.fill", "internaldrive.fill",
  "opticaldiscdrive.fill", "desktopcomputer", "laptopcomputer", "display", "keyboard.fill",
  "computermouse.fill", "printer.fill", "scanner.fill", "tv.fill", "iphone", "ipad", "applewatch",
  "headphones", "hifispeaker.fill", "gamecontroller.fill", "antenna.radiowaves.left.and.right", "wifi",
  "network", "globe", "globe.europe.africa.fill", "link", "lock.fill", "lock.open.fill", "key.fill",
  "shield.fill", "shield.lefthalf.filled", "checkmark.shield.fill", "eye.fill", "eye.slash.fill", "faceid",
  "touchid", "gearshape.fill", "gearshape.2.fill", "wrench.fill", "wrench.and.screwdriver.fill",
  "hammer.fill", "screwdriver.fill", "slider.horizontal.3", "switch.2", "dial.medium.fill", "power",
  "cube.fill", "cube.transparent.fill", "shippingbox.fill", "square.stack.3d.up.fill",
  "rectangle.3.group.fill", "square.grid.2x2.fill", "circle.grid.3x3.fill", "hexagon.fill", "seal.fill",
  "puzzlepiece.fill", "camera.fill", "photo.fill", "photo.on.rectangle.angled", "film.fill",
  "play.rectangle.fill", "music.note", "music.mic", "guitars.fill", "pianokeys", "theatermasks.fill",
  "map.fill", "mappin.and.ellipse", "location.fill", "safari.fill", "signpost.right.fill",
  "binoculars.fill", "car.fill", "bus.fill", "tram.fill", "bicycle", "airplane", "ferry.fill",
  "sailboat.fill", "fuelpump.fill", "bolt.car.fill", "scooter", "figure.hiking", "tent.fill",
  "backpack.fill", "globe.americas.fill", "cross.case.fill", "heart.text.square.fill", "pills.fill",
  "stethoscope", "bandage.fill", "brain.head.profile", "lungs.fill", "dumbbell.fill", "sportscourt.fill",
  "soccerball", "basketball.fill", "tennis.racket", "trophy.fill", "medal.fill", "gift.fill",
  "party.popper.fill", "balloon.fill", "birthday.cake.fill", "fork.knife", "cup.and.saucer.fill",
  "wineglass.fill", "mug.fill", "carrot.fill", "frying.pan.fill", "refrigerator.fill", "washer.fill",
  "shower.fill", "bathtub.fill", "tshirt.fill", "shoe.fill", "atom", "testtube.2", "flask.fill",
  "microbe.fill", "waveform", "waveform.path.ecg", "bolt.horizontal.fill", "battery.100", "powerplug.fill",
  "lightbulb.led.fill", "sensor.fill", "thermometer.sun.fill", "fan.fill", "heater.vertical.fill",
  "air.conditioner.horizontal.fill", "spigot.fill", "solarpanel.fill", "homekit", "robotic.vacuum.fill",
  "light.beacon.max.fill", "questionmark.circle.fill", "exclamationmark.triangle.fill", "info.circle.fill",
  "checkmark.circle.fill", "xmark.circle.fill", "plus.circle.fill", "infinity", "target", "scope",
  "flag.checkered",
].filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

// MARK: - Whole panel

/// Sizes the two parts and the window agree on (see AppDelegate.layout).
final class PanelSizes: ObservableObject {
  @Published var main: CGFloat = 420
  @Published var detail: CGFloat = 300
  @Published var maxHeight: CGFloat = 800
  @Published var detailOnRight = false
}

/// Overview and, next to it, the sessions of the selected project.
struct PanelView: View {
  @ObservedObject var store: Store
  @ObservedObject var selection: Selection
  @ObservedObject var settings: Settings
  @ObservedObject var sizes: PanelSizes
  var actions = Actions()
  var onMainHeight: (CGFloat) -> Void = { _ in }
  var onDetailHeight: (CGFloat) -> Void = { _ in }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      if !sizes.detailOnRight { detail }
      MainView(store: store, selection: selection, settings: settings, actions: actions, onHeight: onMainHeight)
        .frame(height: min(sizes.main, sizes.maxHeight))
      if sizes.detailOnRight { detail }
    }
    .frame(
      maxWidth: .infinity, maxHeight: .infinity, alignment: sizes.detailOnRight ? .topLeading : .topTrailing)
  }

  @ViewBuilder private var detail: some View {
    if selection.dir != nil {
      DetailView(store: store, selection: selection, settings: settings, actions: actions, onHeight: onDetailHeight)
        .frame(height: min(sizes.detail, sizes.maxHeight))
    }
  }
}

// MARK: - Main panel

struct MainView: View {
  @ObservedObject var store: Store
  @ObservedObject var selection: Selection
  @ObservedObject var settings: Settings
  var actions = Actions()
  var onHeight: (CGFloat) -> Void = { _ in }

  @State private var query = ""
  @State private var showArchive = false
  @State private var loginItem = SMAppService.mainApp.status == .enabled
  /// Folder name of the tile being dragged in edit mode.
  @State private var dragging: String?

  private let t = Strings.current
  private let pad = Settings.padding

  private struct Item: Identifiable {
    let project: Project
    let session: Session
    let kind: Status
    var id: String { project.dir + "/" + session.id }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, pad)
        .padding(.top, pad)
        .measured()
      ScrollView {
        VStack(alignment: .leading, spacing: Settings.spacing) { content }
          .padding(.horizontal, pad)
          .padding(.vertical, Settings.spacing)
          .measured()
      }
      bottomBar
        .padding(.horizontal, pad)
        .padding(.bottom, pad)
        .measured()
    }
    .frame(width: settings.mainWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Backdrop())
    .onPreferenceChange(HeightKey.self) { onHeight($0) }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(t.heading).font(.system(size: 15, weight: .semibold))
        Spacer()
        stats
      }
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(t.search, text: $query).textFieldStyle(.plain)
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .font(.system(size: 13))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Capsule().fill(Color.primary.opacity(0.09)))
    }
    .padding(14)
    .glass(Layout.card)
  }

  private var stats: some View {
    HStack(spacing: 5) {
      if store.loaded {
        let visible = store.visibleProjects
        let working = store.workingCount
        Text(t.projects(visible.count) + " · " + t.sessions(visible.reduce(0) { $0 + $1.sessions.count }))
        if working > 0 {
          Text("·")
          StatusCount(text: t.workingCount(working), status: .working)
        }
      } else {
        Text(t.loading)
      }
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
  }

  // Like "Edit Controls" in Control Center: one button at the bottom.
  private var bottomBar: some View {
    HStack {
      Menu {
        Picker(t.columns, selection: $settings.columns) {
          ForEach(Array(Settings.columnRange), id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.menu)
        Button(t.resetOrder) { settings.resetOrder(store.projects.map(\.dir)) }
        Divider()
        Toggle(t.loginItem, isOn: loginBinding)
        Divider()
        Button(t.quit) { actions.quit() }
      } label: {
        Image(systemName: "gearshape")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 32, height: 32)
      .glass(Circle(), interactive: true)
      .help(t.settings)

      Spacer()
      if store.loaded && !store.projects.isEmpty {
        Button {
          settings.editing.toggle()
          if settings.editing { actions.deselect() }
        } label: {
          Text(settings.editing ? t.done : t.edit)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 32)
            .contentShape(Capsule())
            .glass(Capsule(), tint: settings.editing ? Color.accentColor.opacity(0.55) : nil, interactive: true)
        }
        .buttonStyle(.plain)
      }
      Spacer()
      // Keeps the edit button centered.
      Color.clear.frame(width: 32, height: 32)
    }
  }

  // The user switches autostart on and off here; the app never does it on its own.
  private var loginBinding: Binding<Bool> {
    Binding(
      get: { loginItem },
      set: { enable in
        do {
          if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
          NSSound.beep()
        }
        loginItem = SMAppService.mainApp.status == .enabled
      })
  }

  private var words: [String] {
    query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
  }

  private func matches(_ text: String, _ words: [String]) -> Bool {
    let hay = text.lowercased()
    return words.allSatisfy { hay.contains($0) }
  }

  // Sessions that are working or waiting for an answer – across all projects.
  private func attention(_ projects: [Project]) -> (items: [Item], working: Int) {
    var items: [Item] = []
    for project in projects {
      for session in project.sessions {
        let kind = status(session, store.now)
        if kind == .working || (kind == .waiting && store.now - session.lastTs < recentMs) {
          items.append(Item(project: project, session: session, kind: kind))
        }
      }
    }
    items.sort {
      $0.kind != $1.kind ? $0.kind.rawValue < $1.kind.rawValue : $0.session.lastTs > $1.session.lastTs
    }
    let working = items.filter { $0.kind == .working }.count
    return (Array(items.prefix(max(working, Layout.nowMax))), working)
  }

  private func found(_ projects: [Project], _ words: [String]) -> [Item] {
    var items: [Item] = []
    for project in projects {
      for session in project.sessions
      where matches(settings.title(project) + " " + project.name + " " + titleOf(session, t) + " " + session.excerpt, words) {
        items.append(Item(project: project, session: session, kind: status(session, store.now)))
      }
    }
    items.sort { $0.session.lastTs > $1.session.lastTs }
    return Array(items.prefix(Layout.searchMax))
  }

  @ViewBuilder private var content: some View {
    let words = self.words
    let searching = !words.isEmpty
    let visible = settings.ordered(store.visibleProjects)
    let archived = store.archivedProjects
    // Session rows are wide, so they get half as many columns as the tiles.
    let rowColumns = max(1, settings.columns / 2)

    if !searching {
      let top = attention(visible)
      if !top.items.isEmpty && !settings.editing {
        sessionCard(
          t.now, top.working > 0 ? t.nowWorking(top.working) : t.status(.waiting), top.items, rowColumns)
      }
      if !visible.isEmpty {
        tiles(visible, editing: settings.editing, archived: false)
      }
      if let dir = settings.pickingIcon, let project = visible.first(where: { $0.dir == dir }) {
        symbolPicker(project)
      }
      if !archived.isEmpty {
        Button {
          showArchive.toggle()
        } label: {
          HStack(spacing: 5) {
            Image(systemName: showArchive ? "chevron.down" : "chevron.right")
              .font(.system(size: 9, weight: .semibold))
            Text(t.archiveToggle(archived.count))
          }
          .font(.system(size: 11, weight: .medium))
          .padding(.horizontal, 12)
          .frame(height: 26)
          .contentShape(Capsule())
          .glass(Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        if showArchive { tiles(archived, editing: settings.editing, archived: true) }
      }
      if store.loaded && store.projects.isEmpty { empty(t.emptyTitle, t.emptyText) }
    } else {
      let projects = visible.filter { matches(settings.title($0) + " " + $0.name, words) }
      let archivedHits = archived.filter { matches(settings.title($0) + " " + $0.name, words) }
      let sessions = found(visible + archived, words)
      if !projects.isEmpty { tiles(projects, editing: false, archived: false) }
      if !archivedHits.isEmpty { tiles(archivedHits, editing: false, archived: true) }
      if !sessions.isEmpty { sessionCard(t.sessionsTitle, nil, sessions, rowColumns) }
      if projects.isEmpty && archivedHits.isEmpty && sessions.isEmpty {
        empty(t.noMatchTitle, t.noMatchText(query.trimmingCharacters(in: .whitespaces)))
      }
    }
  }

  private func sessionCard(_ title: String, _ meta: String?, _ items: [Item], _ columns: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(title).font(.system(size: 13, weight: .semibold))
        if let meta { Text(meta).font(.system(size: 11)).foregroundStyle(.secondary) }
      }
      .padding(.horizontal, 4)
      Columns(items: items, count: columns, spacing: 4) { sessionRow($0) }
    }
    .padding(10)
    .glass(Layout.card)
  }

  private struct Placed: Identifiable {
    let project: Project
    let tall: Bool
    let column: Int
    let row: Int
    var id: String { project.dir }
  }

  /// Puts every tile into the first free place of the grid. Large tiles take
  /// two rows, so a small tile may fill a gap further up.
  private func place(_ projects: [Project]) -> (items: [Placed], rows: Int) {
    let columns = settings.columns
    var used = Set<Int>()  // row * columns + column
    var items: [Placed] = []
    var rows = 0
    for project in projects {
      let tall = settings.tall.contains(project.dir)
      var cell = 0
      while used.contains(cell) || (tall && used.contains(cell + columns)) { cell += 1 }
      used.insert(cell)
      if tall { used.insert(cell + columns) }
      items.append(Placed(project: project, tall: tall, column: cell % columns, row: cell / columns))
      rows = max(rows, cell / columns + (tall ? 2 : 1))
    }
    return (items, rows)
  }

  private func tiles(_ projects: [Project], editing: Bool, archived: Bool) -> some View {
    let shown = projects.map(\.dir)
    let placed = place(projects)
    let stepX = Settings.tileWidth + Settings.spacing
    let stepY = Layout.tileHeight + Settings.spacing
    return ZStack(alignment: .topLeading) {
      ForEach(placed.items) { item in
        tile(item.project, editing: editing, archived: archived, tall: item.tall, shown: shown)
          .frame(width: Settings.tileWidth)
          .offset(x: CGFloat(item.column) * stepX, y: CGFloat(item.row) * stepY)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .frame(height: CGFloat(placed.rows) * stepY - Settings.spacing, alignment: .topLeading)
  }

  @ViewBuilder
  private func tile(_ project: Project, editing: Bool, archived: Bool, tall: Bool, shown: [String]) -> some View {
    let color = projectColor(project, store.prefs)
    let symbol = settings.icon(project.dir)
    // A large tile shows the most recent session.
    let latest = project.sessions.first
    let previewTitle = latest.map { titleOf($0, t) } ?? ""
    let preview = latest?.excerpt ?? ""
    if editing && archived {
      EditTile(
        name: settings.title(project), symbol: symbol, color: color, archived: true, picking: false, tall: tall,
        previewTitle: previewTitle, preview: preview, t: t
      ) {
        actions.setArchived(project, false)
      }
    } else if editing {
      EditTile(
        name: settings.title(project), symbol: symbol, color: color, archived: false,
        picking: settings.pickingIcon == project.dir, tall: tall,
        previewTitle: previewTitle, preview: preview, t: t,
        onResize: { settings.toggleTall(project.dir) },
        onSymbol: { settings.pickingIcon = settings.pickingIcon == project.dir ? nil : project.dir },
        onBack: { settings.shift(project.dir, by: -1, shown: shown) },
        onForward: { settings.shift(project.dir, by: 1, shown: shown) }
      ) {
        actions.setArchived(project, true)
      }
      .opacity(dragging == project.dir ? 0.45 : 1)
      .onDrag {
        dragging = project.dir
        return NSItemProvider(object: project.dir as NSString)
      }
      .onDrop(
        of: [UTType.text],
        delegate: TileDrop(target: project.dir, dragging: $dragging) { dir, target in
          settings.move(dir, onto: target, shown: shown)
        })
    } else {
      let count = counts(project, store.now)
      ProjectTile(
        name: settings.title(project),
        symbol: symbol,
        color: color,
        working: count.working > 0 ? t.workingCount(count.working) : nil,
        waiting: count.waiting > 0 ? t.waitingCount(count.waiting) : nil,
        idle: t.relTime(project.lastTs, now: store.now),
        selected: selection.dir == project.dir,
        tall: tall,
        previewTitle: previewTitle,
        preview: preview,
        help: t.sessions(project.sessions.count) + " – " + (project.path ?? project.dir),
        openWindowHelp: t.openWindow,
        action: { actions.select(project) },
        openWindow: { actions.openProject(project) }
      )
      .contextMenu {
        Button(t.openWindow) { actions.openProject(project) }
        Button(tall ? t.shrink : t.enlarge) { settings.toggleTall(project.dir) }
        Button(archived ? t.restore : t.archive) { actions.setArchived(project, !archived) }
      }
    }
  }

  private func symbolPicker(_ project: Project) -> some View {
    let color = projectColor(project, store.prefs)
    let current = settings.icon(project.dir)
    let colorIndex = projectColorIndex(project, store.prefs)
    let perRow = max(6, Int((settings.mainWidth - 2 * pad - 20) / 38))
    return VStack(alignment: .leading, spacing: 8) {
      // Title: the folder's name unless the user types another one.
      HStack(spacing: 8) {
        Text(t.titleLabel).font(.system(size: 13, weight: .semibold))
        TextField(
          project.name,
          text: Binding(
            get: { settings.titles[project.dir] ?? "" },
            set: { settings.setTitle(project.dir, $0) })
        )
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.10)))
      }
      .padding(.horizontal, 4)
      // Colors first; the picker stays open so that a symbol can follow.
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: perRow), spacing: 6) {
        ForEach(palette.indices, id: \.self) { index in
          Button {
            store.setColor(project.dir, index)
          } label: {
            Circle().fill(palette[index])
              .frame(width: 24, height: 24)
              .overlay(Circle().strokeBorder(Color.white.opacity(index == colorIndex ? 0.95 : 0), lineWidth: 2))
              .frame(width: 30, height: 30)
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
        }
      }
      Divider().opacity(0.4)
      // Many symbols: they scroll inside the card instead of stretching the panel.
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: perRow), spacing: 6) {
          ForEach(symbolChoices, id: \.self) { name in
            Button {
              settings.setIcon(project.dir, name)
            } label: {
              Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(name == current ? Color.white : Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(name == current ? color : Color.primary.opacity(0.10)))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 2)
      }
      .frame(height: 210)
    }
    .padding(12)
    .glass(Layout.card)
  }

  private func sessionRow(_ item: Item) -> some View {
    let recent = store.now - item.session.lastTs < recentMs
    return SessionRow(
      title: titleOf(item.session, t),
      excerpt: item.session.excerpt,
      time: t.relTime(item.session.lastTs, now: store.now),
      tag: shortTag(settings.title(item.project)),
      status: item.kind == .working || recent ? item.kind : nil,
      statusText: t.status(item.kind),
      color: projectColor(item.project, store.prefs)
    ) { actions.openSession(item.project, item.session) }
  }

  private func empty(_ title: String, _ text: String) -> some View {
    VStack(spacing: 4) {
      Text(title).font(.system(size: 13, weight: .semibold))
      Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 26)
    .padding(.horizontal, 12)
    .glass(Layout.card)
  }
}

// MARK: - Project panel

struct DetailView: View {
  @ObservedObject var store: Store
  @ObservedObject var selection: Selection
  @ObservedObject var settings: Settings
  var actions = Actions()
  var onHeight: (CGFloat) -> Void = { _ in }

  private let t = Strings.current
  private let pad = Settings.padding

  var body: some View {
    VStack(spacing: 0) {
      if let project = store.projects.first(where: { $0.dir == selection.dir }) {
        header(project)
          .padding(.horizontal, pad)
          .padding(.top, pad)
          .padding(.bottom, Settings.spacing)
          .measured()
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(project.sessions) { row(project, $0) }
          }
          .padding(10)
          .measured()
        }
        .clipShape(Layout.card)
        .glass(Layout.card)
        .padding(.horizontal, pad)
        .padding(.bottom, pad)
      }
    }
    .frame(width: Layout.detailWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Backdrop())
    .onPreferenceChange(HeightKey.self) { onHeight($0 + pad) }
  }

  private func header(_ project: Project) -> some View {
    let count = counts(project, store.now)
    return HStack(alignment: .center, spacing: 10) {
      IconCircle(symbol: settings.icon(project.dir), color: projectColor(project, store.prefs))
      VStack(alignment: .leading, spacing: 2) {
        Text(settings.title(project)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        HStack(spacing: 8) {
          Text(t.sessions(project.sessions.count)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
          if count.working > 0 { StatusCount(text: t.workingCount(count.working), status: .working) }
          if count.waiting > 0 { StatusCount(text: t.waitingCount(count.waiting), status: .waiting) }
        }
        .font(.system(size: 11))
      }
      Spacer(minLength: 4)
      Button {
        actions.openProject(project)
      } label: {
        Label(t.openWindow, systemImage: "arrow.up.forward.app")
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
          .fixedSize()
          .padding(.horizontal, 12)
          .frame(height: 30)
          .contentShape(Capsule())
          .background(Capsule().fill(Color.primary.opacity(0.10)))
      }
      .buttonStyle(.plain)
      .help(project.path ?? project.dir)
    }
    .padding(12)
    .glass(Layout.card)
  }

  private func row(_ project: Project, _ session: Session) -> some View {
    let kind = status(session, store.now)
    let show = kind == .working || (kind == .waiting && store.now - session.lastTs < recentMs)
    return SessionRow(
      title: titleOf(session, t),
      excerpt: session.excerpt,
      time: t.relTime(session.lastTs, now: store.now),
      tag: nil,
      status: show ? kind : nil,
      statusText: t.status(kind),
      color: projectColor(project, store.prefs)
    ) { actions.openSession(project, session) }
  }
}

// MARK: - Pieces

/// Lays items out in rows of `count` equally wide cells.
private struct Columns<Item: Identifiable, Cell: View>: View {
  let items: [Item]
  let count: Int
  let spacing: CGFloat
  var gap: CGFloat = Settings.spacing
  @ViewBuilder let cell: (Item) -> Cell

  var body: some View {
    VStack(spacing: spacing) {
      ForEach(Array(stride(from: 0, to: items.count, by: count)), id: \.self) { start in
        HStack(alignment: .top, spacing: gap) {
          ForEach(0..<count, id: \.self) { offset in
            if start + offset < items.count {
              cell(items[start + offset]).frame(maxWidth: .infinity)
            } else {
              Color.clear.frame(maxWidth: .infinity).frame(height: 1)
            }
          }
        }
      }
    }
  }
}

/// Dragging a tile over another one moves it there right away.
private struct TileDrop: DropDelegate {
  let target: String
  @Binding var dragging: String?
  let move: (String, String) -> Void

  func dropEntered(info: DropInfo) {
    if let dragging, dragging != target { move(dragging, target) }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    dragging = nil
    return true
  }
}

private struct StatusCount: View {
  let text: String
  let status: Status

  var body: some View {
    HStack(spacing: 4) {
      Circle().fill(status.color).frame(width: 7, height: 7)
      Text(text).foregroundStyle(status.color).lineLimit(1)
    }
    .fixedSize()
  }
}

/// The project's symbol on its color, like the round buttons in Control Center.
private struct IconCircle: View {
  let symbol: String
  let color: Color
  var size: CGFloat = 36

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(Circle().fill(color))
  }
}

private struct IconButton: View {
  let symbol: String
  let help: String
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 26, height: 22)
        .background(Capsule().fill(Color.primary.opacity(hover ? 0.22 : 0.10)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(help)
  }
}

/// Lower half of a large tile: the latest session's title and Claude's last message.
private struct TilePreview: View {
  let title: String
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
      if !text.isEmpty {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
          .multilineTextAlignment(.leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One project: symbol, name, how many sessions are active (or the last activity).
private struct ProjectTile: View {
  let name: String
  let symbol: String
  let color: Color
  let working: String?
  let waiting: String?
  let idle: String
  let selected: Bool
  let tall: Bool
  let previewTitle: String
  let preview: String
  let help: String
  let openWindowHelp: String
  let action: () -> Void
  let openWindow: () -> Void
  @State private var arrowHover = false

  var body: some View {
    Button(action: action) {
     VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        IconCircle(symbol: symbol, color: color)
        VStack(alignment: .leading, spacing: 2) {
          // Leaves room for the "open window" button, which lies on top of the tile.
          Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).padding(.trailing, 18)
          HStack(spacing: 5) {
            if let working { StatusCount(text: working, status: .working) }
            if let waiting { StatusCount(text: waiting, status: .waiting) }
            if working == nil && waiting == nil {
              Text(idle).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          .font(.system(size: 11))
        }
        Spacer(minLength: 0)
      }
      .frame(height: Layout.tileHeight)
      if tall { TilePreview(title: previewTitle, text: preview).padding(.trailing, 5) }
     }
      .padding(.leading, 11)
      // Narrow, so that "1 working · 1 waiting" still fits next to the symbol.
      .padding(.trailing, 8)
      .frame(height: tall ? Layout.tallTileHeight : Layout.tileHeight, alignment: .top)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Layout.tile)
      .glass(Layout.tile, tint: selected ? color.opacity(0.45) : nil, interactive: true)
    }
    .buttonStyle(.plain)
    .help(help)
    // The arrow jumps straight into the project's VS Code window.
    .overlay(alignment: .topTrailing) {
      Button(action: openWindow) {
        Image(systemName: "arrow.up.forward.app")
          .font(.system(size: 12))
          .foregroundStyle(arrowHover ? Color.primary : Color.secondary)
          .frame(width: 26, height: 26)
          .background(Circle().fill(Color.primary.opacity(arrowHover ? 0.16 : 0)))
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .onHover { arrowHover = $0 }
      .help(openWindowHelp)
      .padding(.top, 6)
      .padding(.trailing, 8)
    }
  }
}

/// A tile in edit mode: choose its symbol, move it (drag, or the two arrows)
/// and archive it. Archived tiles can only be restored.
private struct EditTile: View {
  let name: String
  let symbol: String
  let color: Color
  let archived: Bool
  let picking: Bool
  let tall: Bool
  let previewTitle: String
  let preview: String
  let t: Strings
  var onResize: () -> Void = {}
  var onSymbol: () -> Void = {}
  var onBack: () -> Void = {}
  var onForward: () -> Void = {}
  let onArchive: () -> Void

  var body: some View {
   VStack(alignment: .leading, spacing: 0) {
    HStack(spacing: 9) {
      if archived {
        IconCircle(symbol: symbol, color: color)
      } else {
        Button(action: onSymbol) {
          IconCircle(symbol: symbol, color: color)
            .overlay(Circle().strokeBorder(Color.white.opacity(picking ? 0.95 : 0), lineWidth: 2))
            .overlay(alignment: .bottomTrailing) {
              Image(systemName: "pencil.circle.fill")
                .font(.system(size: 13))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.black, Color.white)
                .offset(x: 3, y: 3)
            }
        }
        .buttonStyle(.plain)
        .help(t.chooseSymbol)
      }
      VStack(alignment: .leading, spacing: 4) {
        if archived {
          Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        } else {
          Button(action: onSymbol) {
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(t.chooseSymbol)
        }
        HStack(spacing: 3) {
          if !archived {
            IconButton(symbol: "chevron.left", help: t.moveBack, action: onBack)
            IconButton(symbol: "chevron.right", help: t.moveForward, action: onForward)
            IconButton(
              symbol: tall ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
              help: tall ? t.shrink : t.enlarge, action: onResize)
          }
          Spacer(minLength: 0)
          IconButton(
            symbol: archived ? "arrow.uturn.backward" : "archivebox",
            help: archived ? t.restore : t.archive, action: onArchive)
        }
      }
    }
    .frame(height: Layout.tileHeight)
    if tall { TilePreview(title: previewTitle, text: preview).opacity(0.6) }
   }
    .padding(.leading, 11)
    .padding(.trailing, 13)
    .frame(height: tall ? Layout.tallTileHeight : Layout.tileHeight, alignment: .top)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Layout.tile)
    .glass(Layout.tile)
    .overlay(
      Layout.tile.strokeBorder(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
  }
}

/// Compact row: title and time on the first line, one line of context below.
private struct SessionRow: View {
  let title: String
  let excerpt: String
  let time: String
  let tag: String?
  let status: Status?
  let statusText: String
  let color: Color
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            if let status { Circle().fill(status.color).frame(width: 7, height: 7) }
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            Text(time).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
              .lineLimit(1).fixedSize()
          }
          if tag != nil || status != nil || !excerpt.isEmpty {
            HStack(spacing: 6) {
              if let tag {
                Text(tag)
                  .lineLimit(1)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.30)))
                  .fixedSize()
              }
              if let status {
                Text(statusText).foregroundStyle(status.color).lineLimit(1).fixedSize()
              }
              if !excerpt.isEmpty {
                Text(excerpt).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            .font(.system(size: 11))
          }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.primary.opacity(hover ? 0.14 : 0.06)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(excerpt.isEmpty ? title : title + "\n\n" + excerpt)
  }
}
