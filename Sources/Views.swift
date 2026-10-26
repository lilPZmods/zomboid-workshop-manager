import AppKit
import ServiceManagement
import SwiftUI
import WebKit

struct ContentView: View {
  @EnvironmentObject var store: Store
  @State private var confirmPullAll = false

  var body: some View {
    NavigationSplitView {
      List(selection: $store.selection) {
        ForEach(store.items) { item in
          ProjectRow(item: item).tag(item.id)
        }
      }
      .navigationSplitViewColumnWidth(min: 240, ideal: 280)
      .safeAreaInset(edge: .bottom) {
        HStack {
          if store.refreshing { ProgressView().controlSize(.small) }
          Text(store.lastRefresh.map { "Checked Steam \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not checked yet")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
        }
        .padding(8)
      }
    } detail: {
      if let id = store.selection, let item = store.items.first(where: { $0.id == id }) {
        ProjectDetail(item: item).id(item.id)
      } else {
        Text(store.items.isEmpty ? "No projects found in \(AppSettings.load().workshopDir)" : "Select a project")
          .foregroundStyle(.secondary)
      }
    }
    .toolbar {
      ToolbarItem {
        let differing = store.items.filter { [.steamEdited, .bothEdited, .differs].contains($0.page) }
        if differing.count > 1 {
          Button { confirmPullAll = true } label: { Label("Use Steam's Page for All", systemImage: "arrow.down.doc") }
            .help("Write the Steam page into workshop.txt for every project whose page differs")
            .confirmationDialog("Use the Steam page for \(differing.count) projects?", isPresented: $confirmPullAll) {
              Button("Update \(differing.count) workshop.txt Files") { store.pullAllPages() }
            } message: {
              Text(differing.map { $0.project.page.title }.joined(separator: ", ")
                + "\n\nEach workshop.txt gets the title, description, tags and visibility from Steam.")
            }
        }
      }
      ToolbarItem {
        Button { Task { await store.refreshSteam() } } label: { Label("Check Steam", systemImage: "arrow.clockwise") }
          .disabled(store.refreshing)
          .help("Check every project against Steam now")
      }
    }
    .overlay(alignment: .top) {
      if let e = store.globalError {
        Banner(color: .red, symbol: "exclamationmark.octagon", text: e).padding()
      }
    }
  }
}

struct ProjectRow: View {
  @ObservedObject var item: ItemState

  var body: some View {
    HStack(spacing: 10) {
      PreviewImage(url: item.project.preview, size: 34)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.project.page.title.isEmpty ? item.project.id : item.project.page.title).lineLimit(1)
        Text(summary).font(.caption).foregroundStyle(item.needsAttention ? .orange : .secondary).lineLimit(1)
      }
      Spacer()
      if item.busy != nil { ProgressView().controlSize(.small) }
      else if item.needsAttention { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
    }
    .padding(.vertical, 2)
  }

  var summary: String {
    if !item.check.errors.isEmpty { return "Fails the game's upload checks" }
    switch item.page {
    case .notPublished: return "Not published yet"
    case .steamEdited: return "Page edited on Steam"
    case .localEdited: return "Page changes not uploaded"
    case .bothEdited: return "Page edited here and on Steam"
    case .differs: return "Page differs from Steam"
    default: break
    }
    if case .differs(let d) = item.content { return "\(d.count) file\(d.count == 1 ? "" : "s") not uploaded" }
    if item.page == .unknown { return "Not checked yet" }
    return "Up to date"
  }
}

struct PreviewImage: View {
  var url: URL
  var size: CGFloat
  var body: some View {
    Group {
      if let img = NSImage(contentsOf: url) {
        Image(nsImage: img).resizable().interpolation(.high)
      } else {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
          .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 8 : 4))
  }
}

struct Banner: View {
  var color: Color
  var symbol: String
  var text: String
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: symbol).foregroundStyle(color)
      Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }
}

struct ProjectDetail: View {
  @EnvironmentObject var store: Store
  @ObservedObject var item: ItemState
  @State private var draft = PageText(title: "", description: "", tags: [], visibility: .public)
  @State private var changeNote = ""
  @State private var showSteamText = false
  @State private var confirmOverwrite = false
  @State private var confirmUpload = false
  @AppStorage("showPreview") private var showPreview = true

  var project: Project { item.project }
  var editing: Bool { draft != project.page }
  var uploadBlocked: Bool { [.steamEdited, .bothEdited, .differs].contains(item.page) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        if let b = item.busy { Banner(color: .blue, symbol: "arrow.triangle.2.circlepath", text: b) }
        if let e = item.error { Banner(color: .red, symbol: "exclamationmark.octagon", text: e) }
        if let m = item.message { Banner(color: .green, symbol: "checkmark.circle", text: m) }
        pageSyncBanner
        pageEditor
        checks
        files
        uploadBox
      }
      .padding(20)
      .frame(maxWidth: 1400, alignment: .leading)
    }
    .onAppear { draft = project.page }
    .onChange(of: item.busy) { _, busy in if busy == nil { draft = project.page } }
    .disabled(item.busy != nil)
  }

  // MARK: header

  var header: some View {
    HStack(alignment: .top, spacing: 16) {
      PreviewImage(url: project.preview, size: 96)
      VStack(alignment: .leading, spacing: 6) {
        Text(project.page.title.isEmpty ? project.id : project.page.title).font(.title2.bold())
        Text("~/Zomboid/Workshop/\(project.id)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        if let wid = project.workshopID {
          Text("Workshop ID \(wid) · \(project.page.visibility.label)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        HStack {
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.workshopTxt]) }
          if let wid = project.workshopID {
            Button("Open on Steam") {
              NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(wid)")!)
            }
          }
          Button("Reload") { store.reloadLocal(item); draft = project.page }
        }
        .controlSize(.small)
      }
    }
  }

  // MARK: page sync

  @ViewBuilder var pageSyncBanner: some View {
    switch item.page {
    case .steamEdited, .bothEdited, .differs:
      VStack(alignment: .leading, spacing: 8) {
        Banner(color: .orange, symbol: "arrow.left.arrow.right", text: pageSyncText)
        HStack {
          Button("Use Steam's Page") { store.pullPage(item) }
            .help("Write the Steam page's title, description, tags and visibility into workshop.txt")
          Button("Send Mine to Steam…") { confirmOverwrite = true }
            .help("Replace the Steam page text with workshop.txt. Files are not uploaded.")
          Button(showSteamText ? "Hide Steam's Text" : "Compare") { showSteamText.toggle() }
        }
        if showSteamText, let sp = item.steamPage { comparison(sp) }
      }
      .confirmationDialog("Replace the Steam page with workshop.txt?", isPresented: $confirmOverwrite) {
        Button("Replace Steam Page", role: .destructive) { store.pushPage(item) }
      } message: {
        Text("The edits made on Steam will be lost.")
      }
    case .localEdited:
      HStack {
        Banner(color: .blue, symbol: "arrow.up.circle", text: "workshop.txt has page changes (\(diffNames)) that are not on Steam yet.")
        Button("Send Page to Steam") { store.pushPage(item) }
      }
    default:
      EmptyView()
    }
  }

  var diffNames: String {
    guard let sp = item.steamPage else { return "" }
    return project.page.differences(from: sp).joined(separator: ", ")
  }

  var pageSyncText: String {
    switch item.page {
    case .steamEdited: return "The page was edited on Steam (\(diffNames)). workshop.txt still has the old text. The next upload would undo the Steam edit, so sync first."
    case .bothEdited: return "The page was edited on Steam and in workshop.txt (\(diffNames)). Pick which one to keep."
    default: return "The Steam page and workshop.txt differ (\(diffNames)). Pick which one to keep."
    }
  }

  func comparison(_ sp: PageText) -> some View {
    let local = project.page
    return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
      GridRow {
        Text("").frame(width: 80)
        Text("workshop.txt").font(.headline)
        Text("Steam").font(.headline)
      }
      row("Title", local.title, sp.title)
      row("Visibility", local.visibility.label, sp.visibility.label)
      row("Tags", local.tags.joined(separator: ", "), sp.tags.joined(separator: ", "))
      row("Description", local.description, sp.description)
    }
    .padding(10)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
  }

  func row(_ name: String, _ a: String, _ b: String) -> some View {
    let differs = PageText(title: a, description: "", tags: [], visibility: .public).normalized().title
      != PageText(title: b, description: "", tags: [], visibility: .public).normalized().title
    return GridRow {
      Text(name).foregroundStyle(differs ? .orange : .secondary).frame(width: 80, alignment: .leading)
      Text(a).textSelection(.enabled).font(name == "Description" ? .system(.caption, design: .monospaced) : .body)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(b).textSelection(.enabled).font(name == "Description" ? .system(.caption, design: .monospaced) : .body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: page editor

  var pageEditor: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("Title") { TextField("Title", text: $draft.title) }
        LabeledContent("Visibility") {
          Picker("", selection: $draft.visibility) {
            ForEach(Visibility.allCases) { Text($0.label).tag($0) }
          }
          .labelsHidden().fixedSize()
        }
        LabeledContent("Tags") { TagPicker(selected: $draft.tags, allowed: store.allowedTags) }
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Description (Steam BBCode)")
            Spacer()
            Toggle("Steam Preview", isOn: $showPreview).toggleStyle(.switch).controlSize(.small)
          }
          HStack(spacing: 10) {
            TextEditor(text: $draft.description)
              .font(.system(.body, design: .monospaced))
              .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            if showPreview {
              SteamPreview(title: draft.title, description: draft.description)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
          }
          .frame(height: 440)
          Text("The game adds the Workshop ID and Mod ID lines on upload. Don't type them here.")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Choose Preview Image…") { pickPreview() }
          if countIDBlocks(project.page.description) > 0 {
            Button("Clean Description") { store.cleanDescription(item) }
              .help("Remove the Workshop ID / Mod ID lines that were copied into workshop.txt")
          }
          Spacer()
          Button("Discard Changes") { draft = project.page }.disabled(!editing)
          Button("Save to workshop.txt") { store.saveLocalPage(item, draft) }
            .keyboardShortcut("s").disabled(!editing)
        }
      }
      .padding(6)
    } label: {
      Label("Page", systemImage: "doc.text")
    }
  }

  func pickPreview() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png]
    panel.message = "Choose a square PNG, 256×256 or 512×512, at most 1000 KB"
    if panel.runModal() == .OK, let url = panel.url { store.choosePreview(item, from: url) }
  }

  // MARK: checks

  var checks: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        if item.check.errors.isEmpty {
          Label("Passes the game's upload checks", systemImage: "checkmark.seal").foregroundStyle(.green)
        }
        ForEach(item.check.errors, id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) }
        ForEach(item.check.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        if !item.check.modIDs.isEmpty {
          Text("Mod IDs: " + item.check.modIDs.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(6)
    } label: {
      Label("Checks", systemImage: "checklist")
    }
  }

  // MARK: files

  var files: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        switch item.content {
        case .unknown:
          Text(project.workshopID == nil ? "Not on Steam yet. Everything in Contents will be uploaded." : "Not checked yet.")
            .foregroundStyle(.secondary)
        case .match:
          Label("Contents matches the latest Steam upload", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .steamCopyMissing:
          HStack {
            Text("This Mac doesn't have the latest Steam upload, so files can't be compared yet.").foregroundStyle(.secondary)
            Button("Download to Compare") { store.download(item) }
          }
        case .differs(let diffs):
          Text("\(diffs.count) file\(diffs.count == 1 ? "" : "s") differ from the latest Steam upload. Players who load your local copy get kicked for a checksum mismatch until you upload.")
          ForEach(diffs.prefix(300)) { d in
            HStack(alignment: .firstTextBaseline) {
              Text(d.kind.rawValue).font(.caption).foregroundStyle(d.kind == .onlyOnSteam ? .red : .orange).frame(width: 110, alignment: .leading)
              Text(d.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
          }
          if diffs.count > 300 { Text("…and \(diffs.count - 300) more").font(.caption) }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(6)
    } label: {
      Label("Files", systemImage: "folder")
    }
  }

  // MARK: upload

  var uploadBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        Text("Change note (shows on the item's Change Notes tab)").font(.callout)
        TextEditor(text: $changeNote)
          .frame(minHeight: 60)
          .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
        if editing {
          Label("Save your page edits to workshop.txt first.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        if uploadBlocked {
          Label("Sync the page first (see above). Uploading now would overwrite the Steam page.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        HStack {
          Spacer()
          Button(project.workshopID == nil ? "Publish to Steam…" : "Upload to Steam…") { confirmUpload = true }
            .buttonStyle(.borderedProminent)
            .disabled(!item.check.errors.isEmpty || editing || uploadBlocked)
        }
      }
      .padding(6)
    } label: {
      Label(project.workshopID == nil ? "Publish" : "Upload", systemImage: "icloud.and.arrow.up")
    }
    .confirmationDialog(confirmTitle, isPresented: $confirmUpload) {
      Button(project.workshopID == nil ? "Publish" : "Upload") {
        if project.workshopID == nil { store.publish(item, note: changeNote) } else { store.upload(item, note: changeNote) }
        changeNote = ""
      }
    } message: {
      Text(project.workshopID == nil
        ? "Creates a new Workshop item as \(project.page.visibility.label.lowercased()) and uploads Contents, the preview and the page."
        : "Uploads Contents, preview.png and the page from workshop.txt. Subscribers get the update.")
    }
  }

  var confirmTitle: String {
    "\(project.workshopID == nil ? "Publish" : "Upload") \"\(project.page.title)\" to the Steam Workshop?"
  }
}

struct TagPicker: View {
  @Binding var selected: [String]
  var allowed: [String]

  var body: some View {
    let extra = selected.filter { t in !allowed.contains { $0.lowercased() == t.lowercased() } }
    let all = allowed + extra
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 4) {
      ForEach(all, id: \.self) { tag in
        Toggle(tag, isOn: Binding(
          get: { selected.contains { $0.lowercased() == tag.lowercased() } },
          set: { on in
            if on { selected.append(tag) } else { selected.removeAll { $0.lowercased() == tag.lowercased() } }
          }))
        .toggleStyle(.checkbox)
        .foregroundStyle(extra.contains(tag) ? .orange : .primary)
      }
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject var store: Store
  @State private var settings = AppSettings.load()
  @State private var openAtLogin = SMAppService.mainApp.status == .enabled

  var body: some View {
    Form {
      LabeledContent("Project Zomboid app") {
        HStack {
          Text(settings.gameApp).lineLimit(1).truncationMode(.middle).frame(maxWidth: 320, alignment: .leading)
          Button("Choose…") { pick(\.gameApp, folder: false) }
        }
      }
      LabeledContent("Workshop projects folder") {
        HStack {
          Text(settings.workshopDir).lineLimit(1).truncationMode(.middle).frame(maxWidth: 320, alignment: .leading)
          Button("Choose…") { pick(\.workshopDir, folder: true) }
        }
      }
      Toggle("Open at login (keeps checking Steam for page edits)", isOn: $openAtLogin)
        .onChange(of: openAtLogin) { _, on in
          do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
          catch { openAtLogin = !on }
        }
    }
    .padding(20)
    .frame(width: 620)
  }

  func pick(_ key: WritableKeyPath<AppSettings, String>, folder: Bool) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = folder
    panel.canChooseFiles = !folder
    panel.treatsFilePackagesAsDirectories = false
    if !folder { panel.allowedContentTypes = [.application] }
    if panel.runModal() == .OK, let url = panel.url {
      settings[keyPath: key] = url.path
      settings.save()
      store.loadProjects()
    }
  }
}

struct MenuBarContent: View {
  @EnvironmentObject var store: Store
  @Environment(\.openWindow) var openWindow

  var body: some View {
    let attention = store.items.filter { $0.needsAttention }
    if attention.isEmpty {
      Text("All Workshop projects in sync")
    } else {
      ForEach(attention) { item in
        Button("⚠︎ \(item.project.page.title)") { show(item.id) }
      }
    }
    Divider()
    Button("Check Steam Now") { Task { await store.refreshSteam() } }
    Button("Open Zomboid Workshop Manager") { show(nil) }
    Divider()
    Button("Quit") { NSApp.terminate(nil) }
  }

  func show(_ id: String?) {
    if let id { store.selection = id }
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}

/// Live preview of the description, rendered like the Workshop page.
struct SteamPreview: NSViewRepresentable {
  var title: String
  var description: String

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let web = WKWebView()
    web.navigationDelegate = context.coordinator
    web.setValue(false, forKey: "drawsBackground")
    web.loadHTMLString(BBCode.page, baseURL: URL(string: "https://steamcommunity.com/"))
    return web
  }

  func updateNSView(_ web: WKWebView, context: Context) {
    context.coordinator.show(web, title: title, html: BBCode.html(description))
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var loaded = false
    var pending: (WKWebView, String, String)?

    func show(_ web: WKWebView, title: String, html: String) {
      guard loaded else { pending = (web, title, html); return }
      // Swap the content in place so the scroll position stays put while typing.
      let t = (try? String(data: JSONEncoder().encode(title), encoding: .utf8)) ?? "\"\""
      let h = (try? String(data: JSONEncoder().encode(html), encoding: .utf8)) ?? "\"\""
      web.evaluateJavaScript("document.getElementById('title').textContent=\(t);document.getElementById('c').innerHTML=\(h);")
    }

    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
      loaded = true
      if let (w, t, h) = pending { pending = nil; show(w, title: t, html: h) }
    }

    // Clicked links open in the browser, not in the preview.
    func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      if action.navigationType == .linkActivated, let url = action.request.url {
        if url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
      } else {
        decisionHandler(.allow)
      }
    }
  }
}
