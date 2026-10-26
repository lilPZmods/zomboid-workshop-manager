// Talks to the Steam client through the libsteam_api.dylib that ships with
// Project Zomboid, using Steamworks' flat C API. Only the helper process
// (`--steam`) uses this, so the main app never holds a Steam session open.

import Foundation

let zomboidAppID: UInt32 = 108600

enum SteamError: Error, CustomStringConvertible {
  case message(String)
  var description: String { if case .message(let m) = self { return m }; return "" }
}

/// Item page and file info as Steam has it now.
struct SteamItem: Codable {
  var id: String
  var result: Int32
  var title: String
  var description: String
  var tags: [String]
  var visibility: Int32
  var owner: String
  var timeUpdated: UInt32
  var previewURL: String
  var installedFolder: String?
  var installedTime: UInt32?
  var stats: [String: UInt64]? = nil
}

final class Steam {
  private let lib: UnsafeMutableRawPointer
  private var ugc: OpaquePointer?
  private var utils: OpaquePointer?

  private func fn<T>(_ name: String, _: T.Type) throws -> T {
    guard let sym = dlsym(lib, name) else { throw SteamError.message("Steam library is missing \(name)") }
    return unsafeBitCast(sym, to: T.self)
  }

  init(libraryPath: String) throws {
    guard let handle = dlopen(libraryPath, RTLD_NOW) else {
      throw SteamError.message("Could not load \(libraryPath). Set the Project Zomboid location in Settings.")
    }
    lib = handle
    setenv("SteamAppId", String(zomboidAppID), 1)
    setenv("SteamGameId", String(zomboidAppID), 1)
    typealias InitFlat = @convention(c) (UnsafeMutablePointer<CChar>) -> Int32
    var err = [CChar](repeating: 0, count: 1024)
    let status = try fn("SteamAPI_InitFlat", InitFlat.self)(&err)
    if status != 0 {
      let text = String(cString: err)
      throw SteamError.message("Steam did not start (\(text.isEmpty ? "code \(status)" : text)). Is the Steam client running and logged in?")
    }
    typealias Getter = @convention(c) () -> OpaquePointer?
    ugc = try fn("SteamAPI_SteamUGC_v020", Getter.self)()
    utils = try fn("SteamAPI_SteamUtils_v010", Getter.self)()
    if ugc == nil || utils == nil { throw SteamError.message("Steam Workshop interface unavailable.") }
  }

  func shutdown() {
    typealias Fn = @convention(c) () -> Void
    try? fn("SteamAPI_Shutdown", Fn.self)()
  }

  private func runCallbacks() {
    typealias Fn = @convention(c) () -> Void
    try? fn("SteamAPI_RunCallbacks", Fn.self)()
  }

  /// Pumps Steam until an async call finishes. `progress` runs on each tick.
  private func wait(_ call: UInt64, timeout: TimeInterval, progress: () -> Void = {}) throws {
    typealias Done = @convention(c) (OpaquePointer?, UInt64, UnsafeMutablePointer<Bool>) -> Bool
    let done = try fn("SteamAPI_ISteamUtils_IsAPICallCompleted", Done.self)
    var failed = false
    let deadline = Date().addingTimeInterval(timeout)
    while !done(utils, call, &failed) {
      runCallbacks()
      progress()
      if Date() > deadline { throw SteamError.message("Steam did not answer in time.") }
      usleep(200_000)
    }
    if failed { throw SteamError.message("Steam reported an I/O failure.") }
  }

  private func callResult(_ call: UInt64, into buffer: UnsafeMutableRawPointer, size: Int32, callback: Int32) throws {
    typealias Get = @convention(c) (OpaquePointer?, UInt64, UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Bool>) -> Bool
    var failed = false
    let ok = try fn("SteamAPI_ISteamUtils_GetAPICallResult", Get.self)(utils, call, buffer, size, callback, &failed)
    if !ok || failed { throw SteamError.message("Steam did not return a result.") }
  }

  // MARK: reading items

  func query(_ ids: [UInt64]) throws -> [SteamItem] {
    guard !ids.isEmpty else { return [] }
    typealias Create = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt64>, UInt32) -> UInt64
    typealias SetBool = @convention(c) (OpaquePointer?, UInt64, Bool) -> Bool
    typealias Send = @convention(c) (OpaquePointer?, UInt64) -> UInt64
    typealias Result = @convention(c) (OpaquePointer?, UInt64, UInt32, UnsafeMutableRawPointer) -> Bool
    typealias Preview = @convention(c) (OpaquePointer?, UInt64, UInt32, UnsafeMutablePointer<CChar>, UInt32) -> Bool
    typealias Release = @convention(c) (OpaquePointer?, UInt64) -> Bool

    var list = ids
    let handle = try fn("SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest", Create.self)(ugc, &list, UInt32(list.count))
    _ = try fn("SteamAPI_ISteamUGC_SetReturnLongDescription", SetBool.self)(ugc, handle, true)
    let call = try fn("SteamAPI_ISteamUGC_SendQueryUGCRequest", Send.self)(ugc, handle)
    defer { _ = try? fn("SteamAPI_ISteamUGC_ReleaseQueryUGCRequest", Release.self)(ugc, handle) }
    try wait(call, timeout: 60)

    let getResult = try fn("SteamAPI_ISteamUGC_GetQueryUGCResult", Result.self)
    let getPreview = try fn("SteamAPI_ISteamUGC_GetQueryUGCPreviewURL", Preview.self)
    typealias Stat = @convention(c) (OpaquePointer?, UInt64, UInt32, Int32, UnsafeMutablePointer<UInt64>) -> Bool
    let getStat = try fn("SteamAPI_ISteamUGC_GetQueryUGCStatistic", Stat.self)
    // EItemStatistic values, named like the Steam Web API fields.
    let statNames: [(Int32, String)] = [(0, "subs"), (1, "favs"), (3, "life_subs"), (4, "life_favs"), (6, "views"), (10, "comments")]
    var items: [SteamItem] = []
    // SteamUGCDetails_t, packed to 4 bytes on macOS. The buffer is oversized
    // on purpose; fields are read by their SDK offsets.
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 8)
    defer { buffer.deallocate() }
    for index in 0..<UInt32(ids.count) {
      memset(buffer, 0, 16384)
      guard getResult(ugc, handle, index, buffer) else { continue }
      func str(_ offset: Int, _ len: Int) -> String {
        let p = buffer.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        var n = 0
        while n < len && p[n] != 0 { n += 1 }
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
      }
      func u32(_ offset: Int) -> UInt32 { buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
      func i32(_ offset: Int) -> Int32 { buffer.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
      func u64(_ offset: Int) -> UInt64 { buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
      var url = [CChar](repeating: 0, count: 1024)
      _ = getPreview(ugc, handle, index, &url, 1024)
      let id = u64(0)
      let tags = str(8183, 1025).split(separator: ",").map { String($0) }
      var item = SteamItem(
        id: String(id), result: i32(8), title: str(24, 129), description: str(153, 8000), tags: tags,
        visibility: i32(8176), owner: String(u64(8156)), timeUpdated: u32(8168), previewURL: String(cString: url))
      if let info = installInfo(id) { item.installedFolder = info.0; item.installedTime = info.1 }
      var stats: [String: UInt64] = ["up": UInt64(u32(9748)), "down": UInt64(u32(9752))]
      for (stat, name) in statNames {
        var v: UInt64 = 0
        if getStat(ugc, handle, index, stat, &v) { stats[name] = v }
      }
      item.stats = stats
      items.append(item)
    }
    return items
  }

  func installInfo(_ id: UInt64) -> (String, UInt32)? {
    typealias Info = @convention(c) (OpaquePointer?, UInt64, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<CChar>, UInt32, UnsafeMutablePointer<UInt32>) -> Bool
    guard let f = try? fn("SteamAPI_ISteamUGC_GetItemInstallInfo", Info.self) else { return nil }
    var size: UInt64 = 0
    var stamp: UInt32 = 0
    var folder = [CChar](repeating: 0, count: 4096)
    guard f(ugc, id, &size, &folder, 4096, &stamp) else { return nil }
    return (String(cString: folder), stamp)
  }

  /// Makes the Steam client download the latest upload of an item and waits for it.
  func download(_ id: UInt64, report: (String) -> Void) throws -> String {
    typealias State = @convention(c) (OpaquePointer?, UInt64) -> UInt32
    typealias Sub = @convention(c) (OpaquePointer?, UInt64) -> UInt64
    typealias Download = @convention(c) (OpaquePointer?, UInt64, Bool) -> Bool
    typealias Info = @convention(c) (OpaquePointer?, UInt64, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Bool
    let state = try fn("SteamAPI_ISteamUGC_GetItemState", State.self)
    let installed: UInt32 = 4, needsUpdate: UInt32 = 8, downloading: UInt32 = 16, pending: UInt32 = 32, subscribed: UInt32 = 1
    if state(ugc, id) & subscribed == 0 {
      // Unsubscribed items get removed by Steam; subscribe so the copy stays.
      let call = try fn("SteamAPI_ISteamUGC_SubscribeItem", Sub.self)(ugc, id)
      try wait(call, timeout: 60)
    }
    _ = try fn("SteamAPI_ISteamUGC_DownloadItem", Download.self)(ugc, id, true)
    let info = try fn("SteamAPI_ISteamUGC_GetItemDownloadInfo", Info.self)
    let deadline = Date().addingTimeInterval(30 * 60)
    var lastPct = -1
    usleep(500_000)
    while true {
      runCallbacks()
      let s = state(ugc, id)
      if s & installed != 0 && s & (needsUpdate | downloading | pending) == 0 { break }
      var done: UInt64 = 0, total: UInt64 = 0
      if info(ugc, id, &done, &total), total > 0 {
        let pct = Int(done * 100 / total)
        if pct != lastPct { report("Downloading from Steam \(pct)%"); lastPct = pct }
      }
      if Date() > deadline { throw SteamError.message("Download timed out.") }
      usleep(300_000)
    }
    guard let (folder, _) = installInfo(id) else { throw SteamError.message("Steam did not say where it installed the item.") }
    return folder
  }

  // MARK: writing items

  /// Creates a new, empty Workshop item and returns its id.
  func createItem() throws -> (id: UInt64, needsLegalAgreement: Bool) {
    typealias Create = @convention(c) (OpaquePointer?, UInt32, Int32) -> UInt64
    let call = try fn("SteamAPI_ISteamUGC_CreateItem", Create.self)(ugc, zomboidAppID, 0)
    try wait(call, timeout: 120)
    // CreateItemResult_t (pack 4): EResult @0, PublishedFileId_t @4, bool @12; 16 bytes.
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
    defer { buf.deallocate() }
    memset(buf, 0, 16)
    try callResult(call, into: buf, size: 16, callback: 3403)
    let result = buf.load(fromByteOffset: 0, as: Int32.self)
    if result != 1 { throw SteamError.message("Steam refused to create the item (EResult \(result)).") }
    return (buf.loadUnaligned(fromByteOffset: 4, as: UInt64.self), buf.load(fromByteOffset: 12, as: Bool.self))
  }

  /// Permanently deletes a Workshop item you own.
  func deleteItem(_ id: UInt64) throws {
    typealias Delete = @convention(c) (OpaquePointer?, UInt64) -> UInt64
    let call = try fn("SteamAPI_ISteamUGC_DeleteItem", Delete.self)(ugc, id)
    try wait(call, timeout: 120)
    // DeleteItemResult_t (pack 4): EResult @0, PublishedFileId_t @4; 12 bytes.
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 12, alignment: 8)
    defer { buf.deallocate() }
    memset(buf, 0, 12)
    try callResult(call, into: buf, size: 12, callback: 3417)
    let result = buf.load(fromByteOffset: 0, as: Int32.self)
    if result != 1 { throw SteamError.message("Delete failed (Steam EResult \(result)\(eresultHint(result))).") }
  }

  struct Update: Codable {
    var id: String
    var title: String?
    var description: String?
    var visibility: Int32?
    var tags: [String]?
    var contentFolder: String?
    var previewFile: String?
    var changeNote: String
  }

  /// Submits an item update. Nil fields stay as they are on Steam.
  func submit(_ u: Update, report: (String) -> Void) throws -> Bool {
    typealias Start = @convention(c) (OpaquePointer?, UInt32, UInt64) -> UInt64
    typealias SetStr = @convention(c) (OpaquePointer?, UInt64, UnsafePointer<CChar>) -> Bool
    typealias SetVis = @convention(c) (OpaquePointer?, UInt64, Int32) -> Bool
    typealias SetTags = @convention(c) (OpaquePointer?, UInt64, UnsafeRawPointer, Bool) -> Bool
    typealias Submit = @convention(c) (OpaquePointer?, UInt64, UnsafePointer<CChar>) -> UInt64
    typealias Progress = @convention(c) (OpaquePointer?, UInt64, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Int32

    guard let id = UInt64(u.id) else { throw SteamError.message("Bad Workshop id \(u.id)") }
    let handle = try fn("SteamAPI_ISteamUGC_StartItemUpdate", Start.self)(ugc, zomboidAppID, id)
    let setStr = { (name: String, value: String) throws in
      guard try self.fn(name, SetStr.self)(self.ugc, handle, value) else {
        throw SteamError.message("Steam rejected \(name.replacingOccurrences(of: "SteamAPI_ISteamUGC_", with: "")).")
      }
    }
    if let t = u.title { try setStr("SteamAPI_ISteamUGC_SetItemTitle", t) }
    if let d = u.description { try setStr("SteamAPI_ISteamUGC_SetItemDescription", d) }
    if let v = u.visibility {
      guard try fn("SteamAPI_ISteamUGC_SetItemVisibility", SetVis.self)(ugc, handle, v) else {
        throw SteamError.message("Steam rejected the visibility.")
      }
    }
    if let tags = u.tags {
      // SteamParamStringArray_t { const char **strings; int32 count; }
      let cStrings = tags.map { strdup($0) }
      defer { cStrings.forEach { free($0) } }
      var pointers = cStrings.map { UnsafePointer<CChar>($0) }
      try pointers.withUnsafeMutableBufferPointer { buf in
        let array = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
        defer { array.deallocate() }
        array.storeBytes(of: buf.baseAddress, toByteOffset: 0, as: UnsafeMutablePointer<UnsafePointer<CChar>?>?.self)
        array.storeBytes(of: Int32(tags.count), toByteOffset: 8, as: Int32.self)
        _ = try fn("SteamAPI_ISteamUGC_SetItemTags", SetTags.self)(ugc, handle, array, false)
      }
    }
    if let c = u.contentFolder { try setStr("SteamAPI_ISteamUGC_SetItemContent", c) }
    if let p = u.previewFile { try setStr("SteamAPI_ISteamUGC_SetItemPreview", p) }

    let call = try fn("SteamAPI_ISteamUGC_SubmitItemUpdate", Submit.self)(ugc, handle, u.changeNote)
    let progress = try fn("SteamAPI_ISteamUGC_GetItemUpdateProgress", Progress.self)
    let stages = [1: "Preparing", 2: "Preparing files", 3: "Uploading files", 4: "Uploading preview", 5: "Finishing"]
    var last = ""
    try wait(call, timeout: 60 * 60) {
      var done: UInt64 = 0, total: UInt64 = 0
      let stage = Int(progress(self.ugc, handle, &done, &total))
      guard var line = stages[stage] else { return }
      if total > 0 { line += " \(done * 100 / total)%" }
      if line != last { report(line); last = line }
    }
    // SubmitItemUpdateResult_t (pack 4): EResult @0, bool @4, PublishedFileId_t @8; 16 bytes.
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
    defer { buf.deallocate() }
    memset(buf, 0, 16)
    try callResult(call, into: buf, size: 16, callback: 3404)
    let result = buf.load(fromByteOffset: 0, as: Int32.self)
    if result != 1 { throw SteamError.message("Upload failed (Steam EResult \(result)\(eresultHint(result))).") }
    return buf.load(fromByteOffset: 4, as: Bool.self)
  }
}

func eresultHint(_ r: Int32) -> String {
  switch r {
  case 2: return ": generic failure, often a file Steam could not read"
  case 8: return ": invalid parameter"
  case 9: return ": item not found"
  case 15: return ": access denied, are you logged into the account that owns this item?"
  case 16: return ": timed out"
  case 25: return ": over your Steam Cloud quota"
  default: return ""
  }
}
