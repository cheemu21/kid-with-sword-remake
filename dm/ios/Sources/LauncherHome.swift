// The launcher's home (FF11): a title screen over a background picture, a round Play button, one Resolution Scale dial for the render scale and Cool mode, quick tiles for
// the settings players change most, and an All Settings drawer that slides over the right side with every setting by section, the cloud saves and the background (Look).
// Launcher.swift's LauncherView lays it out and keeps the Play logic (the cloud save check); the rows are LauncherRow.swift's, so the drawer, the in-game menu and the Mac
// window share one model (LauncherSettings.swift).
import SwiftUI
import PhotosUI
import UIKit

// The launcher's colours: a night forest with gold for what is on
enum LauncherTheme {
    static let night = Color(red: 0.043, green: 0.086, blue: 0.133)
    static let panel = Color(red: 0.059, green: 0.102, blue: 0.078)
    static let row = Color(red: 0.075, green: 0.129, blue: 0.102)
    static let line = Color(red: 0.169, green: 0.247, blue: 0.200)
    static let gold = Color(red: 0.788, green: 0.588, blue: 0.180)
    static let paleGold = Color(red: 0.953, green: 0.831, blue: 0.541)
    static let onGold = Color(red: 0.165, green: 0.110, blue: 0.020)
    static let text = Color(red: 0.933, green: 0.953, blue: 0.918)
    static let soft = Color(red: 0.702, green: 0.769, blue: 0.722)
    static let tileOn = Color(red: 0.165, green: 0.231, blue: 0.114)
}

// The background picture: one the player chose (Look › Choose Picture, saved as Documents/launcher_background.jpg), else one the build packed
// (build_ipa.sh DM_LAUNCHER_BG → dm/launcher_background.jpg, a player's own build only), else none (the drawn forest)
enum LauncherBackgroundStore {
    static var packedDir: URL? = Bundle.main.resourceURL?.appendingPathComponent("dm")   // the running program's dm folder (Launcher.swift sets it)
    static var imported: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("launcher_background.jpg") }
    static var hasImported: Bool { imported.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    static func image() -> UIImage? {
        for u in [imported, packedDir?.appendingPathComponent("launcher_background.jpg")].compactMap({ $0 }) where FileManager.default.fileExists(atPath: u.path) {
            if let i = UIImage(contentsOfFile: u.path) { return i }
        }
        return nil
    }
    // A picked photo, at most 2400 px on its long side, as a JPEG: a 48 MP photo would otherwise take about 190 MB of memory each time the launcher draws it
    static func save(_ data: Data) -> Bool {
        guard let img = UIImage(data: data), let u = imported else { return false }
        let s = img.size, k = min(1, 2400 / max(s.width, s.height, 1)), size = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpg = out.jpegData(compressionQuality: 0.88) else { return false }
        do { try jpg.write(to: u, options: .atomic); fputs("launcher: background picture saved (\(Int(size.width))x\(Int(size.height)))\n", stderr); return true }
        catch { fputs("[RED] launcher: background picture not saved: \(error.localizedDescription)\n", stderr); return false }
    }
    static func remove() { if let u = imported { try? FileManager.default.removeItem(at: u) } }
    // The title over the picture: dm/launcher_title.txt (build_ipa.sh DM_LAUNCHER_TITLE), else the app's name
    static func title() -> String {
        if let u = packedDir?.appendingPathComponent("launcher_title.txt"), let t = try? String(contentsOf: u, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Game"
    }
}

// The background: the picture, filling the screen, under two shades that keep the title (left) and the controls (bottom) readable; without one, a drawn night forest
struct LauncherBackdrop: View {
    let image: UIImage?
    var body: some View {
        ZStack {
            if let image {
                GeometryReader { g in Image(uiImage: image).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped() }
            } else {
                ForestBackdrop()
            }
            LinearGradient(colors: [Color.black.opacity(0.55), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.45, y: 0.5))
            LinearGradient(colors: [Color.black.opacity(0.72), .clear], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.6))
        }
        .ignoresSafeArea()
    }
}

// The drawn forest: a moon, stars, three ridges of trees and fireflies, in a 640 x 304 frame scaled to fill
struct ForestBackdrop: View {
    var body: some View {
        Canvas { ctx, size in
            let k = max(size.width / 640, size.height / 304), ox = (size.width - 640 * k) / 2, oy = (size.height - 304 * k) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * k, y: oy + y * k) }
            func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: Color) { ctx.fill(Path(ellipseIn: CGRect(x: ox + (x - r) * k, y: oy + (y - r) * k, width: 2 * r * k, height: 2 * r * k)), with: .color(c)) }
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(LauncherTheme.night))
            dot(470, 70, 44, Color(red: 0.11, green: 0.17, blue: 0.23)); dot(470, 70, 30, Color(red: 0.91, green: 0.89, blue: 0.76)); dot(482, 62, 6, Color(red: 0.84, green: 0.81, blue: 0.66))
            for (x, y) in [(60, 30), (140, 18), (230, 44), (320, 22), (560, 34), (610, 96), (390, 40)] as [(CGFloat, CGFloat)] { dot(x, y, 1.2, Color(red: 0.79, green: 0.84, blue: 0.90)) }
            func ridge(_ pts: [(CGFloat, CGFloat)], _ c: Color) {
                var path = Path(); path.move(to: p(0, 304)); for (x, y) in pts { path.addLine(to: p(x, y)) }; path.addLine(to: p(640, 304)); path.closeSubpath()
                ctx.fill(path, with: .color(c))
            }
            ridge([(0, 200), (40, 140), (70, 180), (110, 110), (150, 170), (190, 120), (230, 175), (270, 130), (310, 180), (350, 125), (400, 185), (440, 135), (490, 180), (530, 120), (580, 175), (640, 130)], Color(red: 0.071, green: 0.149, blue: 0.122))
            ridge([(0, 240), (30, 185), (55, 215), (85, 160), (120, 220), (160, 170), (200, 225), (245, 175), (290, 230), (330, 180), (380, 232), (420, 178), (470, 228), (515, 172), (560, 226), (600, 180), (640, 220)], Color(red: 0.055, green: 0.122, blue: 0.098))
            ridge([(0, 262), (160, 248), (320, 258), (480, 248), (640, 250)], Color(red: 0.039, green: 0.094, blue: 0.075))
            for (x, y) in [(210, 210), (350, 196), (420, 232), (560, 205), (120, 238)] as [(CGFloat, CGFloat)] { dot(x, y, 2, Color(red: 0.90, green: 0.83, blue: 0.54)) }
        }
    }
}

// A panel that lets the picture show through
private struct Glass: ViewModifier {
    var on = false
    func body(content: Content) -> some View {
        content
            .background(on ? AnyShapeStyle(LauncherTheme.tileOn.opacity(0.88)) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(on ? LauncherTheme.paleGold.opacity(0.55) : Color.white.opacity(0.10), lineWidth: 1))
    }
}

// Resolution Scale: one dial over the render scale and Cool mode. Its steps: Coolest (Cool mode: 3D at 50 % and smaller in-between frames), Cool (50 %), Balanced (60 %),
// Sharp (70 %), Sharpest (80 %); a render scale between steps shows at the nearest. Without Cool mode in the list it starts at Cool, without a render scale it is not drawn
struct HeatDial: View {
    @ObservedObject var m: LauncherModel
    let scale: Setting
    var width: CGFloat = 236
    private static let steps: [(String, Double)] = [("Coolest", 0.5), ("Cool", 0.5), ("Balanced", 0.6), ("Sharp", 0.7), ("Sharpest", 0.8)]
    private var hasCool: Bool { m.settings.contains { $0.env == "DM_COOL" } }
    private var lo: Int { hasCool ? 0 : 1 }
    private var level: Int {
        if hasCool && m.values["DM_COOL"] == "1" { return 0 }
        let v = Double(m.values[scale.env] ?? scale.def) ?? 0.6
        return (1...4).min { abs(Self.steps[$0].1 - v) < abs(Self.steps[$1].1 - v) } ?? 2
    }
    private func set(_ l: Int) {
        let l = max(lo, min(4, l)); guard l != level else { return }
        if hasCool { m.values["DM_COOL"] = l == 0 ? "1" : "0" }
        m.values[scale.env] = String(format: "%.2f", Self.steps[l].1)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resolution Scale").font(.caption).foregroundStyle(LauncherTheme.soft)
            HStack(spacing: 8) {
                GeometryReader { g in
                    let f = CGFloat(level - lo) / CGFloat(4 - lo), w = g.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14)).frame(height: 8)
                        Capsule().fill(LauncherTheme.gold).frame(width: max(8, w * f), height: 8)
                        Circle().fill(LauncherTheme.paleGold).frame(width: 20, height: 20).offset(x: (w - 20) * f)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in set(lo + Int((v.location.x / max(w, 1) * CGFloat(4 - lo)).rounded())) })
                }
                .frame(height: 22)
            }
            HStack {
                Text(Self.steps[level].0).font(.subheadline.weight(.semibold)).foregroundStyle(LauncherTheme.text)
                Spacer()
                Text(m.rangeLabel(scale, Double(m.values[scale.env] ?? scale.def) ?? 0.6)).font(.caption).monospacedDigit().foregroundStyle(LauncherTheme.soft).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: width)
        .modifier(Glass())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resolution Scale")
        .accessibilityValue(Self.steps[level].0)
        .accessibilityAdjustableAction { d in set(level + (d == .increment ? 1 : -1)) }
    }
}

// A quick tile: a toggle setting as a big button; one this phone can't use is dimmed and says why when tapped
struct QuickTile: View {
    @ObservedObject var m: LauncherModel
    let s: Setting
    let title: String, icon: String
    @State private var why = false
    private var on: Bool { (m.values[s.env] ?? s.def) == s.onValue }
    private var blocked: String? { LauncherModel.unavailable[s.env] ?? (m.fixed.contains(s.env) ? (m.fromLaunch.contains(s.env) ? "Set at launch." : "Set by an env file.") : nil) }
    var body: some View {
        Button {
            if blocked != nil { why = true; return }
            m.values[s.env] = on ? s.offValue : s.onValue
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(alignment: .leading) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 2)
                Text(title).font(.caption.weight(.semibold)).multilineTextAlignment(.leading).lineLimit(2).minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? LauncherTheme.paleGold : LauncherTheme.soft)
            .frame(width: 66, height: 52, alignment: .leading)
            .padding(9)
            .modifier(Glass(on: on))
            .opacity(blocked == nil ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "On" : "Off")
        .alert(title, isPresented: $why) { Button("OK", role: .cancel) {} } message: { Text(blocked ?? "") }
    }
}

// Look: the background picture (a photo from the library, or back to the default)
struct LookSection: View {
    let changed: () -> Void
    @State private var pick: PhotosPickerItem?
    @State private var note = ""
    @State private var has = LauncherBackgroundStore.hasImported
    var body: some View {
        Section {
            PhotosPicker(selection: $pick, matching: .images) {
                Label(has ? "Choose a Different Picture" : "Choose Picture", systemImage: "photo.on.rectangle")
            }
            if has {
                Button(role: .destructive) { LauncherBackgroundStore.remove(); has = false; note = "Back to the default background."; changed() } label: {
                    Label("Use Default Background", systemImage: "arrow.uturn.backward")
                }
            }
        } header: { Text("Background") } footer: {
            Text(note.isEmpty ? "A picture from your library behind the launcher. It stays on this iPhone." : note)
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let ok = data.map(LauncherBackgroundStore.save) ?? false
                await MainActor.run { pick = nil; has = LauncherBackgroundStore.hasImported; note = ok ? "Saved." : "That picture couldn't be used. Try another one."; if ok { changed() } }
            }
        }
    }
}

// All Settings: a drawer over the right side with the list's sections, then Saves (cloud saves, memory) and Look (the background)
struct AllSettingsDrawer: View {
    @ObservedObject var m: LauncherModel
    let close: () -> Void
    let backgroundChanged: () -> Void
    let memory: Int
    @State private var tab = ""
    private var tabs: [String] { m.sections.filter { !m.rows(in: $0).isEmpty } + ["Saves", "Look"] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("All Settings").font(.headline).foregroundStyle(LauncherTheme.text)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(LauncherTheme.soft).padding(6) }
                    .accessibilityLabel("Close")
            }
            ViewThatFits(in: .horizontal) {
                tabRow(pad: 12)
                tabRow(pad: 8)
                ScrollView(.horizontal, showsIndicators: false) { tabRow(pad: 8) }
            }
            List {
                switch current {
                case "Saves":
                    CloudSavesSection().listRowBackground(LauncherTheme.row)
                case "Look":
                    LookSection(changed: backgroundChanged).listRowBackground(LauncherTheme.row)
                default:
                    Section { ForEach(m.rows(in: current)) { SettingRow(s: $0, m: m) } }.listRowBackground(LauncherTheme.row)
                    if current == "Performance" {
                        Section {
                            HStack { Text("Memory Available"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary) }
                        }
                        .listRowBackground(LauncherTheme.row)
                    }
                    Section {
                        Button("Reset to Tested Defaults") { m.reset() }.disabled(!m.changed).foregroundStyle(m.changed ? LauncherTheme.paleGold : LauncherTheme.soft)
                    } footer: { Text("Brings back all settings this game was tested with.") }
                    .listRowBackground(LauncherTheme.row)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
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
    }
    private var current: String { tabs.contains(tab) ? tab : (tabs.first ?? "Saves") }
    private func tabRow(pad: CGFloat) -> some View {
        HStack(spacing: 5) {
            ForEach(tabs, id: \.self) { t in
                let on = t == current
                Button { tab = t } label: {
                    Text(t).font(.caption.weight(.semibold)).lineLimit(1).padding(.horizontal, pad).padding(.vertical, 6)
                        .foregroundStyle(on ? LauncherTheme.paleGold : LauncherTheme.soft)
                        .background(on ? LauncherTheme.tileOn : LauncherTheme.row, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? LauncherTheme.paleGold.opacity(0.5) : LauncherTheme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }

}

// When the game was last saved: the newest file in the save folder (DM_SAVE), "Today at 9:41 PM"
func launcherLastPlayed() -> String? {
    guard let s = getenv("DM_SAVE") else { return nil }
    let root = URL(fileURLWithPath: String(cString: s))
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return nil }
    var newest: Date?
    for case let u as URL in e {
        guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true, let d = v.contentModificationDate else { continue }
        if newest.map({ d > $0 }) ?? true { newest = d }
    }
    guard let d = newest else { return nil }
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
    return "Last Played " + f.string(from: d)
}
