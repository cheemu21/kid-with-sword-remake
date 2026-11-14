// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json (an app of several programs: dm/p<N>/launcher.json), which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) starts at that value and can still be changed (LauncherSettings.swift fromFile). All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
                .sheet(isPresented: $picking) {
                    DocumentPicker(types: [.folder]) { url in
                        picking = false
                        if dm_store_cloud_saves(url) {
                            note = "Saved. The game uses this folder when you press Play."
                            refresh()
                        } else {
                            note = "That folder could not be remembered — try a different one."
                        }
                    } onCancel: { picking = false }
                }
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    @State private var checking = false
    @State private var check = 0   // which Play the running check is for: one the player went on from without it is dropped
    @State private var report: SaveSyncReport?
    @State private var asking: SaveSyncReport.Step?
    @State private var drawer = false
    @State private var background = LauncherBackgroundStore.image()
    @State private var statusLine = ""
    // The quick tiles: the toggles players change most (the drawer has them too); a game without one shows the rest
    private static let tiles = [("DM_FRAMEGEN", "Frame Generation", "waveform.path"), ("DM_COOL", "Cool Mode", "snowflake"), ("DM_WIDE_VIEW", "Wide View", "arrow.left.and.right"), ("DM_MIC", "Ocarina Mic", "mic")]

    var body: some View {
        ZStack {
            LauncherBackdrop(image: background)
            GeometryReader { g in
                ZStack {
                    titleBlock
                    sideButtons
                    bottomBar(width: g.size.width - 140)   // the room left of Play
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .overlay(alignment: .trailing) { drawerOverlay }
        .preferredColorScheme(.dark)
        .confirmationDialog(SaveSyncReport.chooseTitle, isPresented: isAsking(.choose), titleVisibility: .visible, presenting: report) { r in
            Button(r.localLabel(here: "iPhone")) { go(r.localChoice) }
            Button(r.cloudLabel) { go(r.cloudChoice) }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.chooseMessage(here: "iPhone")) }
        .confirmationDialog(SaveSyncReport.unreadableTitle, isPresented: isAsking(.unreadable), titleVisibility: .visible, presenting: report) { r in
            Button("Play This iPhone's Save") { go("offline") }   // the mount does not wait for the cloud again
            Button("Try Again") { DispatchQueue.main.async { start() } }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.unreadableMessage(here: "iPhone")) }
        .task {
            var stale: ObjCBool = false
            let cloud = (dm_cloud_saves_path(&stale) ?? "").isEmpty ? nil : "Cloud Saves On"
            statusLine = [launcherLastPlayed(), cloud].compactMap { $0 }.joined(separator: " · ")
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // the title over the picture
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Continue Your Journey").font(.footnote).foregroundStyle(LauncherTheme.soft)
            Text(LauncherBackgroundStore.title()).font(.system(size: 28, weight: .bold)).foregroundStyle(LauncherTheme.text)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 2).lineLimit(1).minimumScaleFactor(0.6)
            Text(statusLine).font(.footnote).foregroundStyle(LauncherTheme.soft).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    // Play, and All Settings under it
    private var sideButtons: some View {
        VStack(spacing: 10) {
            playButton
            Button { withAnimation(.easeOut(duration: 0.25)) { drawer = true } } label: {
                Label("All Settings", systemImage: "slider.horizontal.3").font(.footnote.weight(.semibold)).foregroundStyle(LauncherTheme.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(LauncherTheme.paleGold.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
    private var tileSettings: [(Setting, String, String)] {
        Self.tiles.compactMap { t in m.settings.first(where: { $0.env == t.0 && $0.kind == "toggle" }).map { ($0, t.1, t.2) } }
    }
    // the dial and the quick tiles: in one row where it fits (an iPhone 18 Pro's 874 points), else the tiles two by two beside the dial (an iPhone Duo's 678), else above it
    @ViewBuilder private func dial(_ w: CGFloat = 236) -> some View {
        if let scale = m.settings.first(where: { $0.env == "DM_RENDER_SCALE" }) { HeatDial(m: m, scale: scale, width: w) }
    }
    private func tile(_ t: (Setting, String, String)) -> some View { QuickTile(m: m, s: t.0, title: t.1, icon: t.2) }
    private var tileGrid: some View {
        let rows = stride(from: 0, to: tileSettings.count, by: 2).map { Array(tileSettings[$0..<min($0 + 2, tileSettings.count)]) }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(rows.indices, id: \.self) { r in HStack(spacing: 10) { ForEach(rows[r], id: \.0.env) { tile($0) } } }
        }
    }
    private func bottomBar(width: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) { dial(); ForEach(tileSettings, id: \.0.env) { tile($0) } }
            HStack(alignment: .bottom, spacing: 10) { dial(200); tileGrid }
            VStack(alignment: .leading, spacing: 10) { tileGrid; dial() }
        }
        .frame(maxWidth: max(width, 236), alignment: .bottomLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
    private func closeDrawer() { withAnimation(.easeOut(duration: 0.25)) { drawer = false } }
    @ViewBuilder private var drawerOverlay: some View {
        if drawer {
            GeometryReader { g in
                HStack(spacing: 0) {
                    Color.black.opacity(0.001).onTapGesture(perform: closeDrawer)
                    AllSettingsDrawer(m: m, close: closeDrawer, backgroundChanged: { background = LauncherBackgroundStore.image() }, memory: memory)
                        .frame(width: max(360, g.size.width * 0.6))
                }
            }
            .ignoresSafeArea(edges: .vertical)
            .transition(.move(edge: .trailing))
        }
    }

    @ViewBuilder var playButton: some View {
        Button(action: start) {
            Image(systemName: "play.fill").font(.system(size: 40, weight: .bold)).foregroundStyle(LauncherTheme.onGold).offset(x: 3)
                .frame(width: 112, height: 112)
                .background(LauncherTheme.gold, in: Circle())
                .overlay(Circle().strokeBorder(LauncherTheme.paleGold, lineWidth: 4))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(checking)
        .accessibilityLabel("Play")
        if checking {
            VStack(spacing: 6) {
                HStack(spacing: 6) { ProgressView(); Text("Checking the Cloud Save…").font(.footnote).foregroundStyle(LauncherTheme.soft) }
                Button("Play Without It") { checking = false; go("offline") }.font(.footnote).foregroundStyle(LauncherTheme.paleGold)
            }
        } else {
            Text("Play").font(.headline).foregroundStyle(LauncherTheme.paleGold).shadow(color: .black.opacity(0.6), radius: 6)
        }
    }

    private func isAsking(_ step: SaveSyncReport.Step) -> Binding<Bool> {
        Binding(get: { asking == step }, set: { if !$0 && asking == step { asking = nil } })
    }

    /// Play, once the cloud's save is compared with this iPhone's (save_sync_report, SaveSyncReport): a save that changed on both sides is the player's pick, not the
    /// newer file's, and a cloud save that did not come is said so before the game starts without it.
    private func start() {
        check += 1; checking = true; asking = nil
        let mine = check
        dm_cloud_saves_env()   // DM_SAVE_SYNC from the picked folder, as the game's mount will read it (front_ios.m calls it again at the start)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.compare()
            DispatchQueue.main.async {
                guard checking, check == mine else { return }   // the player played without it
                checking = false
                switch SaveSyncReport.step(r) {
                case .play(let choice): go(choice)
                case let step: report = r; asking = step
                }
            }
        }
    }

    /// Blocks while the cloud's file downloads (SaveSyncReport.waitMs at most). nil: no report (the host then decides as it always did)
    private static func compare() -> SaveSyncReport? {
        // getenv, not ProcessInfo.environment: main.m sets DM_SAVE and applies env.txt after that snapshot
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        guard save_sync_report(save, dm_save_title(), nil, SaveSyncReport.waitMs, &buf, buf.count) == 0 else {
            fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr)
            return nil
        }
        let line = String(cString: buf)
        fputs("launcher: save sync: \(line)\n", stderr)
        return SaveSyncReport(line: line)
    }

    private func go(_ choice: String?) {
        asking = nil
        if let choice { setenv("DM_SAVE_SYNC_CHOICE", choice, 1); fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr) }
        play()
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// This phone's starting values and the settings it can't use (LauncherModel.deviceDefaults / unavailable), before the model reads them.
// Under 10 GB of memory (the iPhone 16, 16 Pro and 17 have 8 GB) Cool mode starts on: Ocarina of Time's footprint reached about 5.9 GB on a 12 GB iPhone 18 Pro (log 23),
// and Cool mode's smaller 3D views and in-between frames take less memory and GPU time. A phone without MetalFX's Metal 4 frame interpolator gets no frame generation
// (the host's own check, nvn_mtl.m, leaves the game at 30 and records it for the next start; the launcher makes no Metal device, issue #840)
private func deviceSetup() {
    let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    if gb < 10 {
        LauncherModel.deviceDefaults["DM_COOL"] = "1"
        fputs(String(format: "launcher: this phone has %.1f GB of memory: Cool mode on by default\n", gb), stderr)
    }
    // what the game found the last time it started (nvn_mtl.m fg_on): making a Metal device here, before startGame applies DM_METAL_HUD, would keep the Performance HUD off
    if UserDefaults.standard.bool(forKey: "dm.framegen.unsupported") {
        LauncherModel.unavailable["DM_FRAMEGEN"] = "This iPhone can't make in-between frames: MetalFX frame interpolation needs a newer chip. The game shows its own 30 fps."
        fputs("launcher: frame generation unavailable (the last start found no Metal 4 MetalFX frame interpolator)\n", stderr)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    // a game of several programs (main.m): the running program's settings, in its dm/p<N>
    let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
    guard let url = dir?.appendingPathComponent("launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    deviceSetup()
    LauncherBackgroundStore.packedDir = dir
    let model = LauncherModel(file.settings)
    do {   // the screen's shape for the render scale's size in pixels with Wide view (LauncherSettings.swift rangeLabel), measured as front_ios.m does
        let sz = UIScreen.main.bounds.size, lo = min(sz.width, sz.height)
        if lo > 0 { LauncherModel.screenAspect = Double(max(sz.width, sz.height) / lo) }
    }
    gameMenuModel = model   // the in-game menu shows and saves the same choices (GameMenu.swift)
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); model.applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = DmHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
