// What the two panels show.
//   MainView    – what needs attention now, then one tile per project
//   DetailView  – the sessions of the project whose tile was clicked
// Both report the height they need so the panels can fit their content.

import ServiceManagement
import SwiftUI

struct Actions {
  var openProject: (Project) -> Void = { _ in }
  var openSession: (Project, Session) -> Void = { _, _ in }
  var select: (Project) -> Void = { _ in }
  var quit: () -> Void = {}
}

/// Which project's sessions are shown in the second panel (its folder name).
final class Selection: ObservableObject {
  @Published var dir: String?
}

enum Layout {
  static let mainWidth: CGFloat = 380
  static let detailWidth: CGFloat = 360
  static let nowMax = 5
  static let searchMax = 30
}

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

// MARK: - Main panel

struct MainView: View {
  @ObservedObject var store: Store
  @ObservedObject var selection: Selection
  var actions = Actions()
  var onHeight: (CGFloat) -> Void = { _ in }

  @State private var query = ""
  @State private var showArchive = false
  @State private var loginItem = SMAppService.mainApp.status == .enabled

  private let t = Strings.current

  private struct Item: Identifiable {
    let project: Project
    let session: Session
    let kind: Status
    var id: String { project.dir + "/" + session.id }
  }

  var body: some View {
    VStack(spacing: 0) {
      header.measured()
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) { content }
          .padding(12)
          .measured()
      }
      Divider()
      footer.measured()
    }
    .frame(width: Layout.mainWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .onPreferenceChange(HeightKey.self) { onHeight($0 + 2) }
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
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
    }
    .padding(12)
  }

  private var stats: some View {
    HStack(spacing: 5) {
      if store.loaded {
        let visible = store.visibleProjects
        let working = store.workingCount
        Text(t.projects(visible.count) + " · " + t.sessions(visible.reduce(0) { $0 + $1.sessions.count }))
        if working > 0 {
          Text("·")
          Circle().fill(Status.working.color).frame(width: 7, height: 7)
          Text(t.workingCount(working)).foregroundStyle(Status.working.color)
        }
      } else {
        Text(t.loading)
      }
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
  }

  private var footer: some View {
    HStack {
      Menu {
        Toggle(t.loginItem, isOn: loginBinding)
        Divider()
        Button(t.quit) { actions.quit() }
      } label: {
        Image(systemName: "gearshape")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(t.settings)
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
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
      where matches(project.name + " " + titleOf(session, t) + " " + session.excerpt, words) {
        items.append(Item(project: project, session: session, kind: status(session, store.now)))
      }
    }
    items.sort { $0.session.lastTs > $1.session.lastTs }
    return Array(items.prefix(Layout.searchMax))
  }

  @ViewBuilder private var content: some View {
    let words = self.words
    let searching = !words.isEmpty
    let visible = store.visibleProjects
    let archived = store.archivedProjects

    if !searching {
      let top = attention(visible)
      if !top.items.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          sectionTitle(t.now, top.working > 0 ? t.nowWorking(top.working) : t.status(.waiting))
          ForEach(top.items) { sessionRow($0) }
        }
      }
      if !visible.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          sectionTitle(t.projectsTitle, nil)
          tiles(visible)
        }
      }
      if !archived.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Button {
            showArchive.toggle()
          } label: {
            HStack(spacing: 4) {
              Image(systemName: showArchive ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
              Text(t.archiveToggle(archived.count))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          if showArchive { tiles(archived) }
        }
      }
      if store.loaded && store.projects.isEmpty { empty(t.emptyTitle, t.emptyText) }
    } else {
      let projects = (visible + archived).filter { matches($0.name, words) }
      let sessions = found(visible + archived, words)
      if !projects.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          sectionTitle(t.projectsTitle, nil)
          tiles(projects)
        }
      }
      if !sessions.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          sectionTitle(t.sessionsTitle, nil)
          ForEach(sessions) { sessionRow($0) }
        }
      }
      if projects.isEmpty && sessions.isEmpty {
        empty(t.noMatchTitle, t.noMatchText(query.trimmingCharacters(in: .whitespaces)))
      }
    }
  }

  private func sectionTitle(_ title: String, _ meta: String?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title).font(.system(size: 13, weight: .semibold))
      if let meta { Text(meta).font(.system(size: 11)).foregroundStyle(.secondary) }
    }
    .padding(.horizontal, 4)
  }

  // Two tiles per row.
  private func tiles(_ projects: [Project]) -> some View {
    VStack(spacing: 8) {
      ForEach(Array(stride(from: 0, to: projects.count, by: 2)), id: \.self) { index in
        HStack(spacing: 8) {
          tile(projects[index])
          if index + 1 < projects.count {
            tile(projects[index + 1])
          } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: 1)
          }
        }
      }
    }
  }

  private func tile(_ project: Project) -> some View {
    let count = counts(project, store.now)
    return ProjectTile(
      name: project.name,
      color: projectColor(project, store.prefs),
      working: count.working > 0 ? t.workingCount(count.working) : nil,
      waiting: count.waiting > 0 ? t.waitingCount(count.waiting) : nil,
      sessions: t.sessions(project.sessions.count),
      time: t.relTime(project.lastTs, now: store.now),
      selected: selection.dir == project.dir,
      help: project.path ?? project.dir,
      openWindowHelp: t.openWindow,
      action: { actions.select(project) },
      openWindow: { actions.openProject(project) })
  }

  private func sessionRow(_ item: Item) -> some View {
    let recent = store.now - item.session.lastTs < recentMs
    return SessionRow(
      title: titleOf(item.session, t),
      excerpt: item.session.excerpt,
      time: t.relTime(item.session.lastTs, now: store.now),
      tag: shortTag(item.project.name),
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
    .padding(.vertical, 30)
  }
}

// MARK: - Project panel

struct DetailView: View {
  @ObservedObject var store: Store
  @ObservedObject var selection: Selection
  var actions = Actions()
  var onHeight: (CGFloat) -> Void = { _ in }

  private let t = Strings.current

  var body: some View {
    VStack(spacing: 0) {
      if let project = store.projects.first(where: { $0.dir == selection.dir }) {
        header(project).measured()
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(project.sessions) { row(project, $0) }
          }
          .padding(12)
          .measured()
        }
      }
    }
    .frame(width: Layout.detailWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .onPreferenceChange(HeightKey.self) { onHeight($0 + 1) }
  }

  private func header(_ project: Project) -> some View {
    let count = counts(project, store.now)
    return HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Circle().fill(projectColor(project, store.prefs)).frame(width: 9, height: 9)
          Text(project.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        }
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
      }
      .controlSize(.small)
      .help(project.path ?? project.dir)
    }
    .padding(12)
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

/// One project: name, how many sessions are active, last activity.
private struct ProjectTile: View {
  let name: String
  let color: Color
  let working: String?
  let waiting: String?
  let sessions: String
  let time: String
  let selected: Bool
  let help: String
  let openWindowHelp: String
  let action: () -> Void
  let openWindow: () -> Void
  @State private var hover = false
  @State private var arrowHover = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Circle().fill(color).frame(width: 8, height: 8)
          Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          // Room for the "open window" button, which lies on top of the tile.
          Spacer(minLength: 20)
        }
        HStack(spacing: 8) {
          if let working { StatusCount(text: working, status: .working) }
          if let waiting { StatusCount(text: waiting, status: .waiting) }
          if working == nil && waiting == nil {
            Text(sessions).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .font(.system(size: 11))
        Text(time).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10).fill(color.opacity(selected ? 0.26 : hover ? 0.20 : 0.12)))
      .overlay(
        RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(help)
    // The arrow jumps straight into the project's VS Code window.
    .overlay(alignment: .topTrailing) {
      Button(action: openWindow) {
        Image(systemName: "arrow.up.forward.app")
          .font(.system(size: 13))
          .foregroundStyle(arrowHover ? Color.primary : Color.secondary)
          .frame(width: 28, height: 28)
          .background(
            RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(arrowHover ? 0.12 : 0)))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { arrowHover = $0 }
      .help(openWindowHelp)
      .padding(4)
    }
  }
}

/// Compact card: title and time on the first line, one line of context below.
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
                  .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.22)))
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
        RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover ? 0.11 : 0.045)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(excerpt.isEmpty ? title : title + "\n\n" + excerpt)
  }
}
