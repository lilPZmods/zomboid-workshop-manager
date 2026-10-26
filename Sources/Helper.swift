// `Zomboid Workshop Manager --steam <op> ...` runs one Steam operation and
// exits. Output is one JSON object per line:
//   {"progress": "..."}   while working
//   {"result": ...}       on success
//   {"error": "..."}      on failure (exit code 1)

import Foundation

enum Helper {
  static func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object),
       let line = String(data: data, encoding: .utf8) {
      FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
    }
  }

  static func encodable<T: Encodable>(_ value: T) -> Any {
    let data = try! JSONEncoder().encode(value)
    return try! JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
  }

  static func run(_ args: [String]) -> Int32 {
    guard let op = args.first else {
      emit(["error": "missing operation"])
      return 1
    }
    let settings = AppSettings.load()
    do {
      let steam = try Steam(libraryPath: settings.steamLibraryPath)
      defer { steam.shutdown() }
      let report: (String) -> Void = { emit(["progress": $0]) }
      switch op {
      case "query":
        let ids = args.dropFirst().compactMap { UInt64($0) }
        emit(["result": encodable(try steam.query(ids))])
      case "download":
        guard let id = args.dropFirst().first.flatMap({ UInt64($0) }) else { throw SteamError.message("missing id") }
        emit(["result": try steam.download(id, report: report)])
      case "create":
        let created = try steam.createItem()
        emit(["result": ["id": String(created.id), "needsLegalAgreement": created.needsLegalAgreement]])
      case "delete":
        guard let id = args.dropFirst().first.flatMap({ UInt64($0) }) else { throw SteamError.message("missing id") }
        try steam.deleteItem(id)
        emit(["result": ["deleted": String(id)]])
      case "submit":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let update = try JSONDecoder().decode(Steam.Update.self, from: input)
        let legal = try steam.submit(update, report: report)
        emit(["result": ["needsLegalAgreement": legal]])
      default:
        throw SteamError.message("unknown operation \(op)")
      }
      return 0
    } catch {
      emit(["error": "\(error)"])
      return 1
    }
  }
}
