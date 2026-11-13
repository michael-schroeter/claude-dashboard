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

/// What is known about a session so far. Kept per file so that later only the
/// lines appended since the last look have to be read.
private struct ParseState {
  var cwd: String?
  var title: String?
  var firstPrompt: String?
  var lastPrompt: String?
  var excerpt = ""  // Claude's last reply, already stripped
  var lastTs = 0.0
  var openTurn = false
  /// Bytes of the file that are accounted for (up to the last complete line).
  var offset = 0
}

/// Applies entries from the end of the file, oldest first: title, Claude's
/// last reply, last activity. Returns whether a reply from Claude is known.
@discardableResult
private func applyTail(_ entries: [[String: Any]], to state: inout ParseState) -> Bool {
  var lastMessage: [String: Any]?
  var reply: String?
  for entry in entries {
    let type = entry["type"] as? String
    if type == "ai-title", let value = entry["aiTitle"] as? String {
      state.title = value
    } else if type == "last-prompt", let value = entry["lastPrompt"] as? String {
      state.lastPrompt = value
    } else if (type == "user" || type == "assistant") && !flag(entry, "isSidechain") {
      if state.cwd == nil, let value = entry["cwd"] as? String { state.cwd = value }
      let ts = parseTimestamp(entry["timestamp"])
      if ts > state.lastTs { state.lastTs = ts }
      lastMessage = entry
      if type == "assistant" {
        let text = messageText(entry)
        if !text.isEmpty { reply = text }
      }
    }
  }
  if let reply { state.excerpt = plainExcerpt(reply) }
  if let last = lastMessage {
    let type = last["type"] as? String
    let finished =
      type == "assistant" && (last["message"] as? [String: Any])?["stop_reason"] as? String == "end_turn"
    // Interrupted by the user: the turn is over even without a reply from Claude.
    let interrupted = type == "user" && messageText(last).hasPrefix("[Request interrupted")
    state.openTurn = !finished && !interrupted
  }
  return !state.excerpt.isEmpty
}

/// Length of `data` up to and including its last line break.
private func completeLength(_ data: Data) -> Int {
  guard let index = data.lastIndex(of: 0x0A) else { return 0 }
  return index - data.startIndex + 1
}

/// First look at a file: its head and as much of its tail as needed.
private func readSession(_ file: String, size: Int) -> ParseState {
  var state = ParseState()

  // Head: working folder and the user's first message.
  for step in headSteps {
    let length = min(step, size)
    let entries = parseLines(readRange(file, start: 0, length: length), dropFirst: false, dropLast: length < size)
    for entry in entries {
      if state.cwd == nil, let value = entry["cwd"] as? String { state.cwd = value }
      if state.firstPrompt == nil, isHumanPrompt(entry) { state.firstPrompt = messageText(entry) }
      if state.cwd != nil && state.firstPrompt != nil { break }
    }
    if (state.cwd != nil && state.firstPrompt != nil) || length >= size { break }
  }

  // Tail: title, Claude's last reply, last activity.
  for step in tailSteps {
    let length = min(step, size)
    let data = readRange(file, start: UInt64(size - length), length: length)
    // A last line that is still being written is read next time.
    state.offset = size - data.count + completeLength(data)
    let found = applyTail(parseLines(data, dropFirst: length < size, dropLast: false), to: &state)
    if found || length >= size { break }
  }
  return state
}

/// Later looks: only the lines appended since then.
private func readAppended(_ file: String, size: Int, state: inout ParseState) {
  let data = readRange(file, start: UInt64(state.offset), length: size - state.offset)
  let complete = completeLength(data)
  guard complete > 0 else { return }
  applyTail(parseLines(data.prefix(complete), dropFirst: false, dropLast: false), to: &state)
  state.offset += complete
}

private func makeSession(_ file: String, _ state: ParseState, mtimeMs: Double) -> Session {
  let id = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
  return Session(
    id: id,
    cwd: state.cwd,
    title: oneLine(state.title ?? state.firstPrompt ?? state.lastPrompt ?? "", titleMax),
    excerpt: state.excerpt,
    lastTs: state.lastTs == 0 ? mtimeMs : state.lastTs,
    openTurn: state.openTurn)
}

/// Above this many new bytes a file is read from scratch instead.
private let appendMax = 2 * 1024 * 1024

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

/// Scans all projects. Remembers files by size and modification time: unchanged
/// files are not opened at all, and of a file that grew only the new lines are
/// read. Use from one queue only.
final class SessionScanner {
  private struct Cached {
    let size: Int
    let mtimeMs: Double
    let state: ParseState
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
        var state = ParseState()
        // Release the read buffers after every file instead of at the end of the scan.
        autoreleasepool {
          if let cached = cache[file], size > cached.size, size - cached.state.offset <= appendMax {
            // Session files only grow, so the known part does not change.
            state = cached.state
            readAppended(file, size: size, state: &state)
          } else {
            state = readSession(file, size: size)
          }
        }
        let session = makeSession(file, state, mtimeMs: mtimeMs)
        cache[file] = Cached(size: size, mtimeMs: mtimeMs, state: state, session: session)
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
