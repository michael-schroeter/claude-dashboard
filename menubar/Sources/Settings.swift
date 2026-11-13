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
  /// Room around the cards: the blurred backdrop reaches a little beyond them.
  static let padding: CGFloat = 14
  static let defaultIcon = "folder.fill"

  @Published var columns: Int {
    didSet { defaults?.set(columns, forKey: "columns") }
  }
  /// Project folder names in the order the user arranged them. Empty means
  /// "most recently used first".
  @Published private(set) var order: [String] {
    didSet { defaults?.set(order, forKey: "order") }
  }
  /// SF Symbol name per project folder name.
  @Published private(set) var icons: [String: String] {
    didSet { defaults?.set(icons, forKey: "icons") }
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
  }

  func icon(_ dir: String) -> String {
    icons[dir] ?? Settings.defaultIcon
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

  /// Projects the user has not arranged yet (new ones) come first.
  func ordered(_ projects: [Project]) -> [Project] {
    guard !order.isEmpty else { return projects }
    let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let arranged = projects.filter { index[$0.dir] != nil }.sorted { index[$0.dir]! < index[$1.dir]! }
    return projects.filter { index[$0.dir] == nil } + arranged
  }

  /// Puts `dir` where `target` is. `shown` is the order currently on screen.
  func move(_ dir: String, onto target: String, shown: [String]) {
    var list = shown
    guard let from = list.firstIndex(of: dir), let to = list.firstIndex(of: target), from != to else { return }
    list.insert(list.remove(at: from), at: to)
    order = list
  }

  /// Moves `dir` one place back (-1) or forward (+1).
  func shift(_ dir: String, by step: Int, shown: [String]) {
    var list = shown
    guard let from = list.firstIndex(of: dir), list.indices.contains(from + step) else { return }
    list.swapAt(from, from + step)
    order = list
  }

  func resetOrder() {
    order = []
  }
}
