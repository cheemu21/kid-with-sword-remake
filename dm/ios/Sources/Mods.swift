// Mods: replacement game files from the player (Documents/mods/<name>/romfs/..., the usual Switch layout), served over the game's files when they are on (dm/host/mods.h).
// The launcher's Mods button (Launcher.swift) opens this panel: Import Mod (a .zip, or a folder, which iOS zips for us), the installed mods with a switch each, their order
// (the higher one wins when two change the same file) and delete. The order and the mods turned off are kept in UserDefaults; a mod folder put into Documents/mods with
// the Files app shows up too, on. At Play, DM_MODS lists the romfs folders of the mods that are on, top first (ModStore.applyEnv); with none on it is unset and the game
// starts exactly as without this feature.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ModStore: ObservableObject {
    struct Mod: Identifiable, Equatable {
        let id: String            // its folder's name
        var on: Bool
        var valid: Bool           // it has a romfs folder (and a name the list can carry)
        var files = 0
        var bytes: Int64 = 0
        var note = ""             // what the check found
        var warn = false
    }
    static let shared = ModStore()
    static var dir: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mods", isDirectory: true) }
    private static let orderKey = "dm.mods.order", offKey = "dm.mods.off"

    @Published private(set) var mods: [Mod] = []
    @Published private(set) var busy = false
    @Published var message: String?
    private var generation = 0

    var enabledCount: Int { mods.filter { $0.on && $0.valid }.count }

    init() { mods = Self.scan() }

    /// The folders in Documents/mods (hidden ones are the host's), in the saved order, then new ones by name; each on unless turned off
    static func scan() -> [Mod] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { n in
            var d: ObjCBool = false
            return !n.hasPrefix(".") && fm.fileExists(atPath: dir.appendingPathComponent(n).path, isDirectory: &d) && d.boolValue
        }
        let defaults = UserDefaults.standard
        let order = defaults.stringArray(forKey: orderKey) ?? [], off = Set(defaults.stringArray(forKey: offKey) ?? [])
        let listed = order.filter(names.contains) + names.filter { !order.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return listed.map { n in
            var d: ObjCBool = false
            let romfs = fm.fileExists(atPath: dir.appendingPathComponent(n).appendingPathComponent("romfs").path, isDirectory: &d) && d.boolValue
            return Mod(id: n, on: !off.contains(n), valid: romfs && !n.contains(":"))   // DM_MODS is ':'-separated
        }
    }
    /// DM_MODS for the host: the romfs folders of the mods that are on, top of the list first. Unset when none is on
    @discardableResult static func applyEnv() -> Int {
        let on = scan().filter { $0.on && $0.valid }.map { dir.appendingPathComponent($0.id).appendingPathComponent("romfs").path }
        if on.isEmpty { unsetenv("DM_MODS") } else { setenv("DM_MODS", on.joined(separator: ":"), 1) }
        fputs("launcher: \(on.count) mod(s) on\n", stderr)
        return on.count
    }

    func reload() {
        var list = Self.scan()
        for i in list.indices { if let old = mods.first(where: { $0.id == list[i].id }) { list[i].files = old.files; list[i].bytes = old.bytes; list[i].note = old.note; list[i].warn = old.warn } }
        mods = list; save(); check()
    }
    private func save() {
        UserDefaults.standard.set(mods.map(\.id), forKey: Self.orderKey)
        UserDefaults.standard.set(mods.filter { !$0.on }.map(\.id), forKey: Self.offKey)
    }
    func setOn(_ id: String, _ on: Bool) {
        guard let i = mods.firstIndex(where: { $0.id == id }) else { return }
        mods[i].on = on; save(); check()
    }
    func move(from: IndexSet, to: Int) { mods.move(fromOffsets: from, toOffset: to); save(); check() }
    func delete(_ id: String) {
        do { try FileManager.default.removeItem(at: Self.dir.appendingPathComponent(id)) } catch { message = "\(id) couldn't be deleted: \(error.localizedDescription)" }
        reload()
    }

    /// Each mod's files, size and what the size table makes of it (dm_mods_check), and which of its files a mod above it that is on also has
    private func check() {
        generation += 1
        let gen = generation, list = mods
        DispatchQueue.global(qos: .utility).async {
            var seen: [String: String] = [:]   // file → the first mod that is on and has it
            var out = list
            for i in out.indices {
                let m = out[i]
                guard m.valid else {
                    out[i].note = m.id.contains(":") ? "Its name has a colon (:). Rename the folder in the Files app." : "No romfs folder inside, so it isn't used. A mod's files go in a folder named romfs."
                    out[i].warn = true; continue
                }
                let romfs = Self.dir.appendingPathComponent(m.id).appendingPathComponent("romfs")
                var files: [String] = [], bytes: Int64 = 0
                if let e = FileManager.default.enumerator(atPath: romfs.path) {   // paths relative to romfs (the host skips hidden names at every level, so this does)
                    while let rel = e.nextObject() as? String {
                        guard let a = e.fileAttributes, a[.type] as? FileAttributeType == .typeRegular, !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
                        files.append(rel); bytes += (a[.size] as? NSNumber)?.int64Value ?? 0
                    }
                }
                var c = [Int32](repeating: 0, count: 6)
                romfs.path.withCString { dm_mods_check($0, &c) }
                var lines = ["\(files.count) file\(files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"]
                var warn = false
                if c[3] > 0 { lines.append("\(c[3]) file\(c[3] == 1 ? " is" : "s are") bigger than the game has room for. The game may crash when it loads \(c[3] == 1 ? "it" : "them")."); warn = true }
                else if c[5] != 0 && c[1] > 0 { lines.append("\(c[1]) file\(c[1] == 1 ? " is" : "s are") bigger than the original\(c[1] == 1 ? "" : "s"), and this copy of the app can't make room for \(c[1] == 1 ? "it" : "them"). Build the app again with this version, or the game may crash."); warn = true }
                else if c[2] > 0 { lines.append("\(c[2]) file\(c[2] == 1 ? " is" : "s are") bigger than the original\(c[2] == 1 ? "" : "s"). The game's size table makes room for \(c[2] == 1 ? "it" : "them") when you press Play.") }
                if c[4] > 0 { lines.append("Brings its own copy of the game's size table. The app uses its own merged table instead.") }
                if m.on {
                    var under: [String: Int] = [:]
                    for f in files { if let top = seen[f] { under[top, default: 0] += 1 } else { seen[f] = m.id } }
                    for (top, n) in under.sorted(by: { $0.key < $1.key }) { lines.append("\(n) of its files are also in \(top), higher in the list, so \(top)'s are used.") }
                }
                out[i].files = files.count; out[i].bytes = bytes; out[i].note = lines.joined(separator: "\n"); out[i].warn = warn
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                for o in out { if let i = self.mods.firstIndex(where: { $0.id == o.id }) { self.mods[i].files = o.files; self.mods[i].bytes = o.bytes; self.mods[i].note = o.note; self.mods[i].warn = o.warn } }
            }
        }
    }

    /// Imports a .zip, or a folder (zipped by iOS, which also downloads it from iCloud first); the new mods go to the top of the list, on
    func importItem(at url: URL) {
        busy = true; message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var d: ObjCBool = false
            let folder = FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
            let name = folder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            var result: (count: Int, msg: String, added: [String]) = (0, "", [])
            var err: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: folder ? .forUploading : [], error: &err) { u in result = Self.importZip(u.path, name: name) }
            if let err { result = (0, "The file couldn't be read: \(err.localizedDescription)", []) }
            DispatchQueue.main.async {
                self.busy = false
                if result.count > 0 {
                    let order = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
                    UserDefaults.standard.set(result.added + order.filter { !result.added.contains($0) }, forKey: Self.orderKey)
                    self.message = "Added \(result.added.joined(separator: ", ")). " + result.msg
                } else { self.message = result.msg }
                self.reload()
            }
        }
    }
    private static func importZip(_ path: String, name: String) -> (count: Int, msg: String, added: [String]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var msg = [CChar](repeating: 0, count: 1024), added = [CChar](repeating: 0, count: 4096)
        let n = dm_mods_import(path, dir.path, name, &msg, msg.count, &added, added.count)
        return (Int(n), String(cString: msg), String(cString: added).split(separator: "\n").map(String.init))
    }
}

/// The Mods panel: over the right side of the launcher, as All Settings is
struct ModsDrawer: View {
    @ObservedObject var store: ModStore
    let close: () -> Void
    @State private var picking = false
    @State private var editing = false
    @State private var deleting: ModStore.Mod?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mods").font(.headline).foregroundStyle(LauncherTheme.text)
                Spacer()
                if store.mods.count > 1 {
                    Button(editing ? "Done" : "Change Order") { withAnimation { editing.toggle() } }.font(.footnote.weight(.semibold)).foregroundStyle(LauncherTheme.paleGold)
                }
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(LauncherTheme.soft).padding(6) }
                    .accessibilityLabel("Close")
            }
            List {
                Section {
                    Button { picking = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 18)).foregroundStyle(LauncherTheme.paleGold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Import Mod…").foregroundStyle(LauncherTheme.text)
                                Text("A .zip file or a folder from Files").font(.caption).foregroundStyle(LauncherTheme.soft)
                            }
                            Spacer()
                            if store.busy { ProgressView() }
                        }
                    }
                    .disabled(store.busy)
                    // the sheet sits on the button, not on the Section (Launcher.swift CloudSavesSection: a Section hands its modifiers to every row)
                    .sheet(isPresented: $picking) {
                        ModPicker { url in picking = false; store.importItem(at: url) } onCancel: { picking = false }
                    }
                } footer: {
                    if let m = store.message { Text(m) }
                }
                .listRowBackground(LauncherTheme.row)
                if !store.mods.isEmpty {
                    Section {
                        ForEach(store.mods) { mod in
                            ModRow(mod: mod, on: Binding(get: { mod.on }, set: { store.setOn(mod.id, $0) }))
                                .swipeActions { Button(role: .destructive) { deleting = mod } label: { Label("Delete", systemImage: "trash") } }
                                .contextMenu { Button(role: .destructive) { deleting = mod } label: { Label("Delete", systemImage: "trash") } }
                        }
                        .onMove { store.move(from: $0, to: $1) }
                    } header: {
                        Text("Installed · Top of the List Wins")
                    } footer: {
                        Text("When two mods change the same file, the one higher in the list is used. Mods load when you press Play, over the app's own amiibo files. You can also copy a mod folder (with its romfs folder inside) into this app's mods folder in the Files app.")
                    }
                    .listRowBackground(LauncherTheme.row)
                }
            }
            .environment(\.editMode, .constant(editing ? .active : .inactive))
            .launcherListStyle()
            .listRowSeparatorTint(LauncherTheme.line)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .contentMargins(.top, 2, for: .scrollContent)
            .tint(LauncherTheme.gold)
        }
        .padding(14)
        .background(LauncherTheme.panel)
        .compositingGroup()
        .overlay(alignment: .leading) { Rectangle().fill(LauncherTheme.line).frame(width: 1) }
        .onAppear { store.reload() }
        .confirmationDialog("Delete \(deleting?.id ?? "this mod")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { mod in
            Button("Delete Mod", role: .destructive) { store.delete(mod.id); deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in Text("Its files are removed from this iPhone. Your saves aren't touched.") }
    }
}

private struct ModRow: View {
    let mod: ModStore.Mod
    @Binding var on: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(mod.id).foregroundStyle(LauncherTheme.text).lineLimit(2)
                if !mod.note.isEmpty {
                    Text(mod.note).font(.caption).foregroundStyle(mod.warn ? Color.orange : LauncherTheme.soft).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $on).labelsHidden().disabled(!mod.valid)
        }
        .padding(.vertical, 2)
    }
}

/// Files: a .zip (or another archive, so the import can say what it is) or a folder. .open, not .import: a folder can't be copied in whole, and the import reads it through a coordinator
private struct ModPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.zip, .folder, .archive] + ["7z", "rar"].compactMap { UTType(filenameExtension: $0) }
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
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) { self.onPick = onPick; self.onCancel = onCancel }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if let u = urls.first { onPick(u) } else { onCancel() } }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}
