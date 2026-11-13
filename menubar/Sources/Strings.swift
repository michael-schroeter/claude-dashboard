// Strings shown by the menu bar app. English is the default; German is used
// when macOS runs in German. Mirrors the wording of the VS Code dashboard.

import Foundation

struct Strings {
  let german: Bool

  static let current = Strings(
    german: (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("de"))

  private func pick(_ en: String, _ de: String) -> String { german ? de : en }

  var heading: String { pick("Claude Projects", "Claude Projekte") }
  var projectsTitle: String { pick("Projects", "Projekte") }
  var sessionsTitle: String { pick("Sessions", "Sitzungen") }
  var edit: String { pick("Edit", "Bearbeiten") }
  var done: String { pick("Done", "Fertig") }
  var editHint: String { pick("drag to arrange", "zum Anordnen ziehen") }
  var archive: String { pick("Archive", "Archivieren") }
  var restore: String { pick("Restore", "Wiederherstellen") }
  var moveBack: String { pick("Move back", "Nach vorn") }
  var moveForward: String { pick("Move forward", "Nach hinten") }
  var columns: String { pick("Columns", "Spalten") }
  var resetOrder: String { pick("Sort by last use", "Nach letzter Nutzung sortieren") }
  var chooseSymbol: String { pick("Choose symbol and color", "Symbol und Farbe wählen") }
  func symbolFor(_ name: String) -> String {
    pick("Symbol and color for “\(name)”", "Symbol und Farbe für „\(name)“")
  }
  var enlarge: String { pick("Large tile", "Große Kachel") }
  var shrink: String { pick("Small tile", "Kleine Kachel") }
  var search: String { pick("Search", "Suchen") }
  var loading: String { pick("Loading…", "Lädt …") }
  var now: String { pick("Now", "Aktuell") }
  var nowRecent: String { pick("recently used", "zuletzt benutzt") }
  var untitled: String { pick("Untitled", "Ohne Titel") }
  var less: String { pick("Show less", "Weniger") }
  var openWindow: String { pick("Open window", "Fenster öffnen") }
  var emptyTitle: String { pick("No sessions yet", "Noch keine Sitzungen") }
  var emptyText: String {
    pick(
      "As soon as you work on a project with Claude Code, it shows up here.",
      "Sobald du in einem Projekt mit Claude Code arbeitest, erscheint es hier.")
  }
  var noMatchTitle: String { pick("Nothing found", "Nichts gefunden") }
  var loginItem: String { pick("Start at login", "Beim Anmelden starten") }
  var quit: String { pick("Quit Claude Dashboard", "Claude Dashboard beenden") }
  var settings: String { pick("Settings", "Einstellungen") }
  var tooltip: String {
    pick("All Claude Code sessions across all projects", "Alle Claude-Code-Sitzungen aller Projekte")
  }
  var codeMissing: String {
    pick("Visual Studio Code was not found.", "Visual Studio Code wurde nicht gefunden.")
  }

  func noMatchText(_ query: String) -> String {
    pick("No session matches “\(query)”.", "Keine Sitzung passt zu „\(query)“.")
  }
  func all(_ n: Int) -> String { pick("All \(n)", "Alle \(n)") }
  func projects(_ n: Int) -> String {
    german ? "\(n) \(n == 1 ? "Projekt" : "Projekte")" : "\(n) \(n == 1 ? "project" : "projects")"
  }
  func sessions(_ n: Int) -> String {
    german ? "\(n) \(n == 1 ? "Sitzung" : "Sitzungen")" : "\(n) \(n == 1 ? "session" : "sessions")"
  }
  func workingCount(_ n: Int) -> String { pick("\(n) working", "\(n) arbeitet") }
  func waitingCount(_ n: Int) -> String {
    german ? "\(n) \(n == 1 ? "wartet" : "warten")" : "\(n) waiting"
  }
  func nowWorking(_ n: Int) -> String {
    german
      ? "\(n) \(n == 1 ? "Sitzung arbeitet" : "Sitzungen arbeiten")"
      : "\(n) \(n == 1 ? "session working" : "sessions working")"
  }
  func archiveToggle(_ n: Int) -> String {
    pick("Archive · \(projects(n))", "Archiv · \(projects(n))")
  }
  func status(_ status: Status) -> String {
    switch status {
    case .working: return pick("working", "arbeitet")
    case .waiting: return pick("waiting for you", "wartet auf dich")
    case .done: return pick("done", "fertig")
    }
  }

  func relTime(_ ts: Double, now: Double) -> String {
    let minutes = Int(max(0, now - ts) / 60000)
    if minutes < 1 { return pick("just now", "gerade eben") }
    if minutes < 60 { return pick("\(minutes) min ago", "vor \(minutes) Min.") }
    let hours = minutes / 60
    if hours < 24 { return pick("\(hours) h ago", "vor \(hours) Std.") }
    let days = hours / 24
    if days == 1 { return pick("yesterday", "gestern") }
    if days < 7 { return pick("\(days) days ago", "vor \(days) Tagen") }
    let date = Date(timeIntervalSince1970: ts / 1000)
    let calendar = Calendar.current
    let sameYear =
      calendar.component(.year, from: date)
      == calendar.component(.year, from: Date(timeIntervalSince1970: now / 1000))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: german ? "de_DE" : "en_US")
    formatter.setLocalizedDateFormatFromTemplate(sameYear ? "dMMM" : "dMMMy")
    return formatter.string(from: date)
  }
}
