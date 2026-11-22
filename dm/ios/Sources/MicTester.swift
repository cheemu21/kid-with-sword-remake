// The launcher's microphone tester (kid-with-sword-remake L8): hum or whistle and see what the game would hear, before playing. It runs the capture the game gets (48 kHz mono, the
// voice leveler of mic_level.h at the Mic Sensitivity slider, as mic_apple.m does) and measures it as Ocarina of Time does: the RMS of each 512-frame block in dBFS, clamped to
// -76..0 (main+0x336f090), a note starting at -32 dBFS and ending under -52 on the main microphone (main+0x336e000). The pitch shown is the tester's own estimate (YIN over 1024
// samples), to tell the player which of the ocarina's notes a hum is nearest; the game's own pitch analysis is not read
import SwiftUI
import AVFoundation

final class MicTestEngine: ObservableObject {
    static let rate = 48_000.0
    static let gameBlock = 512                       // the game's level block (main+0x336f090)
    static let floorDB: Float = -76, noteOnDB: Float = -32, noteOffDB: Float = -52

    @Published var rawDB: Float = MicTestEngine.floorDB    // the microphone as captured
    @Published var gameDB: Float = MicTestEngine.floorDB   // after the leveler: what the game measures
    @Published var backgroundDB: Float = MicTestEngine.floorDB
    @Published var note = false                            // the game's gate on the main microphone
    @Published var pitchHz: Float = 0
    @Published var running = false
    @Published var problem: String?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()                            // the leveler's settings (main thread) against the capture (the tap's thread)
    private var level = mic_level()
    // The tap's thread only
    private var rawAcc = 0.0, gameAcc = 0.0, blockN = 0, gate = false, published = 0
    private var window = [Float](repeating: 0, count: 2048), windowN = 0, lastPitch: Float = 0

    private static func db(_ meanSquare: Double) -> Float {
        guard meanSquare > 0 else { return floorDB }
        return min(0, max(floorDB, Float(10 * log10(meanSquare))))
    }

    func setSensitivity(_ v: String) {
        var b: Float = 0, g: Float = 0
        _ = mic_level_preset(v, &b, &g)
        lock.lock(); level.boost_db = b; level.margin_db = g; lock.unlock()
    }

    func start(sensitivity: String) {
        guard !running else { return }
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted { self.begin(sensitivity) } else { self.problem = "Microphone access is off for this app. Turn it on in the Settings app, under Privacy & Security, Microphone." }
            }
        }
    }

    private func begin(_ sensitivity: String) {
        let s = AVAudioSession.sharedInstance()
        do {   // as the game's session with Ocarina Mic on (front_ios.m)
            try s.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try s.setActive(true)
        } catch { problem = "The microphone could not start: \(error.localizedDescription)"; return }
        let input = engine.inputNode, hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0,
              let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: hw, to: out) else { problem = "This device has no microphone the app can use."; return }
        converter = conv
        var b: Float = 0, g: Float = 0
        _ = mic_level_preset(sensitivity, &b, &g)
        lock.lock(); mic_level_init(&level, b, g); lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buf, _ in self?.capture(buf, out) }
        do { try engine.start(); running = true; problem = nil }
        catch { input.removeTap(onBus: 0); problem = "The microphone could not start: \(error.localizedDescription)" }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0); engine.stop(); running = false
    }

    private func capture(_ buf: AVAudioPCMBuffer, _ out: AVAudioFormat) {   // the tap's thread
        guard let conv = converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * Self.rate / buf.format.sampleRate) + 16
        guard let o = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return }
        var given = false
        _ = conv.convert(to: o, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        guard let ch = o.floatChannelData?[0] else { return }
        let n = Int(o.frameLength)
        let raw = Array(UnsafeBufferPointer(start: ch, count: n))
        lock.lock(); mic_level_run(&level, ch, Int32(n)); let background = level.floor_db; lock.unlock()
        for i in 0..<n {
            let r = raw[i], g = ch[i]
            rawAcc += Double(r * r); gameAcc += Double(g * g); blockN += 1
            window[windowN] = g; windowN += 1
            if windowN == window.count { lastPitch = gate ? Self.pitch(window) : 0; window.replaceSubrange(0..<1024, with: window[1024...]); windowN = 1024 }
            guard blockN == Self.gameBlock else { continue }
            let rdb = Self.db(rawAcc / Double(blockN)), gdb = Self.db(gameAcc / Double(blockN))
            rawAcc = 0; gameAcc = 0; blockN = 0
            if !gate && gdb >= Self.noteOnDB { gate = true } else if gate && gdb < Self.noteOffDB { gate = false }
            published += 1
            if published % 4 == 0 {   // about 23 updates a second
                let on = gate, hz = gate ? lastPitch : 0, bg = background.isFinite ? max(Self.floorDB, background) : Self.floorDB
                DispatchQueue.main.async { self.rawDB = rdb; self.gameDB = gdb; self.note = on; self.pitchHz = hz; self.backgroundDB = bg }
            }
        }
    }

    // YIN (de Cheveigné and Kawahara 2002) over the last 2048 samples: the fundamental between 70 Hz and 2 kHz, 0 when nothing is periodic enough
    static func pitch(_ x: [Float]) -> Float {
        let w = 1024, minLag = Int(rate / 2000), maxLag = Int(rate / 70)
        var d = [Float](repeating: 0, count: maxLag + 2)
        x.withUnsafeBufferPointer { p in
            for tau in 1...maxLag + 1 {
                var s: Float = 0
                for i in 0..<w { let e = p[i] - p[i + tau]; s += e * e }
                d[tau] = s
            }
        }
        var run: Float = 0
        for tau in 1...maxLag + 1 { run += d[tau]; d[tau] = run > 0 ? d[tau] * Float(tau) / run : 1 }
        var tau = minLag
        while tau <= maxLag {
            if d[tau] < 0.15 {
                while tau + 1 <= maxLag && d[tau + 1] < d[tau] { tau += 1 }
                let a = d[tau - 1], b = d[tau], c = d[tau + 1], den = a - 2 * b + c
                let t = Float(tau) + (abs(den) > 1e-9 ? 0.5 * (a - c) / den : 0)
                return Float(rate) / t
            }
            tau += 1
        }
        return 0
    }
}

struct MicTesterView: View {
    @ObservedObject var m: LauncherModel
    @StateObject private var mic = MicTestEngine()
    @Environment(\.dismiss) private var dismiss
    private var rows: [Setting] { m.settings.filter { $0.env == "DM_MIC" || $0.env == "DM_MIC_BOOST" } }
    private var sensitivity: String { m.values["DM_MIC_BOOST"] ?? m.settings.first { $0.env == "DM_MIC_BOOST" }?.def ?? "0.6" }
    private var micOn: Bool { guard let s = m.settings.first(where: { $0.env == "DM_MIC" }) else { return true }; return (m.values[s.env] ?? s.def) == s.onValue }

    // The ocarina's five notes (D F A B D): the nearest by pitch class, and how far off in cents
    private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    private static let ocarina: [(Int, String)] = [(2, "D"), (5, "F"), (9, "A"), (11, "B")]
    private var pitchText: (String, String) {
        guard mic.note, mic.pitchHz > 0 else { return ("—", mic.note ? "Hold a steady hum or whistle" : "Hum or whistle a note") }
        let midi = 69 + 12 * log2(Double(mic.pitchHz) / 440), nearest = Int(midi.rounded()), pc = ((nearest % 12) + 12) % 12
        let heard = "\(Self.names[pc])\(nearest / 12 - 1) · \(Int(mic.pitchHz.rounded())) Hz"
        let best = Self.ocarina.min { a, b in
            let da = min(abs(pc - a.0), 12 - abs(pc - a.0)), db = min(abs(pc - b.0), 12 - abs(pc - b.0)); return da < db }!
        let semis = min(abs(pc - best.0), 12 - abs(pc - best.0))
        return (heard, semis == 0 ? "Ocarina note \(best.1)" : "Nearest ocarina note \(best.1) (\(semis) semitone\(semis == 1 ? "" : "s") off)")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let p = mic.problem {
                        Text(p).foregroundStyle(LauncherTheme.paleGold)
                    } else {
                        meter("Microphone", mic.rawDB, marks: false)
                        meter("What the game hears", mic.gameDB, marks: true)
                        HStack(spacing: 12) {
                            Circle().fill(mic.note ? Color.green : LauncherTheme.line).frame(width: 18, height: 18)
                            Text(mic.note ? "Heard as a note" : "No note").font(.headline).foregroundStyle(mic.note ? Color.green : LauncherTheme.soft)
                            Spacer()
                            Text("Room \(Int(mic.backgroundDB.rounded())) dB").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        }
                        let p = pitchText
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.0).font(.title3.monospacedDigit())
                            Text(p.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("The game starts a note when the lower bar crosses the gold line, and ends it when it falls under the grey one. Hum or whistle at the distance you play from; if no note shows, raise Mic Sensitivity. If notes show while you are silent, lower it.")
                }
                .listRowBackground(LauncherTheme.row)
                Section {
                    ForEach(rows) { SettingRow(s: $0, m: m) }
                } footer: {
                    if !micOn { Text("Ocarina Mic is off: the game itself will not listen until you turn it on.") }
                }
                .listRowBackground(LauncherTheme.row)
            }
            .launcherListStyle()
            .navigationTitle("Test Microphone")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { mic.start(sensitivity: sensitivity) }
        .onDisappear { mic.stop() }
        .onChange(of: sensitivity) { _, v in mic.setSensitivity(v) }
    }

    private func meter(_ title: String, _ db: Float, marks: Bool) -> some View {
        let frac = { (v: Float) in CGFloat((v - MicTestEngine.floorDB) / -MicTestEngine.floorDB) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text("\(Int(db.rounded())) dB").monospacedDigit().foregroundStyle(.secondary) }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(LauncherTheme.line)
                    Capsule().fill(db >= MicTestEngine.noteOnDB ? Color.green : LauncherTheme.gold).frame(width: max(4, g.size.width * frac(db)))
                    if marks {
                        Rectangle().fill(Color.gray).frame(width: 2).offset(x: g.size.width * frac(MicTestEngine.noteOffDB) - 1)
                        Rectangle().fill(LauncherTheme.paleGold).frame(width: 2).offset(x: g.size.width * frac(MicTestEngine.noteOnDB) - 1)
                    }
                }
            }
            .frame(height: 12)
            .accessibilityElement().accessibilityLabel(title).accessibilityValue("\(Int(db.rounded())) decibels")
        }
        .padding(.vertical, 4)
    }
}
