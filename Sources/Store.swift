import AppKit
import CryptoKit
import Foundation
import UserNotifications

enum PageSync: Equatable {
  case notPublished
  case unknown            // Steam not checked yet
  case inSync
  case localEdited        // workshop.txt changed since the last sync
  case steamEdited        // the Steam page changed since the last sync
  case bothEdited
  case differs            // no sync history; can't tell who changed what

  var needsAttention: Bool { ![.inSync, .unknown, .notPublished].contains(self) }
}

enum ContentSync: Equatable {
  case unknown
  case match
  case differs([FileDifference])
  case steamCopyMissing   // Steam has no local copy of the latest upload yet
}

final class ItemState: ObservableObject, Identifiable {
  let project: Project
  var id: String { project.id }
  @Published var check = CheckResult()
  @Published var steam: SteamItem?
  @Published var page: PageSync = .unknown
  @Published var content: ContentSync = .unknown
  @Published var busy: String?
  @Published var message: String?
  @Published var error: String?

  init(project: Project) { self.project = project }

  var steamPage: PageText? {
    guard let s = steam else { return nil }
    return PageText(
      title: s.title, description: stripIDBlocks(s.description), tags: s.tags,
      visibility: Visibility(rawValue: s.visibility) ?? .public)
  }

  var needsAttention: Bool {
    if page.needsAttention || !check.errors.isEmpty { return true }
    if case .differs = content { return true }
    return false
  }
}

@MainActor
final class Store: ObservableObject {
  @Published var items: [ItemState] = []
  @Published var selection: String?
  @Published var lastRefresh: Date?
  @Published var refreshing = false
  @Published var globalError: String?
  var allowedTags: [String] = []
  private var timer: Timer?
  private let steamQueue = DispatchQueue(label: "steam-helper")

  private var supportDir: URL {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Zomboid Workshop Manager")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
  }

  init() {
    loadProjects()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    Task { await refreshSteam() }
    timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.refreshSteam() }
    }
  }

  // MARK: sync history (the page text as of the last sync, per Workshop id)

  private var baselinesFile: URL { supportDir.appendingPathComponent("page-baselines.json") }
  private var notifiedFile: URL { supportDir.appendingPathComponent("notified.json") }

  private func loadJSON<T: Decodable>(_ url: URL, as: T.Type) -> T? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(T.self, from: d)
  }

  private func saveJSON<T: Encodable>(_ value: T, _ url: URL) {
    if let d = try? JSONEncoder().encode(value) { try? d.write(to: url, options: .atomic) }
  }

  func baseline(_ id: String) -> PageText? { loadJSON(baselinesFile, as: [String: PageText].self)?[id] }

  func setBaseline(_ id: String, _ page: PageText) {
    var all = loadJSON(baselinesFile, as: [String: PageText].self) ?? [:]
    all[id] = page.normalized()
    saveJSON(all, baselinesFile)
  }

  // MARK: loading

  func loadProjects() {
    let settings = AppSettings.load()
    allowedTags = ((try? String(contentsOfFile: settings.tagsFile, encoding: .utf8)) ?? "")
      .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let root = URL(fileURLWithPath: settings.workshopDir)
    let folders = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
      .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("workshop.txt").path) }
      .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
    let old = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    items = folders.map { folder in
      let state = old[folder.lastPathComponent] ?? ItemState(project: Project(folder: folder))
      state.project.reload()
      state.check = state.project.check(allowedTags: allowedTags)
      return state
    }
    for item in items { updatePageSync(item) }
    if selection == nil { selection = items.first?.id }
  }

  func reloadLocal(_ item: ItemState) {
    item.project.reload()
    item.check = item.project.check(allowedTags: allowedTags)
    updatePageSync(item)
    updateContentSync(item)
  }

  func updatePageSync(_ item: ItemState) {
    guard let wid = item.project.workshopID else { item.page = .notPublished; return }
    guard let steamPage = item.steamPage else { item.page = .unknown; return }
    let local = item.project.page
    if local.same(as: steamPage) {
      item.page = .inSync
      if baseline(wid) == nil || !(baseline(wid)!.same(as: local)) { setBaseline(wid, local) }
      return
    }
    guard let base = baseline(wid) else { item.page = .differs; return }
    let localChanged = !local.same(as: base), steamChanged = !steamPage.same(as: base)
    item.page = localChanged && steamChanged ? .bothEdited : steamChanged ? .steamEdited : .localEdited
  }

  func updateContentSync(_ item: ItemState) {
    guard let s = item.steam, let folder = s.installedFolder,
          FileManager.default.fileExists(atPath: folder),
          (s.installedTime ?? 0) >= s.timeUpdated else {
      item.content = item.steam == nil ? .unknown : .steamCopyMissing
      return
    }
    let diffs = compareFolders(local: item.project.contents, steam: URL(fileURLWithPath: folder))
    item.content = diffs.isEmpty ? .match : .differs(diffs)
  }

  // MARK: Steam helper

  struct HelperFailure: Error, CustomStringConvertible { var description: String }

  /// Runs this app's own executable with `--steam <args>` and returns the result.
  nonisolated func helper(_ args: [String], input: Data? = nil, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Any {
    try await withCheckedThrowingContinuation { cont in
      steamQueue.async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath!)
        p.arguments = ["--steam"] + args
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inPipe
        do { try p.run() } catch { cont.resume(throwing: error); return }
        if let input { inPipe.fileHandleForWriting.write(input) }
        try? inPipe.fileHandleForWriting.close()
        var result: Any?
        var failure: String?
        var buffer = Data()
        let handle = out.fileHandleForReading
        func consume(_ line: Data) {
          guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
          if let pr = obj["progress"] as? String { progress(pr) }
          if let r = obj["result"] { result = r }
          if let e = obj["error"] as? String { failure = e }
        }
        while true {
          let chunk = handle.availableData
          if chunk.isEmpty { break }
          buffer.append(chunk)
          while let nl = buffer.firstIndex(of: 0x0A) {
            consume(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
          }
        }
        if !buffer.isEmpty { consume(buffer) }
        p.waitUntilExit()
        if let failure { cont.resume(throwing: HelperFailure(description: failure)) }
        else if let result { cont.resume(returning: result) }
        else { cont.resume(throwing: HelperFailure(description: "The Steam helper exited without an answer.")) }
      }
    }
  }

  func refreshSteam() async {
    loadProjects()
    let ids = items.compactMap { $0.project.workshopID }
    guard !ids.isEmpty else { lastRefresh = Date(); return }
    refreshing = true
    defer { refreshing = false }
    do {
      let raw = try await helper(["query"] + ids)
      let data = try JSONSerialization.data(withJSONObject: raw)
      let steamItems = try JSONDecoder().decode([SteamItem].self, from: data)
      let byID = Dictionary(steamItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      for item in items {
        guard let wid = item.project.workshopID else { continue }
        item.steam = byID[wid]
        if let s = byID[wid], s.result != 1 {
          item.error = "Steam could not read item \(wid) (EResult \(s.result)\(eresultHint(s.result)))."
        }
        updatePageSync(item)
        updateContentSync(item)
      }
      globalError = nil
      lastRefresh = Date()
      notifySteamEdits()
    } catch {
      globalError = "\(error)"
    }
  }

  /// One notification per Steam page edit that workshop.txt does not have yet.
  private func notifySteamEdits() {
    var notified = loadJSON(notifiedFile, as: [String: String].self) ?? [:]
    for item in items where item.page == .steamEdited || item.page == .bothEdited {
      guard let wid = item.project.workshopID, let sp = item.steamPage else { continue }
      let encoded = (try? JSONEncoder().encode(sp.normalized())) ?? Data()
      let key = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
      if notified[wid] == key { continue }
      notified[wid] = key
      let content = UNMutableNotificationContent()
      content.title = "Workshop page edited on Steam"
      content.body = "\(sp.title): the Steam page no longer matches workshop.txt. Open Zomboid Workshop Manager to sync it."
      content.userInfo = ["workshopID": wid]
      UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "page-\(wid)", content: content, trigger: nil))
    }
    saveJSON(notified, notifiedFile)
  }

  func select(workshopID: String) {
    if let item = items.first(where: { $0.project.workshopID == workshopID }) { selection = item.id }
  }

  // MARK: actions

  private func run(_ item: ItemState, _ label: String, _ work: @escaping () async throws -> String?) {
    guard item.busy == nil else { return }
    item.busy = label
    item.error = nil
    item.message = nil
    Task {
      do {
        let msg = try await work()
        item.message = msg
      } catch {
        item.error = "\(error)"
      }
      item.busy = nil
      reloadLocal(item)
    }
  }

  private func progressSetter(_ item: ItemState) -> @Sendable (String) -> Void {
    { text in Task { @MainActor in item.busy = text } }
  }

  /// Steam page → workshop.txt.
  func pullPage(_ item: ItemState) {
    guard let sp = item.steamPage, let wid = item.project.workshopID else { return }
    run(item, "Saving Steam's page to workshop.txt") {
      try item.project.write(page: sp)
      self.setBaseline(wid, sp)
      return "workshop.txt now matches the Steam page."
    }
  }

  /// Steam page → workshop.txt for every project whose page differs.
  func pullAllPages() {
    for item in items where [.steamEdited, .bothEdited, .differs].contains(item.page) { pullPage(item) }
  }

  /// workshop.txt → Steam page (text only, files untouched).
  func pushPage(_ item: ItemState) {
    guard let wid = item.project.workshopID else { return }
    run(item, "Updating the Steam page") {
      let p = item.project.page
      let update = Steam.Update(
        id: wid, title: p.title, description: item.project.submitDescription(item.check),
        visibility: p.visibility.rawValue, tags: p.tags, contentFolder: nil, previewFile: nil, changeNote: "")
      let raw = try await self.helper(["submit"], input: try JSONEncoder().encode(update), progress: self.progressSetter(item))
      self.setBaseline(wid, p)
      await self.refreshSteam()
      return self.legalNote(raw) ?? "The Steam page now matches workshop.txt."
    }
  }

  /// Full upload, the same calls as the game's uploader.
  func upload(_ item: ItemState, note: String) {
    guard item.project.workshopID != nil else { publish(item, note: note); return }
    run(item, "Uploading") {
      try await self.submitAll(item, note: note)
    }
  }

  /// Creates a new Workshop item, writes its id into workshop.txt, then uploads.
  func publish(_ item: ItemState, note: String) {
    run(item, "Creating the Workshop item") {
      let raw = try await self.helper(["create"])
      guard let dict = raw as? [String: Any], let newID = dict["id"] as? String else {
        throw HelperFailure(description: "Steam did not return the new item's id.")
      }
      try item.project.write(page: item.project.page, id: newID)
      item.check = item.project.check(allowedTags: self.allowedTags)
      let done = try await self.submitAll(item, note: note.isEmpty ? "First upload" : note)
      if dict["needsLegalAgreement"] as? Bool == true { return self.legalText }
      return "Published as Workshop item \(newID). " + (done ?? "")
    }
  }

  private func submitAll(_ item: ItemState, note: String) async throws -> String? {
    guard let wid = item.project.workshopID else { return nil }
    let p = item.project.page
    let update = Steam.Update(
      id: wid, title: p.title, description: item.project.submitDescription(item.check),
      visibility: (p.title == "Mod Template" ? Visibility.private : p.visibility).rawValue, tags: p.tags,
      contentFolder: item.project.contents.path, previewFile: item.project.preview.path, changeNote: note)
    let raw = try await helper(["submit"], input: try JSONEncoder().encode(update), progress: progressSetter(item))
    setBaseline(wid, p)
    item.busy = "Downloading the new upload to compare"
    _ = try? await helper(["download", wid], progress: progressSetter(item))
    await refreshSteam()
    return legalNote(raw) ?? "Uploaded."
  }

  /// Downloads the latest upload into Steam's Workshop folder so files can be compared.
  func download(_ item: ItemState) {
    guard let wid = item.project.workshopID else { return }
    run(item, "Downloading from Steam") {
      _ = try await self.helper(["download", wid], progress: self.progressSetter(item))
      await self.refreshSteam()
      return nil
    }
  }

  func saveLocalPage(_ item: ItemState, _ page: PageText) {
    run(item, "Saving workshop.txt") {
      try item.project.write(page: page)
      return "Saved workshop.txt."
    }
  }

  func cleanDescription(_ item: ItemState) {
    var p = item.project.page
    p.description = stripIDBlocks(p.description)
    saveLocalPage(item, p)
  }

  func choosePreview(_ item: ItemState, from url: URL) {
    run(item, "Copying preview image") {
      let fm = FileManager.default
      if fm.fileExists(atPath: item.project.preview.path) {
        let backup = item.project.folder.appendingPathComponent("preview.previous.png")
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: item.project.preview, to: backup)
      }
      try fm.copyItem(at: url, to: item.project.preview)
      return "Preview image replaced. The old one is saved as preview.previous.png. It goes to Steam with the next upload."
    }
  }

  private let legalText = "Steam says you still need to accept the Workshop legal agreement before the item becomes visible. Open the item on Steam to accept it."

  private func legalNote(_ raw: Any) -> String? {
    (raw as? [String: Any])?["needsLegalAgreement"] as? Bool == true ? legalText : nil
  }
}
