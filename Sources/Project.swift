// A Workshop upload project: ~/Zomboid/Workshop/<folder>/ with workshop.txt,
// preview.png and Contents/. Reading, writing and checking follow the game's
// own uploader (zombie.core.znet.SteamWorkshopItem) so results match it.

import AppKit
import Foundation

enum Visibility: Int32, CaseIterable, Identifiable, Codable {
  case `public` = 0, friendsOnly = 1, `private` = 2, unlisted = 3
  var id: Int32 { rawValue }
  /// The word workshop.txt uses.
  var word: String {
    switch self {
    case .public: return "public"
    case .friendsOnly: return "friendsOnly"
    case .private: return "private"
    case .unlisted: return "unlisted"
    }
  }
  var label: String {
    switch self {
    case .public: return "Public"
    case .friendsOnly: return "Friends only"
    case .private: return "Private"
    case .unlisted: return "Unlisted"
    }
  }
  /// Same mapping as the game: anything unknown counts as public.
  init(word: String) {
    self = Visibility.allCases.first { $0.word == word } ?? .public
  }
}

/// The text fields of a Workshop page.
struct PageText: Codable, Equatable {
  var title: String
  var description: String
  var tags: [String]
  var visibility: Visibility

  /// Compare the way Steam stores them: line endings, trailing spaces, tag
  /// order and tag case do not count.
  func normalized() -> PageText {
    PageText(
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      description: stripIDBlocks(description)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines),
      tags: tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }.sorted(),
      visibility: visibility)
  }

  func same(as other: PageText) -> Bool { normalized() == other.normalized() }

  /// Names of the fields that differ.
  func differences(from other: PageText) -> [String] {
    let a = normalized(), b = other.normalized()
    var out: [String] = []
    if a.title != b.title { out.append("title") }
    if a.description != b.description { out.append("description") }
    if a.tags != b.tags { out.append("tags") }
    if a.visibility != b.visibility { out.append("visibility") }
    return out
  }
}

/// The game appends "Workshop ID / Mod ID / Map Folder" lines to the
/// description on every upload. Remove every copy of that block from the end.
func stripIDBlocks(_ text: String) -> String {
  var s = text.replacingOccurrences(of: "\r\n", with: "\n")
  let pattern = "(?:\\n\\n|^)Workshop ID: \\d*(?:\\nMod ID: [^\\n]*)*(?:\\nMap Folder: [^\\n]*)*\\s*$"
  while let range = s.range(of: pattern, options: .regularExpression) {
    s.removeSubrange(range)
  }
  return s
}

func countIDBlocks(_ text: String) -> Int {
  text.components(separatedBy: "Workshop ID: ").count - 1
}

struct CheckResult {
  var errors: [String] = []
  var warnings: [String] = []
  var modIDs: [String] = []
  var mapFolders: [String] = []
}

final class Project: Identifiable {
  let folder: URL
  var id: String { folder.lastPathComponent }
  var workshopID: String?
  var page: PageText

  var workshopTxt: URL { folder.appendingPathComponent("workshop.txt") }
  var contents: URL { folder.appendingPathComponent("Contents") }
  var preview: URL { folder.appendingPathComponent("preview.png") }

  init(folder: URL) {
    self.folder = folder
    page = PageText(title: "", description: "", tags: [], visibility: .public)
    reload()
  }

  /// Same parsing rules as SteamWorkshopItem.readWorkshopTxt.
  func reload() {
    var id: String?, title = "", description = "", tags: [String] = [], visibility = "public"
    var sawDescription = false
    if let text = try? String(contentsOf: workshopTxt, encoding: .utf8) {
      for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
        if line.hasPrefix("id=") {
          let v = String(line.dropFirst(3))
          id = v.isEmpty || UInt64(v) == nil ? nil : v
        } else if line.hasPrefix("description=") {
          if sawDescription { description += "\n" }
          description += String(line.dropFirst(12))
          sawDescription = true
        } else if line.hasPrefix("tags=") {
          tags += line.dropFirst(5).split(separator: ";").map(String.init)
        } else if line.hasPrefix("title=") {
          title = String(line.dropFirst(6))
        } else if line.hasPrefix("visibility=") {
          visibility = String(line.dropFirst(11))
        }
      }
    }
    workshopID = id
    page = PageText(title: title, description: description, tags: tags, visibility: Visibility(word: visibility))
  }

  /// Same format as SteamWorkshopItem.writeWorkshopTxt.
  func write(page newPage: PageText, id newID: String? = nil) throws {
    let id = newID ?? workshopID ?? ""
    try backupWorkshopTxt()
    var lines = ["version=1", "id=\(id)", "title=\(newPage.title)"]
    for line in newPage.description.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
      lines.append("description=\(line)")
    }
    lines.append("tags=" + newPage.tags.joined(separator: ";"))
    lines.append("visibility=\(newPage.visibility.word)")
    try (lines.joined(separator: "\n") + "\n").write(to: workshopTxt, atomically: true, encoding: .utf8)
    reload()
  }

  /// Keeps the previous workshop.txt in
  /// ~/Library/Application Support/Zomboid Workshop Manager/backups/<project>/.
  func backupWorkshopTxt() throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: workshopTxt.path) else { return }
    let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Zomboid Workshop Manager/backups/\(id)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
    try fm.copyItem(at: workshopTxt, to: dir.appendingPathComponent("workshop-\(f.string(from: Date())).txt"))
  }

  /// Description as the game submits it (SteamWorkshopItem.getSubmitDescription).
  func submitDescription(_ check: CheckResult) -> String {
    guard let wid = workshopID else { return page.description }
    var s = page.description
    if !s.isEmpty { s += "\n\n" }
    s += "Workshop ID: \(wid)"
    for m in check.modIDs { s += "\nMod ID: \(m)" }
    for m in check.mapFolders { s += "\nMap Folder: \(m)" }
    return s
  }

  // MARK: the game's upload checks (SteamWorkshopItem.validateContents)

  func check(allowedTags: [String]) -> CheckResult {
    var r = CheckResult()
    let fm = FileManager.default
    func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    func entries(_ u: URL) -> [URL] {
      ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
        .filter { $0.lastPathComponent != ".DS_Store" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // Preview: PNG, at most 1,024,000 bytes, square 256 or 512 px.
    if !fm.fileExists(atPath: preview.path) {
      r.errors.append("preview.png is missing next to workshop.txt.")
    } else {
      let size = (try? fm.attributesOfItem(atPath: preview.path)[.size] as? Int) ?? 0
      if size > 1_024_000 { r.errors.append("preview.png is \(size / 1024) KB. The game allows at most 1000 KB.") }
      if let rep = NSImageRep(contentsOf: preview) {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        if w != h || (w != 256 && w != 512) { r.errors.append("preview.png is \(w)×\(h). It must be 256×256 or 512×512.") }
      } else {
        r.errors.append("preview.png is not a readable PNG.")
      }
    }

    if page.title.trimmingCharacters(in: .whitespaces).isEmpty { r.errors.append("The title is empty.") }
    if page.title == "Mod Template" { r.warnings.append("The game always uploads an item titled \"Mod Template\" as private.") }
    let allowed = Set(allowedTags.map { $0.lowercased() })
    if !allowed.isEmpty {
      for t in page.tags where !allowed.contains(t.lowercased()) {
        r.warnings.append("Tag \"\(t)\" is not in the game's tag list.")
      }
    }
    let blocks = countIDBlocks(page.description)
    if blocks > 0 {
      r.warnings.append("workshop.txt's description already contains \(blocks) \"Workshop ID:\" block(s). The game adds one on every upload, so they pile up on Steam. Use \"Clean description\" to remove them.")
    }

    guard isDir(contents) else {
      r.errors.append("The Contents folder is missing.")
      return r
    }
    let top = entries(contents)
    if top.isEmpty { r.errors.append("The Contents folder is empty.") }
    for item in top {
      guard isDir(item) else {
        r.errors.append("Contents/\(item.lastPathComponent): only folders are allowed directly in Contents.")
        continue
      }
      switch item.lastPathComponent {
      case "buildings", "creative": break
      case "mods":
        let mods = entries(item)
        if mods.isEmpty { r.errors.append("Contents/mods is empty.") }
        for mod in mods {
          guard isDir(mod) else {
            r.errors.append("Contents/mods/\(mod.lastPathComponent): only mod folders are allowed in mods.")
            continue
          }
          var foundInfo = false
          for sub in entries(mod) where isDir(sub) {
            let name = sub.lastPathComponent
            // "common" or a game-version folder such as "42" or "42.12".
            guard name == "common" || name.range(of: "^\\d+(\\.\\d+)*$", options: .regularExpression) != nil else { continue }
            let info = sub.appendingPathComponent("mod.info")
            if fm.fileExists(atPath: info.path) {
              foundInfo = true
              let text = (try? String(contentsOf: info, encoding: .utf8)) ?? ""
              let idLine = text.components(separatedBy: .newlines).first { $0.hasPrefix("id=") }
              let modID = idLine.map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) } ?? ""
              if modID.isEmpty {
                r.errors.append("\(mod.lastPathComponent)/\(name)/mod.info has no id= line.")
              } else if !r.modIDs.contains(modID) {
                r.modIDs.append(modID)
              }
            }
            let maps = sub.appendingPathComponent("media/maps")
            for map in entries(maps) where isDir(map) {
              if fm.fileExists(atPath: map.appendingPathComponent("map.info").path) {
                if !r.mapFolders.contains(map.lastPathComponent) { r.mapFolders.append(map.lastPathComponent) }
              } else {
                r.errors.append("Map folder \(map.lastPathComponent) has no map.info.")
              }
            }
          }
          if !foundInfo {
            r.errors.append("Contents/mods/\(mod.lastPathComponent) has no mod.info in common/ or a version folder like 42/.")
          }
        }
      default:
        r.errors.append("Contents/\(item.lastPathComponent): only buildings/, creative/ and mods/ are allowed in Contents.")
      }
    }

    // Blocked file types (SteamWorkshopItem.validateFileTypes).
    let blocked = [".exe", ".dll", ".bat", ".app", ".dylib", ".sh", ".so", ".zip"]
    if let walker = fm.enumerator(at: contents, includingPropertiesForKeys: [.isDirectoryKey]) {
      for case let u as URL in walker where !isDir(u) {
        let name = u.lastPathComponent
        if name.lowercased().hasSuffix("pyramid.zip") { continue }
        if blocked.contains(where: { name.hasSuffix($0) }) {
          r.errors.append("\(u.path.replacingOccurrences(of: contents.path + "/", with: "")): the game does not allow \(blocked.joined(separator: " ")) files.")
        }
      }
    }
    return r
  }
}

// MARK: file differences

struct FileDifference: Identifiable, Hashable {
  enum Kind: String { case changed = "Changed", notOnSteam = "Only on your Mac", onlyOnSteam = "Only on Steam" }
  var kind: Kind
  var path: String
  var id: String { kind.rawValue + path }
}

func listFiles(_ root: URL) -> [String: URL] {
  var out: [String: URL] = [:]
  guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return out }
  let base = root.standardizedFileURL.path + "/"
  for case let u as URL in walker {
    if u.lastPathComponent == ".DS_Store" { continue }
    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
    out[u.standardizedFileURL.path.replacingOccurrences(of: base, with: "")] = u
  }
  return out
}

func compareFolders(local: URL, steam: URL) -> [FileDifference] {
  let a = listFiles(local), b = listFiles(steam)
  var out: [FileDifference] = []
  for (path, url) in a {
    if let other = b[path] {
      if !FileManager.default.contentsEqual(atPath: url.path, andPath: other.path) { out.append(.init(kind: .changed, path: path)) }
    } else {
      out.append(.init(kind: .notOnSteam, path: path))
    }
  }
  for path in b.keys where a[path] == nil { out.append(.init(kind: .onlyOnSteam, path: path)) }
  return out.sorted { $0.path < $1.path }
}
