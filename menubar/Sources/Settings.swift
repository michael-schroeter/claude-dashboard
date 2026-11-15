// What the user sets up in the menu bar app itself: how many columns of tiles
// the panel has and the order of the tiles. Kept in the app's own preferences
// (the VS Code dashboard has no use for them). Colors and the archive are
// shared with the extension instead, see Prefs in Store.swift.

import SwiftUI

final class Settings: ObservableObject {
  static let columnRange = 2...5
  static let tileWidth: CGFloat = 190
  /// Distance between tiles and cards.
  static let spacing: CGFloat = 10
  /// Room around the cards, so their glass edges and shadows are not cut off.
  static let padding: CGFloat = 8
  static let defaultIcon = "folder.fill"

  @Published var columns: Int {
    didSet { defaults?.set(columns, forKey: "columns") }
  }
  /// Project folder names in the order of the tiles.
  @Published private(set) var order: [String] {
    didSet { defaults?.set(order, forKey: "order") }
  }
  /// SF Symbol name per project folder name.
  @Published private(set) var icons: [String: String] {
    didSet { defaults?.set(icons, forKey: "icons") }
  }
  /// Own titles for projects, by folder name. Without one, the tile shows the
  /// folder's name. Copied into the extension's prefs.json so that the VS Code
  /// dashboard shows the same titles.
  @Published private(set) var titles: [String: String] {
    didSet {
      defaults?.set(titles, forKey: "titles")
      shareTitlesSoon()
    }
  }
  private var shareTitles: DispatchWorkItem?

  /// Where the folder chooser for a new project starts.
  @Published var projectsFolder: String {
    didSet { defaults?.set(projectsFolder, forKey: "projectsFolder") }
  }

  /// Projects whose tile is two rows tall and shows the latest message.
  @Published private(set) var tall: Set<String> {
    didSet { defaults?.set(tall.sorted(), forKey: "tall") }
  }
  /// Edit mode: arrange and archive tiles, choose symbols. Not remembered across openings.
  @Published var editing = false {
    didSet { if !editing { pickingIcon = nil } }
  }
  /// Folder name of the project whose symbol is being chosen.
  @Published var pickingIcon: String?

  private let defaults: UserDefaults?

  /// `persistent: false` keeps everything in memory (demo mode).
  init(persistent: Bool) {
    defaults = persistent ? UserDefaults.standard : nil
    let stored = defaults?.integer(forKey: "columns") ?? 0
    columns = Settings.columnRange.contains(stored) ? stored : 2
    order = defaults?.stringArray(forKey: "order") ?? []
    icons = defaults?.dictionary(forKey: "icons") as? [String: String] ?? [:]
    tall = Set(defaults?.stringArray(forKey: "tall") ?? [])
    let usual = Paths.home + "/Claude Projects"
    projectsFolder =
      defaults?.string(forKey: "projectsFolder")
      ?? (FileManager.default.fileExists(atPath: usual) ? usual : Paths.home)
    titles = defaults?.dictionary(forKey: "titles") as? [String: String] ?? [:]
    positions = defaults?.dictionary(forKey: "positions") as? [String: [String: [Int]]] ?? [:]
  }

  func icon(_ dir: String) -> String {
    icons[dir] ?? Settings.defaultIcon
  }

  func title(_ project: Project) -> String {
    let own = (titles[project.dir] ?? "").trimmingCharacters(in: .whitespaces)
    return own.isEmpty ? project.name : own
  }

  /// An empty title brings back the folder's name.
  func setTitle(_ dir: String, _ text: String) {
    if text.isEmpty { titles.removeValue(forKey: dir) } else { titles[dir] = String(text.prefix(60)) }
  }

  // Not on every keystroke: wait until typing pauses.
  private func shareTitlesSoon() {
    guard defaults != nil else { return }
    shareTitles?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      var names: [String: String] = [:]
      for (dir, text) in self.titles {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { names[dir] = trimmed }
      }
      Prefs.saveNames(names)
    }
    shareTitles = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
  }

  func toggleTall(_ dir: String) {
    if tall.contains(dir) { tall.remove(dir) } else { tall.insert(dir) }
  }

  func setIcon(_ dir: String, _ symbol: String) {
    icons[dir] = symbol
  }

  var mainWidth: CGFloat {
    2 * Settings.padding + CGFloat(columns) * Settings.tileWidth + CGFloat(columns - 1) * Settings.spacing
  }

  /// Tiles keep their place: the order is remembered, and projects that are
  /// new are added at the end instead of moving the others.
  func adopt(_ dirs: [String]) {
    let known = Set(order)
    let new = dirs.filter { !known.contains($0) }
    if !new.isEmpty { order += new }
  }

  func ordered(_ projects: [Project]) -> [Project] {
    let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let arranged = projects.filter { index[$0.dir] != nil }.sorted { index[$0.dir]! < index[$1.dir]! }
    return arranged + projects.filter { index[$0.dir] == nil }
  }

  /// Back to "most recently used first", as a new fixed order. `dirs` is the
  /// current list of projects, most recent first. Also forgets where the
  /// tiles were placed, so they close up again.
  func resetOrder(_ dirs: [String]) {
    order = dirs
    positions = [:]
  }

  // MARK: Free placement

  /// A place in the tile grid.
  struct Cell: Hashable {
    var col: Int
    var row: Int
  }

  /// Where the user put each tile, per number of columns (key "\(columns)"),
  /// as folder name → [column, row]. Gaps between tiles stay. A layout for
  /// 2 columns does not fit 4, so each column count keeps its own.
  @Published private(set) var positions: [String: [String: [Int]]] {
    didSet { defaults?.set(positions, forKey: "positions") }
  }

  private func index(_ cell: Cell) -> Int { cell.row * columns + cell.col }
  private func cell(_ index: Int) -> Cell { Cell(col: index % columns, row: index / columns) }

  /// The cells a tile covers: one, or two for a large tile.
  func footprint(_ dir: String, at cell: Cell) -> [Cell] {
    tall.contains(dir) ? [cell, Cell(col: cell.col, row: cell.row + 1)] : [cell]
  }

  private func occupied(_ cells: [String: Cell], except: Set<String> = []) -> Set<Cell> {
    var used = Set<Cell>()
    for (dir, cell) in cells where !except.contains(dir) { used.formUnion(footprint(dir, at: cell)) }
    return used
  }

  private func fits(_ dir: String, at cell: Cell, _ used: Set<Cell>) -> Bool {
    cell.col >= 0 && cell.col < columns && cell.row >= 0 && footprint(dir, at: cell).allSatisfy { !used.contains($0) }
  }

  /// First cell from `start` on (in reading order) where `dir` fits.
  private func firstFree(_ dir: String, from start: Int, _ used: Set<Cell>) -> Cell {
    var i = max(0, start)
    while !fits(dir, at: cell(i), used) { i += 1 }
    return cell(i)
  }

  /// Where each tile goes. `free: true` uses the places the user chose; tiles
  /// without a place (new projects, or ones whose place is taken) come after
  /// the last placed tile, so gaps the user left stay empty. `free: false`
  /// packs the tiles into the first free places (archive, search results).
  /// `add` is the place for the "new project" tile.
  func arrange(_ dirs: [String], free: Bool) -> (cells: [String: Cell], rows: Int, add: Cell) {
    let saved = free ? (positions[String(columns)] ?? [:]) : [:]
    var cells: [String: Cell] = [:]
    var used = Set<Cell>()
    var rest: [String] = []
    for dir in dirs {
      if let pair = saved[dir], pair.count == 2, fits(dir, at: Cell(col: pair[0], row: pair[1]), used) {
        let place = Cell(col: pair[0], row: pair[1])
        cells[dir] = place
        used.formUnion(footprint(dir, at: place))
      } else {
        rest.append(dir)
      }
    }
    let start = free ? (used.map(index).max().map { $0 + 1 } ?? 0) : 0
    for dir in rest {
      let place = firstFree(dir, from: start, used)
      cells[dir] = place
      used.formUnion(footprint(dir, at: place))
    }
    let addStart = free ? (used.map(index).max().map { $0 + 1 } ?? 0) : 0
    var addIndex = addStart
    while used.contains(cell(addIndex)) { addIndex += 1 }
    let add = cell(addIndex)
    let rows = (used.map(\.row).max() ?? -1) + 1
    return (cells, rows, add)
  }

  /// The places of all tiles if `dir` were put at `target`, without saving
  /// (shown while a tile is dragged). Tiles that are in the way go to the
  /// place `dir` came from if they fit there, otherwise to the next free place.
  /// `dirs` are all tiles of the grid (the visible projects).
  func cells(moving dir: String, to target: Cell, among dirs: [String]) -> [String: Cell]? {
    var cells = arrange(dirs, free: true).cells
    guard let from = cells[dir], target != from, target.col >= 0, target.col < columns, target.row >= 0 else { return nil }
    cells[dir] = target
    makeRoom(for: dir, in: &cells, hint: from)
    return cells
  }

  /// Puts `dir` at `target` and remembers the new places.
  func move(_ dir: String, to target: Cell, among dirs: [String]) {
    if let cells = cells(moving: dir, to: target, among: dirs) { save(cells) }
  }

  /// Moves `dir` one place back (-1) or forward (+1) in reading order and
  /// swaps it with the tile there.
  func shift(_ dir: String, by step: Int, among dirs: [String]) {
    guard let from = arrange(dirs, free: true).cells[dir] else { return }
    let to = index(from) + step
    guard to >= 0 else { return }
    move(dir, to: cell(to), among: dirs)
  }

  /// Small ↔ large. A tile that a growing tile would cover moves out of the way.
  func toggleTall(_ dir: String, among dirs: [String]) {
    var cells = arrange(dirs, free: true).cells
    toggleTall(dir)
    guard tall.contains(dir), let place = cells[dir] else { return }
    makeRoom(for: dir, in: &cells, hint: Cell(col: place.col, row: place.row + 1))
    save(cells)
  }

  private func makeRoom(for dir: String, in cells: inout [String: Cell], hint: Cell) {
    guard let place = cells[dir] else { return }
    let mine = Set(footprint(dir, at: place))
    let inTheWay = cells.filter { $0.key != dir && !mine.isDisjoint(with: footprint($0.key, at: $0.value)) }
      .sorted { index($0.value) < index($1.value) }
      .map(\.key)
    guard !inTheWay.isEmpty else { return }
    for other in inTheWay { cells.removeValue(forKey: other) }
    for other in inTheWay {
      let used = occupied(cells)
      cells[other] = fits(other, at: hint, used) ? hint : firstFree(other, from: index(hint), used)
    }
  }

  /// Puts one tile at a place without moving others (demo mode).
  func pin(_ dir: String, at cell: Cell) {
    positions[String(columns), default: [:]][dir] = [cell.col, cell.row]
  }

  /// Remembers the places of all tiles shown, keeping those of hidden
  /// (archived) projects so they come back to their place.
  private func save(_ cells: [String: Cell]) {
    var layout = positions[String(columns)] ?? [:]
    for (dir, cell) in cells { layout[dir] = [cell.col, cell.row] }
    positions[String(columns)] = layout
  }
}
