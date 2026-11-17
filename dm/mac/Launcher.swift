// Mac app launcher: the settings window shown before the game starts, in the launcher's own process (launcher.c calls dm_mac_launcher before it starts the host). Its settings come from the
// app's Resources/dm/launcher.json (dm/games/settings.py with SETTINGS_PLATFORM=mac); the model and the rows are the iOS launcher's (dm/ios/Sources/LauncherSettings.swift, LauncherRow.swift),
// and so is the store: launcher.<VAR> in the app's preferences, which launcher.c reads when the window is not shown (docs/frontends.md, Saved choices). Basic settings (level basic) come
// first, the others under Advanced settings, each in the list's sections. Play puts the settings into this process's environment, which the host inherits; Quit and closing the window end the
// app without the game. "Show this window at launch" off: no window unless Option is held at launch, and launcher.c applies the saved choices. The window never takes focus by itself: an app
// opened in the background (open -g) keeps its window behind until the player switches to it
import AppKit
import QuartzCore
import SwiftUI

private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

/// The host's comparison of the two saves (dm/host/save_sync.c). This launcher links save_sync.o but imports no C header (pack_app.py builds it with swiftc and no bridging
/// header), so the symbol is declared here.
@_silgen_name("save_sync_report")
private func save_sync_report(_ save: UnsafePointer<CChar>, _ title: UnsafePointer<CChar>, _ folder: UnsafePointer<CChar>?, _ waitMs: Int32,
                              _ out: UnsafeMutablePointer<CChar>, _ n: Int) -> Int32

/// Cloud saves before Play: this Mac's save against the cloud's (SaveSyncReport, shared with the iPhone launcher), and the question it needs, as alerts.
/// It runs with the window's Play and, with the window off, before dmMacLauncher returns; DM_LAUNCHER=0 asks nothing (the host takes the newer save).
enum SaveCheck {
    enum Outcome { case play(String?), retry, cancel }

    /// Blocks while the cloud's file comes (SaveSyncReport.waitMs at most): call it off the main thread. nil: no report (sync is then left to the host as before)
    static func report() -> SaveSyncReport? {
        // getenv, not ProcessInfo.environment: launcher.c sets DM_SAVE and applies the env files in this process before the window
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        guard let id = info("DMTitleID"), !id.isEmpty else { fputs("launcher: save sync: no DMTitleID\n", stderr); return nil }
        // the folder as launcher.c will pass it (cloud_saves_folder): DM_SAVE_SYNC from the launch environment or an env file, else the window's choice; "0" = off
        let folder = getenv("DM_SAVE_SYNC").map { String(cString: $0) } ?? (UserDefaults.standard.string(forKey: "cloudSaves.folder") ?? "")
        var buf = [CChar](repeating: 0, count: 1024)
        let r = (folder.isEmpty ? "0" : folder).withCString { save_sync_report(save, id, $0, SaveSyncReport.waitMs, &buf, buf.count) }
        let line = String(cString: buf)
        guard r == 0 else { fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr); return nil }
        fputs("launcher: save sync: \(line)\n", stderr)
        return SaveSyncReport(line: line)
    }

    /// The question the report needs, as a modal alert; `cancel` names the way back ("Cancel" to the window, "Quit" without one)
    static func ask(_ r: SaveSyncReport?, cancel: String) -> Outcome {
        switch SaveSyncReport.step(r) {
        case .play(let choice): return .play(choice)
        case .choose:
            guard let r else { return .play(nil) }
            let a = NSAlert()
            a.messageText = SaveSyncReport.chooseTitle
            a.informativeText = r.chooseMessage(here: "Mac")
            a.alertStyle = .warning
            a.addButton(withTitle: r.localLabel(here: "Mac"))
            a.addButton(withTitle: r.cloudLabel)
            a.addButton(withTitle: cancel)
            a.buttons[0].keyEquivalent = ""   // no default: Return must not pick a save (the newer is not always the one to keep)
            a.buttons[2].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .play(r.localChoice)
            case .alertSecondButtonReturn: return .play(r.cloudChoice)
            default: return .cancel
            }
        case .unreadable:
            let a = NSAlert()
            a.messageText = SaveSyncReport.unreadableTitle
            a.informativeText = r?.unreadableMessage(here: "Mac") ?? ""
            a.addButton(withTitle: "Play This Mac's Save")
            a.addButton(withTitle: "Try Again")
            a.addButton(withTitle: cancel)
            a.buttons[2].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .play("offline")   // the mount does not wait for the cloud again
            case .alertSecondButtonReturn: return .retry
            default: return .cancel
            }
        }
    }

    static func apply(_ choice: String?) {
        guard let choice else { return }
        setenv("DM_SAVE_SYNC_CHOICE", choice, 1)
        fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr)
    }

    /// With the window off: the check and its question before the game, the app in front only while it asks. false: the player quit
    static func withoutWindow() -> Bool {
        final class Box: @unchecked Sendable { let lock = NSLock(); var report: SaveSyncReport?; var waiting = false }
        let app = NSApplication.shared
        defer { app.setActivationPolicy(.prohibited) }
        while true {
            let box = Box(), sem = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                let r = report()
                box.lock.lock(); box.report = r; box.lock.unlock()
                sem.signal()
                DispatchQueue.main.async { if box.waiting { app.abortModal() } }   // runs inside the waiting alert's modal loop, if there is one
            }
            if sem.wait(timeout: .now() + 0.5) == .timedOut {   // a cloud file to download: say so, and let the player go on without it
                app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Checking the cloud save…"
                a.informativeText = "Waiting for iCloud to deliver this game's save."
                a.addButton(withTitle: "Play Without It")
                a.addButton(withTitle: "Quit")
                box.waiting = true
                let answer = a.runModal()
                box.waiting = false
                if answer == .alertFirstButtonReturn { apply("offline"); return true }
                if answer == .alertSecondButtonReturn { return false }
                sem.wait()   // aborted: the report is in
            }
            box.lock.lock(); let r = box.report; box.lock.unlock()
            if case .play(let choice) = SaveSyncReport.step(r) { apply(choice); return true }
            app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
            switch ask(r, cancel: "Quit") {
            case .play(let choice): apply(choice); return true
            case .retry: continue
            case .cancel: return false
            }
        }
    }
}

// The Mac launcher (kid-with-sword-remake): the iPhone launcher's home (LauncherHome.swift: the background picture, the title, a round Play button, the Resolution Scale slider,
// the quick tiles and the All Settings drawer) in a wide window, made for a Mac: Return plays, ⌘, opens All Settings and Esc closes it, the tiles say what they do on hover, the
// Display Mode tile (window or full screen) stands where the iPhone has its microphone, and Look takes a picture from the Finder too. "Show this window at launch" stays, under Play
struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let done: (Bool) -> Void
    @AppStorage("window.show") private var show = true
    @State private var checking = false
    @State private var check = 0   // which Play the running check is for: one the player went on from without it is dropped
    @State private var drawer = false
    @State private var background = LauncherBackgroundStore.image()
    @State private var statusLine = ""
    private static let limitTile = ("DM_FPS_TARGET", "Frame Limit", "speedometer")
    private static let modeTile = ("DM_FULLSCREEN", "Display Mode", "macwindow")
    private static let tiles = [("DM_FRAMEGEN", "Frame Generation", "waveform.path"), ("DM_WIDE_VIEW", "Wide View", "arrow.left.and.right"), ("DM_MIC", "Ocarina Mic", "mic"), ("DM_METAL_HUD", "Performance HUD", "gauge.with.dots.needle.33percent")]

    var body: some View {
        ZStack {
            LauncherBackdrop(image: background)
            ZStack {
                titleBlock
                sideButtons
                bottomBar
            }
            .padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 26)   // the title bar is transparent: the picture runs under it
        }
        .overlay(alignment: .trailing) { drawerOverlay }
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 860, minHeight: 500)
        .background(alignment: .topLeading) {   // ⌘, toggles the drawer (a hidden button carries the shortcut)
            Button("") { toggleDrawer() }.keyboardShortcut(",", modifiers: .command).opacity(0).allowsHitTesting(false)
        }
        .task { statusLine = [launcherLastPlayed(), cloudLine()].compactMap { $0 }.joined(separator: " · ") }
    }

    private func cloudLine() -> String? {
        let env = getenv("DM_SAVE_SYNC").map { String(cString: $0) }
        let folder = env ?? (UserDefaults.standard.string(forKey: "cloudSaves.folder") ?? "")
        return folder.isEmpty || folder == "0" ? nil : "Cloud Saves On"
    }
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Continue Your Journey").font(.callout).foregroundStyle(LauncherTheme.soft)
            Text(LauncherBackgroundStore.title()).font(.system(size: 40, weight: .bold)).foregroundStyle(LauncherTheme.text)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 2).lineLimit(1).minimumScaleFactor(0.6)
            Text(statusLine).font(.callout).foregroundStyle(LauncherTheme.soft).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var sideButtons: some View {
        VStack(spacing: 12) {
            playButton
            Button { toggleDrawer() } label: {
                Label("All Settings", systemImage: "slider.horizontal.3").font(.callout.weight(.semibold)).foregroundStyle(LauncherTheme.text)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(LauncherTheme.paleGold.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain).help("All Settings (⌘,)")
            Toggle("Show this window at launch", isOn: $show).toggleStyle(.checkbox).font(.caption).foregroundStyle(LauncherTheme.soft)
                .help("Off: the game starts at once. Hold Option while opening the app to see this window again.")
            Button("Quit") { done(false) }.buttonStyle(.plain).font(.caption).foregroundStyle(LauncherTheme.soft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
    private var tileSettings: [(Setting, String, String)] {
        Self.tiles.compactMap { t in m.settings.first(where: { $0.env == t.0 && $0.kind == "toggle" }).map { ($0, t.1, t.2) } }
    }
    private func choice(_ t: (String, String, String)) -> Setting? { m.settings.first { $0.env == t.0 && $0.kind == "choice" && ($0.options?.count ?? 0) > 1 } }
    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let scale = m.settings.first(where: { $0.env == "DM_RENDER_SCALE" }) { ScaleSlider(m: m, scale: scale, width: 260) }
            if let l = choice(Self.limitTile) { ChoiceTile(m: m, s: l, title: Self.limitTile.1, icon: Self.limitTile.2).help("Frame Limit: click to switch") }
            ForEach(tileSettings, id: \.0.env) { t in QuickTile(m: m, s: t.0, title: t.1, icon: t.2).help(t.1 + ": click to turn on or off") }
            if let d = choice(Self.modeTile) { ChoiceTile(m: m, s: d, title: Self.modeTile.1, icon: Self.modeTile.2).help("Display Mode: a window or full screen") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
    private func toggleDrawer() { withAnimation(.easeOut(duration: 0.22)) { drawer.toggle() } }
    @ViewBuilder private var drawerOverlay: some View {
        if drawer {
            HStack(spacing: 0) {
                Color.black.opacity(0.001).onTapGesture { toggleDrawer() }
                AllSettingsDrawer(m: m, close: toggleDrawer, backgroundChanged: { background = LauncherBackgroundStore.image() }, memory: 0)
                    .frame(width: 440)
                    .overlay(alignment: .topTrailing) { Button("") { toggleDrawer() }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false) }   // Esc
            }
            .transition(.move(edge: .trailing))
        }
    }
    @ViewBuilder private var playButton: some View {
        Button(action: start) {
            Image(systemName: "play.fill").font(.system(size: 44, weight: .bold)).foregroundStyle(LauncherTheme.onGold).offset(x: 3)
                .frame(width: 120, height: 120)
                .background(LauncherTheme.gold, in: Circle())
                .overlay(Circle().strokeBorder(LauncherTheme.paleGold, lineWidth: 4))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(checking)
        .help("Play (Return)")
        .accessibilityLabel("Play")
        if checking {
            VStack(spacing: 6) {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking the Cloud Save…").font(.callout).foregroundStyle(LauncherTheme.soft) }
                Button("Play Without It") { checking = false; SaveCheck.apply("offline"); done(true) }.buttonStyle(.plain).font(.callout).foregroundStyle(LauncherTheme.paleGold)
            }
        } else {
            Text("Play").font(.title3.weight(.semibold)).foregroundStyle(LauncherTheme.paleGold).shadow(color: .black.opacity(0.6), radius: 6)
        }
    }

    /// Play, once the cloud's save is compared with this Mac's: a save that changed on both sides is the player's pick, not the newer file's (SaveCheck)
    private func start() {
        check += 1; checking = true
        let mine = check
        DispatchQueue.global(qos: .userInitiated).async {
            let r = SaveCheck.report()
            DispatchQueue.main.async {
                guard checking, check == mine else { return }   // the player played without it
                checking = false
                switch SaveCheck.ask(r, cancel: "Cancel") {
                case .play(let choice): SaveCheck.apply(choice); done(true)
                case .retry: start()
                case .cancel: break   // back to the window, nothing chosen
                }
            }
        }
    }
}

/// Cloud saves: a folder the save is synced through (dm/host/save_sync.h), the one the iPhone app picks in its launcher's Cloud saves section. It is kept in this app's
/// preferences as cloudSaves.folder, which launcher.c puts into DM_SAVE_SYNC before the host starts; a DM_SAVE_SYNC an env file or the launch environment set wins, and is shown here.
struct CloudSavesSection: View {
    @AppStorage("cloudSaves.folder") private var folder = ""
    private let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_SAVE_SYNC") || env["DM_SAVE_SYNC"] != nil ? env["DM_SAVE_SYNC"] : nil
    }()

    var body: some View {
        Section {
            LabeledContent("Cloud saves") {
                Text(fixed.map { "\(Self.shown($0)) (env.txt)" } ?? (folder.isEmpty ? "Off" : Self.shown(folder)))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            if fixed == nil {
                HStack {
                    Button(folder.isEmpty ? "Choose a folder…" : "Choose a different folder…", action: choose)
                    if !folder.isEmpty { Button("Turn off") { folder = "" } }
                }
            }
        } footer: {
            Text("Choose the iCloud Drive folder the iPhone app uses for this game. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in the save's -backups folder.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Use for Cloud Saves"
        panel.message = "The folder the iPhone app chose in its launcher's Cloud saves"
        panel.directoryURL = URL(fileURLWithPath: folder.isEmpty ? Self.drive : folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    static let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"   // iCloud Drive, as the Finder shows it

    /// A path under iCloud Drive as the Finder and the Files app name it: iCloud Drive › Documents › dev › Zelda; any other path as it is
    static func shown(_ path: String) -> String {
        guard path == drive || path.hasPrefix(drive + "/") else { return path }
        return (["iCloud Drive"] + path.dropFirst(drive.count).split(separator: "/").map(String.init)).joined(separator: " › ")
    }
}

private final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: LauncherModel
    var window: NSWindow?
    var play = false

    init(_ model: LauncherModel) { self.model = model }

    func applicationDidFinishLaunching(_ n: Notification) {
        let name = info("CFBundleName") ?? "Game"
        let menu = NSMenu(), item = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; menu.addItem(item); NSApp.mainMenu = menu
        // a wide window, the picture under a transparent title bar (kid-with-sword-remake: the iPhone launcher's look, LauncherView above)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = name; w.isReleasedWhenClosed = false; w.delegate = self
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)   // dark whatever the Mac's appearance, as on the iPhone
        w.contentMinSize = NSSize(width: 860, height: 500)
        window = w
        let host = NSHostingView(rootView: LauncherView(m: model, done: { [weak self] in self?.finish($0) }))
        w.contentView = host
        w.center()
        // no activation and no ordering in front of another app's windows: LaunchServices activates an app opened from Finder or the Dock (applicationDidBecomeActive), open -g does not
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderBack(nil) }
    }
    func applicationDidBecomeActive(_ n: Notification) { window?.makeKeyAndOrderFront(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {   // ⌘Q, or a logout or restart: the app ends without the game (exit 0, as Quit)
        fputs("launcher: quit without starting the game\n", stderr)
        return .terminateNow   // not terminateCancel, which a logout or restart takes as a refusal and stops
    }
    func windowWillClose(_ n: Notification) { finish(false) }

    func finish(_ play: Bool) {
        guard let w = window else { return }
        window = nil; self.play = play
        // The main thread blocks in launcher.c's waitpid once run() returns, so the window must leave the screen now: no fade-out (it runs on later run-loop passes),
        // and dmMacLauncher flushes the order-out (AppKit commits it at the end of a pass). Without both, the window stayed on screen, not responding, until the game ended
        w.animationBehavior = .none
        w.delegate = nil; w.orderOut(nil)
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)   // run returns at the next event
    }
}

enum LauncherWindowLayout {
    static func fitted(_ frame: NSRect, extraHeight: CGFloat, visible: NSRect) -> NSRect {
        let top = min(frame.maxY, visible.maxY)
        let height = min(frame.height + extraHeight, top - visible.minY)
        return NSRect(x: frame.minX, y: top - height, width: frame.width, height: height)
    }
}

// 1: Play (the window's settings are in the environment), 0: the player quit, 2: no window (no launcher.json, or "Show this window at launch" off): launcher.c applies the saved choices
@_cdecl("dm_mac_launcher")
public func dmMacLauncher() -> Int32 {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return 2 }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return 2 }
    if (UserDefaults.standard.object(forKey: "window.show") as? Bool) == false && !NSEvent.modifierFlags.contains(.option) {
        fputs("launcher: settings window off (hold Option at launch to show it)\n", stderr)
        return SaveCheck.withoutWindow() ? 2 : 0
    }
    let model = LauncherModel(file.settings)
    let app = NSApplication.shared, launcher = Launcher(model)
    app.setActivationPolicy(.regular)
    app.delegate = launcher
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    app.run()
    CATransaction.flush()   // finish's order-out
    app.setActivationPolicy(.prohibited)   // the host is the game's app from here on
    guard launcher.play else { fputs("launcher: quit without starting the game\n", stderr); return 0 }
    model.apply()
    return 1
}
