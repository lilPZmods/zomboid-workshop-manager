import AppKit
import SwiftUI
import UserNotifications

// `--steam <op>` runs one Steam operation in this short-lived process and exits.
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--steam" {
  exit(Helper.run(Array(CommandLine.arguments.dropFirst(2))))
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  var store: Store?

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
  }

  // Keep running in the menu bar after the window closes, so page checks continue.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions { [.banner, .sound] }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let wid = response.notification.request.content.userInfo["workshopID"] as? String
    await MainActor.run {
      if let wid { self.store?.select(workshopID: wid) }
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}

struct ZomboidWorkshopManagerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var store = Store()

  var body: some Scene {
    Window("Zomboid Workshop Manager", id: "main") {
      ContentView()
        .environmentObject(store)
        .frame(minWidth: 1000, minHeight: 620)
        .onAppear { delegate.store = store }
        .onOpenURL { url in
          // zomboid-workshop-manager://item/<workshop id>
          if url.host == "item", let wid = url.pathComponents.dropFirst().first { store.select(workshopID: wid) }
        }
    }
    .handlesExternalEvents(matching: ["*"])
    Settings { SettingsView().environmentObject(store) }
    MenuBarExtra {
      MenuBarContent().environmentObject(store)
    } label: {
      Image(systemName: store.items.contains { $0.needsAttention } ? "shippingbox.and.arrow.backward.fill" : "shippingbox")
    }
  }
}

ZomboidWorkshopManagerApp.main()
