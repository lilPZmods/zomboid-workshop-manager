import Foundation

/// Where things live. Saved in UserDefaults; defaults match a normal Steam install.
struct AppSettings {
  var gameApp: String
  var workshopDir: String

  static let defaultGameApp = NSHomeDirectory()
    + "/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app"
  static let defaultWorkshopDir = NSHomeDirectory() + "/Zomboid/Workshop"

  var steamLibraryPath: String { gameApp + "/Contents/MacOS/libsteam_api.dylib" }
  var tagsFile: String { gameApp + "/Contents/Java/media/WorkshopTags.txt" }

  static func load() -> AppSettings {
    let d = UserDefaults(suiteName: "io.github.lilpzmods.zomboid-workshop-manager") ?? .standard
    return AppSettings(
      gameApp: d.string(forKey: "gameApp") ?? defaultGameApp,
      workshopDir: d.string(forKey: "workshopDir") ?? defaultWorkshopDir)
  }

  func save() {
    let d = UserDefaults(suiteName: "io.github.lilpzmods.zomboid-workshop-manager") ?? .standard
    d.set(gameApp, forKey: "gameApp")
    d.set(workshopDir, forKey: "workshopDir")
  }
}
