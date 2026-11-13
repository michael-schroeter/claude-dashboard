// Reads Claude Code session files (~/.claude/projects/<folder>/<id>.jsonl).
// Local and read-only. This is a port of lib/sessions.js – keep the two in sync
// when the file format changes.

import Foundation

struct Session: Identifiable, Equatable {
  let id: String
  let cwd: String?
  let title: String
  let excerpt: String
  let lastTs: Double  // milliseconds since 1970, like in the extension
  let openTurn: Bool
}

struct Project: Identifiable, Equatable {
  let dir: String
  let path: String?
  let name: String
  let missing: Bool
  let lastTs: Double
  let sessions: [Session]
  var id: String { dir }
}

private let headSteps = [64 * 1024, 1024 * 1024]
private let tailSteps = [256 * 1024, 2 * 1024 * 1024]
private let excerptMax = 420
private let titleMax = 90

private func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
  // Patterns are constants, so a failure is a programming error.
  try! NSRegularExpression(pattern: pattern, options: options)
}

private extension String {
  func replacing(_ rx: NSRegularExpression, with template: String) -> String {
    rx.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
  }
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private let rxSpace = regex("\\s+")
private let rxCode = regex("```[\\s\\S]*?(```|$)")
private let rxLink = regex("\\[([^\\]]+)\\]\\([^)]*\\)")
private let rxLead = regex("^\\s{0,3}(#{1,6}|[-*+]|\\d+\\.)\\s+", .anchorsMatchLines)
private let rxRule = regex("^\\s*\\|?[-:| ]{3,}\\|?\\s*$", .anchorsMatchLines)
private let rxMarks = regex("[*_`|]")
private let rxAttachment = regex("^\\{\"parentUuid\":[^,]{0,60},\"isSidechain\":(?:true|false),\"attachment\":")

private let typePrefix = Array("{\"type\":\"".utf8)
private let parentPrefix = Array("{\"parentUuid\":".utf8)
private let keptTypes = ["ai-title\"", "last-prompt\"", "user\"", "assistant\""].map { Array($0.utf8) }

// Don't even parse the large lines we don't care about.
private func skipLine(_ line: Data) -> Bool {
  if line.starts(with: typePrefix) {
    let rest = line.dropFirst(typePrefix.count)
    return !keptTypes.contains { rest.starts(with: $0) }
  }
  if line.starts(with: parentPrefix) {
    let head = String(decoding: line.prefix(200), as: UTF8.self)
    return rxAttachment.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) != nil
  }
  return false
}

private func readRange(_ file: String, start: UInt64, length: Int) -> Data {
  guard let handle = FileHandle(forReadingAtPath: file) else { return Data() }
  defer { try? handle.close() }
  do {
    try handle.seek(toOffset: start)
    return try handle.read(upToCount: length) ?? Data()
  } catch {
    return Data()
  }
}

private func parseLines(_ data: Data, dropFirst: Bool, dropLast: Bool) -> [[String: Any]] {
  var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
  if dropFirst, !lines.isEmpty { lines.removeFirst() }
  if dropLast, !lines.isEmpty { lines.removeLast() }
  var entries: [[String: Any]] = []
  for line in lines {
    if line.count < 2 || skipLine(line) { continue }
    // Incomplete lines (file is being written) fail to parse and are ignored.
    if let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
      entries.append(entry)
    }
  }
  return entries
}

// Text of a message without injected blocks (<system-reminder>, <ide_selection>, …).
private func messageText(_ entry: [String: Any]) -> String {
  let content = (entry["message"] as? [String: Any])?["content"]
  if let text = content as? String {
    let trimmed = text.trimmed
    return trimmed.hasPrefix("<") ? "" : trimmed
  }
  guard let blocks = content as? [Any] else { return "" }
  var parts: [String] = []
  for case let block as [String: Any] in blocks {
    guard block["type"] as? String == "text", let raw = block["text"] as? String else { continue }
    let text = raw.trimmed
    if text.isEmpty || text.hasPrefix("<") { continue }
    parts.append(text)
  }
  return parts.joined(separator: "\n\n")
}

private func flag(_ entry: [String: Any], _ key: String) -> Bool {
  entry[key] as? Bool ?? false
}

private func isHumanPrompt(_ entry: [String: Any]) -> Bool {
  entry["type"] as? String == "user" && !flag(entry, "isMeta") && !flag(entry, "isSidechain")
    && !messageText(entry).isEmpty
}

private func oneLine(_ text: String, _ max: Int) -> String {
  let flat = text.replacing(rxSpace, with: " ").trimmed
  guard flat.count > max else { return flat }
  var cut = String(flat.prefix(max - 1))
  while let last = cut.last, last.isWhitespace { cut.removeLast() }
  return cut + "…"
}

// Strip Markdown roughly so the excerpt looks calm.
private func plainExcerpt(_ text: String) -> String {
  let plain = text
    .replacing(rxCode, with: " ")
    .replacing(rxLink, with: "$1")
    .replacing(rxLead, with: "")
    .replacing(rxRule, with: " ")
    .replacing(rxMarks, with: "")
  return oneLine(plain, excerptMax)
}

private let isoFraction: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()
private let isoPlain = ISO8601DateFormatter()

private func parseTimestamp(_ value: Any?) -> Double {
  guard let text = value as? String else { return 0 }
  guard let date = isoFraction.date(from: text) ?? isoPlain.date(from: text) else { return 0 }
  return date.timeIntervalSince1970 * 1000
}

private func readSession(_ file: String, size: Int, mtimeMs: Double) -> Session {
  var cwd: String?
  var title: String?
  var firstPrompt: String?
  var lastPrompt: String?
  var excerpt: String?
  var lastTs = 0.0
  var openTurn = false

  // Head: working folder and the user's first message.
  for step in headSteps {
    let length = min(step, size)
    let entries = parseLines(readRange(file, start: 0, length: length), dropFirst: false, dropLast: length < size)
    for entry in entries {
      if cwd == nil, let value = entry["cwd"] as? String { cwd = value }
      if firstPrompt == nil, isHumanPrompt(entry) { firstPrompt = messageText(entry) }
      if cwd != nil && firstPrompt != nil { break }
    }
    if (cwd != nil && firstPrompt != nil) || length >= size { break }
  }

  // Tail: title, Claude's last reply, last activity.
  for step in tailSteps {
    let length = min(step, size)
    let entries = parseLines(
      readRange(file, start: UInt64(size - length), length: length), dropFirst: length < size, dropLast: false)
    var lastMessage: [String: Any]?
    for entry in entries {
      let type = entry["type"] as? String
      if type == "ai-title", let value = entry["aiTitle"] as? String {
        title = value
      } else if type == "last-prompt", let value = entry["lastPrompt"] as? String {
        lastPrompt = value
      } else if (type == "user" || type == "assistant") && !flag(entry, "isSidechain") {
        if cwd == nil, let value = entry["cwd"] as? String { cwd = value }
        let ts = parseTimestamp(entry["timestamp"])
        if ts > lastTs { lastTs = ts }
        lastMessage = entry
        if type == "assistant" {
          let text = messageText(entry)
          if !text.isEmpty { excerpt = text }
        }
      }
    }
    if let last = lastMessage {
      let type = last["type"] as? String
      let finished =
        type == "assistant" && (last["message"] as? [String: Any])?["stop_reason"] as? String == "end_turn"
      // Interrupted by the user: the turn is over even without a reply from Claude.
      let interrupted = type == "user" && messageText(last).hasPrefix("[Request interrupted")
      openTurn = !finished && !interrupted
    }
    if excerpt != nil || length >= size { break }
  }

  if lastTs == 0 { lastTs = mtimeMs }
  let id = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
  return Session(
    id: id,
    cwd: cwd,
    title: oneLine(title ?? firstPrompt ?? lastPrompt ?? "", titleMax),
    excerpt: excerpt.map(plainExcerpt) ?? "",
    lastTs: lastTs,
    openTurn: openTurn)
}

private func fileStat(_ path: String) -> stat? {
  var info = stat()
  return stat(path, &info) == 0 ? info : nil
}

private func isKind(_ info: stat, _ kind: mode_t) -> Bool {
  (info.st_mode & S_IFMT) == kind
}

// A folder only counts as missing when it is really gone. Folders macOS will not
// let us look at (e.g. ~/Documents without permission) are assumed to exist.
private func folderMissing(_ path: String) -> Bool {
  if let info = fileStat(path) { return !isKind(info, S_IFDIR) }
  return errno == ENOENT || errno == ENOTDIR
}

/// Scans all projects. Remembers files by size and modification time so only
/// changed files are read again. Use from one queue only.
final class SessionScanner {
  private struct Cached {
    let size: Int
    let mtimeMs: Double
    let session: Session
  }
  private var cache: [String: Cached] = [:]

  /// All projects, most recent first.
  func scan(root: String) -> [Project] {
    let files = FileManager.default
    guard let dirs = try? files.contentsOfDirectory(atPath: root) else { return [] }
    var seen = Set<String>()
    var projects: [Project] = []

    for dir in dirs {
      let dirPath = (root as NSString).appendingPathComponent(dir)
      guard let dirInfo = fileStat(dirPath), isKind(dirInfo, S_IFDIR),
        let names = try? files.contentsOfDirectory(atPath: dirPath)
      else { continue }

      var sessions: [Session] = []
      for name in names where name.hasSuffix(".jsonl") {
        let file = (dirPath as NSString).appendingPathComponent(name)
        guard let info = fileStat(file), isKind(info, S_IFREG), info.st_size > 0 else { continue }
        let size = Int(info.st_size)
        let mtimeMs = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1e6
        seen.insert(file)
        if let cached = cache[file], cached.size == size, cached.mtimeMs == mtimeMs {
          sessions.append(cached.session)
          continue
        }
        let session = readSession(file, size: size, mtimeMs: mtimeMs)
        cache[file] = Cached(size: size, mtimeMs: mtimeMs, session: session)
        sessions.append(session)
      }
      if sessions.isEmpty { continue }
      sessions.sort { $0.lastTs > $1.lastTs }
      let path = sessions.first { $0.cwd != nil }?.cwd
      var name = dir
      if let path {
        let base = (path as NSString).lastPathComponent
        name = base.isEmpty ? path : base
      }
      projects.append(
        Project(
          dir: dir,
          path: path,
          name: name,
          missing: path.map(folderMissing) ?? true,
          lastTs: sessions[0].lastTs,
          sessions: sessions))
    }

    cache = cache.filter { seen.contains($0.key) }
    projects.sort { $0.lastTs > $1.lastTs }
    return projects
  }
}
