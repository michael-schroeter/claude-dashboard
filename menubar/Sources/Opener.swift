// Jumps into VS Code: brings a project's window to the front and, for a session,
// asks the Claude Dashboard extension in that window to open it.

import AppKit

enum Opener {
  private static var codeURL: URL? {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
      return url
    }
    let fallback = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
    return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
  }

  /// If the folder is already open in a window, VS Code focuses that window.
  @discardableResult
  static func openProject(_ project: Project) -> Bool {
    guard let path = project.path, let code = codeURL else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: code,
      configuration: configuration)
    return true
  }

  /// One window cannot reach into another, and neither can this app. So it drops
  /// the same small request file the extension uses itself; the instance whose
  /// workspace folder matches opens the session (see SessionOpener in extension.js).
  @discardableResult
  static func openSession(_ project: Project, _ session: Session) -> Bool {
    guard let path = project.path else { return false }
    let dir = Paths.extensionStorage
    var isDir: ObjCBool = false
    // Without the extension only the window opens.
    if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
      let request: [String: Any] = [
        "folder": path,
        "sessionId": session.id,
        "ts": Int(Date().timeIntervalSince1970 * 1000),
      ]
      if let data = try? JSONSerialization.data(withJSONObject: request) {
        try? data.write(to: URL(fileURLWithPath: dir + "/open-request.json"))
      }
    }
    return openProject(project)
  }
}
