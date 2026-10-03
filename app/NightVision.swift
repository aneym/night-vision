import SwiftUI
import AppKit
import CoreGraphics

// MARK: - Paths & phase model

enum NV {
    static let nightvision = NSString(string: "~/.local/bin/nightvision").expandingTildeInPath
    static let config = NSString(string: "~/.config/night-vision/config.json").expandingTildeInPath
    /// Present while away; holds the brightness to restore. Written by the CLI.
    static let awayFlag = NSString(string: "~/.local/state/night-vision/away").expandingTildeInPath
}

struct PhaseSpec: Codable {
    let id: String
    let title: String
    let symbol: String
    let time: String
    let lum: Double
    let warmth: Double
}

struct LightSpec: Codable {
    let title: String
    let shortcut: String
}

/// Step sizes for the global F1/F2 display keys, tunable without a rebuild.
struct KeyStepSpec: Codable {
    let brightness: Int
    let warmth: Int
}

struct NightVisionConfig: Codable {
    let display: String
    let phases: [PhaseSpec]
    let lights: [LightSpec]?
    let keySteps: KeyStepSpec?
    let scheduleEnabled: Bool?
    /// Day the schedule was switched off; it switches back on the next day.
    let scheduleOffOn: String?
}

let FALLBACK_CONFIG = NightVisionConfig(
    display: "ddc",
    phases: [
        .init(id: "day", title: "Day", symbol: "sun.max.fill", time: "07:00", lum: 48, warmth: 0),
        .init(id: "evening", title: "Evening", symbol: "sun.horizon.fill", time: "20:00", lum: 32, warmth: 60),
        .init(id: "winddown", title: "Wind-down", symbol: "moon.fill", time: "20:30", lum: 18, warmth: 90),
        .init(id: "cutoff", title: "Cutoff", symbol: "moon.zzz.fill", time: "22:15", lum: 6, warmth: 100),
    ],
    lights: [
        .init(title: "Bedroom On", shortcut: "Bedroom on"),
        .init(title: "Living Room Low", shortcut: "Living room low"),
        .init(title: "Hallway Low", shortcut: "Hallway Low"),
        .init(title: "Bathroom Low", shortcut: "Bathroom low"),
    ],
    keySteps: .init(brightness: 5, warmth: 20),
    scheduleEnabled: true,
    scheduleOffOn: nil
)

func loadConfig() -> NightVisionConfig {
    guard let data = FileManager.default.contents(atPath: NV.config),
          let config = try? JSONDecoder().decode(NightVisionConfig.self, from: data),
          config.phases.count >= 2 else { return FALLBACK_CONFIG }
    return config
}

enum ScheduleStore {
    static func save(enabled: Bool? = nil, phase: PhaseSpec? = nil) throws {
        let url = URL(fileURLWithPath: NV.config)
        let source: Data
        if FileManager.default.fileExists(atPath: url.path) {
            source = try Data(contentsOf: url)
        } else {
            source = try JSONEncoder().encode(FALLBACK_CONFIG)
        }
        guard var root = try JSONSerialization.jsonObject(with: source) as? [String: Any],
              var phases = root["phases"] as? [[String: Any]] else {
            throw NSError(domain: "NightVision", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid schedule configuration"])
        }
        if let enabled {
            root["scheduleEnabled"] = enabled
            if enabled { root.removeValue(forKey: "scheduleOffOn") } else { root["scheduleOffOn"] = todayStamp() }
        }
        if let phase {
            guard let index = phases.firstIndex(where: { $0["id"] as? String == phase.id }) else {
                throw NSError(domain: "NightVision", code: 2, userInfo: [NSLocalizedDescriptionKey: "Period no longer exists"])
            }
            guard !phases.enumerated().contains(where: { offset, item in
                offset != index && item["time"] as? String == phase.time
            }) else {
                throw NSError(domain: "NightVision", code: 3, userInfo: [NSLocalizedDescriptionKey: "Another period already starts at this time"])
            }
            phases[index]["time"] = phase.time
            phases[index]["lum"] = Int(phase.lum.rounded())
            phases[index]["warmth"] = Int(phase.warmth.rounded())
            root["phases"] = phases
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

let CONFIG = loadConfig()

func todayStamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
}

func curveValues(at t: Double, phases: [PhaseSpec]) -> (lum: Double, warmth: Double) {
    let clamped = min(max(t, 0), Double(phases.count - 1))
    let i = min(Int(clamped), phases.count - 2)
    let f = clamped - Double(i)
    let a = phases[i], b = phases[i + 1]
    return (a.lum + (b.lum - a.lum) * f, a.warmth + (b.warmth - a.warmth) * f)
}

/// Project an arbitrary (lum, warmth) back onto the arc; residual > ~0.06 means "custom mix".
func curvePosition(lum: Double, warmth: Double, phases: [PhaseSpec]) -> (t: Double, residual: Double) {
    var best = (t: 0.0, d: Double.greatestFiniteMagnitude)
    let px = lum / 100.0, py = warmth / 100.0
    for i in 0..<(phases.count - 1) {
        let ax = phases[i].lum / 100, ay = phases[i].warmth / 100
        let bx = phases[i + 1].lum / 100, by = phases[i + 1].warmth / 100
        let abx = bx - ax, aby = by - ay
        let len2 = abx * abx + aby * aby
        var f = len2 > 0 ? ((px - ax) * abx + (py - ay) * aby) / len2 : 0
        f = min(max(f, 0), 1)
        let qx = ax + abx * f, qy = ay + aby * f
        let d = ((px - qx) * (px - qx) + (py - qy) * (py - qy)).squareRoot()
        if d < best.d { best = (Double(i) + f, d) }
    }
    return (best.t, best.d)
}

// MARK: - Device IO (coalesced writes on a serial queue)

final class DeviceIO {
    static let shared = DeviceIO()
    private let queue = DispatchQueue(label: "nightvision.device", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingLum: Int?
    private var pendingWarmth: Int?
    private var draining = false

    @discardableResult
    func run(_ path: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Coalesce slider spam: only the latest pending value per channel is written.
    func send(lum: Int? = nil, warmth: Int? = nil) {
        lock.lock()
        if let l = lum { pendingLum = l }
        if let w = warmth { pendingWarmth = w }
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            let l = pendingLum, w = pendingWarmth
            pendingLum = nil
            pendingWarmth = nil
            if l == nil && w == nil {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            if let l { run(NV.nightvision, ["lum", String(l)]) }
            if let w { run(NV.nightvision, ["temp", String(w)]) }
        }
    }

    private struct Status: Decodable {
        let paused: Bool
        let lum: Double
        let warmth: Double
    }

    func readDevice() -> (lum: Double?, warmth: Double, paused: Bool) {
        let output = run(NV.nightvision, ["status-json"])
        guard let data = output.data(using: .utf8),
              let status = try? JSONDecoder().decode(Status.self, from: data) else {
            return (nil, 0, false)
        }
        return (status.lum, status.warmth, status.paused)
    }

    func runShortcut(_ name: String) {
        queue.async { self.run("/usr/bin/shortcuts", ["run", name]) }
    }

    func runCLI(_ args: [String], then completion: (() -> Void)? = nil) {
        queue.async {
            self.run(NV.nightvision, args)
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    func refreshSchedule(completion: @escaping (String?) -> Void) {
        queue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: NV.nightvision)
            proc.arguments = ["schedule-sync"]
            let pipe = Pipe()
            proc.standardError = pipe
            proc.standardOutput = Pipe()
            do { try proc.run() } catch {
                DispatchQueue.main.async { completion(error.localizedDescription) }
                return
            }
            let error = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let message = proc.terminationStatus == 0 ? nil : (String(data: error, encoding: .utf8) ?? "Could not refresh schedule")
            DispatchQueue.main.async { completion(message) }
        }
    }

    func reapplyExpandedBrightness() {
        queue.async {
            let helper = NSString(string: "~/.local/share/night-vision/bin/nvbrightness").expandingTildeInPath
            _ = self.run(helper, ["reapply"])
        }
    }
}

// MARK: - Away blackout

/// Holds every online display's gamma at black while away. macOS drops a
/// process's gamma table when it exits, so only this long-running app can hold
/// it; the CLI owns the hardware half (brightness 0, then restore).
enum Blackout {
    private static let black: [CGGammaValue] = [0, 0]

    private static func displays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// True when every online display's transfer table peaks at zero.
    static var isHeld: Bool {
        displays().allSatisfy { id in
            var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
            var n: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &n) == .success, n > 0 else { return false }
            return max(r[Int(n) - 1], g[Int(n) - 1], b[Int(n) - 1]) == 0
        }
    }

    static func engage() {
        for id in displays() { CGSetDisplayTransferByTable(id, 2, black, black, black) }
    }

    static func release() {
        CGDisplayRestoreColorSyncSettings()
    }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var phases = CONFIG.phases
    @Published var scheduleEnabled = CONFIG.scheduleEnabled ?? true
    @Published var scheduleError: String?
    @Published var lum: Double = 41
    @Published var warmth: Double = 0
    @Published var scenePos: Double = 0
    @Published var isCustom = false
    @Published var paused = false
    @Published var away = false
    var isInteracting = false
    /// Set while an away/back CLI call is in flight, so the flag watcher does
    /// not undo a transition the app itself started.
    private var awayTransition = false

    init() {
        refresh()
        // The flag file is the source of truth, so `nightvision away|back` run
        // from anywhere (ssh, a phone) takes effect here within two seconds.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.syncAway() }
        }
        DispatchQueue.main.async { self.syncAway() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    var sceneMax: Double { Double(phases.count - 1) }
    var nearestIndex: Int { min(max(Int(scenePos.rounded()), 0), phases.count - 1) }

    var menuSymbol: String {
        if away { return "eye.slash" }
        return paused ? "pause.circle" : phases[nearestIndex].symbol
    }

    var phaseName: String {
        if isCustom { return "Custom mix" }
        let i = min(Int(scenePos), phases.count - 2)
        let f = scenePos - Double(i)
        if f < 0.15 { return phases[i].title }
        if f > 0.85 { return phases[i + 1].title }
        return "\(phases[i].title) → \(phases[i + 1].title)"
    }

    var statusLine: String {
        if away { return "Away · press a brightness key to return" }
        if paused { return "Paused · schedule resumes tomorrow" }
        let w = warmth <= 0 ? "no warmth" : "\(Int(warmth))% warm"
        return "\(phaseName) · \(Int(lum))% bright · \(w)"
    }

    func refresh() {
        if isInteracting { return }
        // An "off" schedule only lasts the day it was switched off.
        if !scheduleEnabled, loadConfig().scheduleOffOn != todayStamp() {
            _ = saveSchedule(enabled: true)
        }
        DispatchQueue.global(qos: .utility).async {
            let s = DeviceIO.shared.readDevice()
            DispatchQueue.main.async { self.apply(s) }
        }
    }

    private func apply(_ s: (lum: Double?, warmth: Double, paused: Bool)) {
        if isInteracting { return }
        if let l = s.lum { lum = l }
        warmth = s.warmth
        paused = s.paused
        recomputeScene()
    }

    private func recomputeScene() {
        let (t, r) = curvePosition(lum: lum, warmth: warmth, phases: phases)
        scenePos = t
        isCustom = r > 0.06
    }

    // Scene slider: interpolate along the arc, push both channels.
    func dragScene(_ t: Double) {
        isInteracting = true
        let v = curveValues(at: t, phases: phases)
        scenePos = min(max(t, 0), sceneMax)
        lum = v.lum
        warmth = v.warmth
        isCustom = false
        DeviceIO.shared.send(lum: Int(v.lum.rounded()), warmth: Int(v.warmth.rounded()))
    }

    func commitScene(_ t: Double) {
        let snapped = t.rounded()
        if abs(t - snapped) < 0.1 && (0...sceneMax).contains(snapped) {
            applyPhase(Int(snapped))
        } else {
            dragScene(t)
        }
        isInteracting = false
    }

    func applyPhase(_ index: Int) {
        let p = phases[index]
        scenePos = Double(index)
        lum = p.lum
        warmth = p.warmth
        isCustom = false
        DeviceIO.shared.runCLI([p.id])
    }

    func setLum(_ v: Double) {
        lum = min(max(v, 0), 100)
        DeviceIO.shared.send(lum: Int(lum.rounded()))
        recomputeScene()
    }

    func stepLum(_ delta: Int) {
        setLum(lum + Double(delta))
    }

    func setWarmth(_ v: Double) {
        warmth = min(max(v, 0), 100)
        DeviceIO.shared.send(warmth: Int(warmth.rounded()))
        recomputeScene()
    }

    func stepWarmth(_ delta: Int) {
        setWarmth(warmth + Double(delta))
    }

    // MARK: Away

    /// Hardware to 0 and gamma to black, without sleeping anything. Gamma is
    /// only blacked out while the key tap is live, because the brightness keys
    /// are the way back.
    /// `restoreTo` is the brightness to come back to when the caller already
    /// changed it on the way in (the first key of a two-key chord steps once).
    func goAway(restoreTo: Double? = nil) {
        guard !away else { return }
        away = true
        awayTransition = true
        if DisplayKeyMonitor.isLive { Blackout.engage() }
        DisplayKeyMonitor.log("away")
        let args = ["away"] + (restoreTo.map { [String(Int($0.rounded()))] } ?? [])
        DeviceIO.shared.runCLI(args) { self.awayTransition = false }
    }

    func comeBack() {
        guard away else { return }
        away = false
        awayTransition = true
        Blackout.release()
        DisplayKeyMonitor.log("back")
        DeviceIO.shared.runCLI(["back"]) {
            self.awayTransition = false
            self.refresh()
        }
    }

    private func syncAway() {
        guard !awayTransition else { return }
        let flagged = FileManager.default.fileExists(atPath: NV.awayFlag)
        if flagged {
            away = true
            // Display reconfiguration and color-profile changes reset gamma.
            if DisplayKeyMonitor.isLive && !Blackout.isHeld { Blackout.engage() }
        } else if away {
            away = false
            Blackout.release()
            refresh()
        }
    }

    func setPaused(_ on: Bool) {
        paused = on
        DeviceIO.shared.runCLI([on ? "pause" : "resume"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    func saveSchedule(enabled: Bool? = nil, phase: PhaseSpec? = nil) -> Bool {
        do {
            try ScheduleStore.save(enabled: enabled, phase: phase)
            let refreshed = loadConfig()
            phases = refreshed.phases
            scheduleEnabled = refreshed.scheduleEnabled ?? true
            recomputeScene()
            scheduleError = nil
            DeviceIO.shared.refreshSchedule { error in
                if let error { self.scheduleError = error }
            }
            return true
        } catch {
            scheduleError = error.localizedDescription
            return false
        }
    }

    var nextTransition: String {
        let cal = Calendar.current
        let now = Date()
        var best: (Date, String)?
        guard scheduleEnabled else { return "Schedule off" }
        for phase in phases {
            let parts = phase.time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2,
                  let d = cal.nextDate(after: now,
                                       matching: DateComponents(hour: parts[0], minute: parts[1]),
                                       matchingPolicy: .nextTime) else { continue }
            if best == nil || d < best!.0 { best = (d, phase.title) }
        }
        guard let best else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "Next: \(best.1) at \(fmt.string(from: best.0))"
    }
}

// MARK: - Scene slider (the arc)

struct SceneSlider: View {
    @ObservedObject var model: Model

    private let thumbSize: CGFloat = 21
    private var pad: CGFloat { thumbSize / 2 }

    private let trackGradient = LinearGradient(
        colors: [
            Color(red: 0.97, green: 0.94, blue: 0.84),
            Color(red: 0.96, green: 0.76, blue: 0.42),
            Color(red: 0.76, green: 0.44, blue: 0.13),
            Color(red: 0.28, green: 0.14, blue: 0.05),
        ],
        startPoint: .leading, endPoint: .trailing
    )

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - pad * 2
            let cx = pad + usable * CGFloat(model.scenePos / model.sceneMax)
            let cy = geo.size.height / 2
            ZStack {
                Capsule()
                    .fill(trackGradient)
                    .frame(height: 10)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                ForEach(0..<model.phases.count, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 3.5, height: 3.5)
                        .position(x: pad + usable * CGFloat(i) / CGFloat(model.sceneMax), y: cy)
                }
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15)))
                    .overlay(
                        Circle()
                            .strokeBorder(NV_ACCENT.opacity(model.isCustom ? 0.9 : 0), lineWidth: 2)
                            .padding(3)
                    )
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .position(x: cx, y: cy)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in model.dragScene(t(for: g.location.x, usable: usable)) }
                    .onEnded { g in model.commitScene(t(for: g.location.x, usable: usable)) }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Scene")
        .accessibilityValue(model.phaseName)
        .accessibilityAdjustableAction { direction in
            let step = 0.25
            switch direction {
            case .increment: model.commitScene(model.scenePos + step)
            case .decrement: model.commitScene(model.scenePos - step)
            @unknown default: break
            }
        }
    }

    private func t(for x: CGFloat, usable: CGFloat) -> Double {
        guard usable > 0 else { return 0 }
        return Double((x - pad) / usable) * model.sceneMax
    }
}

// MARK: - Content view

// Single restrained accent shared by every control, matching the arc's amber.
let NV_ACCENT = Color(red: 0.87, green: 0.58, blue: 0.28)

struct ContentView: View {
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            SceneSlider(model: model)
            phaseRow
            Divider()
            channelSliders
            Divider()
            pauseRow
            scheduleSection
            lights
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(.quaternary).frame(width: 28, height: 28)
                Image(systemName: model.menuSymbol)
                    .font(.system(size: 13, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Night Vision").font(.headline)
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Away: screen off (both brightness keys)") { model.goAway() }
                Button("Refresh") { model.refresh() }
                Divider()
                Button("Quit Night Vision") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
    }

    private var phaseRow: some View {
        HStack(spacing: 6) {
            ForEach(0..<model.phases.count, id: \.self) { i in
                let p = model.phases[i]
                let active = !model.isCustom && model.nearestIndex == i
                Button {
                    if reduceMotion {
                        model.applyPhase(i)
                    } else {
                        withAnimation(.snappy(duration: 0.25)) { model.applyPhase(i) }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: p.symbol).font(.system(size: 13, weight: .medium))
                        Text(p.title).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(active ? 0.14 : 0.045))
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .accessibilityLabel("\(p.title) preset")
            }
        }
    }

    private var channelSliders: some View {
        VStack(spacing: 10) {
            channelRow(
                label: "Brightness", symbol: "sun.max",
                value: model.lum, display: "\(Int(model.lum))%"
            ) { model.setLum($0) }
            channelRow(
                label: "Warmth", symbol: "thermometer.medium",
                value: model.warmth, display: model.warmth <= 0 ? "Off" : "\(Int(model.warmth))%"
            ) { model.setWarmth($0) }
        }
    }

    private func channelRow(
        label: String, symbol: String, value: Double, display: String,
        set: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 3) {
            HStack {
                Label(label, systemImage: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(display)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { value }, set: set),
                in: 0...100,
                onEditingChanged: { editing in
                    model.isInteracting = editing
                }
            )
            .controlSize(.small)
            .tint(NV_ACCENT)
            .accessibilityLabel(label)
        }
    }

    private var pauseRow: some View {
        Toggle(isOn: Binding(get: { model.paused }, set: { model.setPaused($0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Pause tonight").font(.callout)
                Text(model.paused ? "Schedule resumes tomorrow morning" : "Skip tonight's automatic phases")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(NV_ACCENT)
    }

    private var scheduleSection: some View {
        ScheduleEditor(model: model)
    }

    private var lights: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lights")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(CONFIG.lights ?? [], id: \.shortcut) { light in
                    lightButton(light.title, shortcut: light.shortcut)
                }
            }
        }
    }

    private func lightButton(_ title: String, shortcut: String) -> some View {
        Button {
            DeviceIO.shared.runShortcut(shortcut)
        } label: {
            Label(title, systemImage: "lightbulb")
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            ForEach(0..<model.phases.count, id: \.self) { i in
                let p = model.phases[i]
                Label(p.time, systemImage: p.symbol)
                    .font(.caption2)
                    .foregroundStyle(!model.isCustom && model.nearestIndex == i ? Color.primary : Color.secondary)
                if i < model.phases.count - 1 { Spacer() }
            }
        }
        .overlay(alignment: .bottomLeading) {
            EmptyView()
        }
        .padding(.top, 2)
        .help(model.nextTransition)
    }
}

struct ScheduleEditor: View {
    @ObservedObject var model: Model
    @State private var expanded = false
    @State private var selectedID = "day"
    @State private var hour = 7
    @State private var minute = 0
    @State private var brightness = 48.0
    @State private var warmth = 0.0

    private var selected: PhaseSpec? {
        model.phases.first(where: { $0.id == selectedID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Schedule", isOn: Binding(
                    get: { model.scheduleEnabled },
                    set: { _ = model.saveSchedule(enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(NV_ACCENT)
                Spacer()
                Button(expanded ? "Done" : "Edit periods") { expanded.toggle() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(NV_ACCENT)
            }
            if expanded, let phase = selected {
                Divider()
                Picker("Period", selection: $selectedID) {
                    ForEach(model.phases, id: \.id) { p in
                        Label(p.title, systemImage: p.symbol).tag(p.id)
                    }
                }
                .onChange(of: selectedID) { _, _ in loadSelected() }
                HStack {
                    Text("Starts at").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Hour", selection: $hour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }.labelsHidden().frame(width: 64)
                    Text(":").foregroundStyle(.secondary)
                    Picker("Minute", selection: $minute) {
                        ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }.labelsHidden().frame(width: 64)
                }
                settingRow("Brightness", value: $brightness)
                settingRow("Warmth", value: $warmth)
                HStack {
                    Button("Use current settings") {
                        brightness = model.lum.rounded()
                        warmth = model.warmth.rounded()
                    }
                    .font(.caption)
                    Spacer()
                    Button("Save \(phase.title)") {
                        let updated = PhaseSpec(
                            id: phase.id, title: phase.title, symbol: phase.symbol,
                            time: String(format: "%02d:%02d", hour, minute),
                            lum: brightness.rounded(), warmth: warmth.rounded())
                        _ = model.saveSchedule(phase: updated)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NV_ACCENT)
                    .controlSize(.small)
                }
                Text("Saving a period does not change your display now.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = model.scheduleError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .onAppear {
            if !model.phases.contains(where: { $0.id == selectedID }) {
                selectedID = model.phases[0].id
            }
            loadSelected()
        }
    }

    private func settingRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))%")
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: value, in: 0...100, step: 1)
                .controlSize(.small)
                .tint(NV_ACCENT)
                .accessibilityLabel("Scheduled \(title)")
        }
    }

    private func loadSelected() {
        guard let phase = selected else { return }
        let parts = phase.time.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 { hour = parts[0]; minute = parts[1] }
        brightness = phase.lum
        warmth = phase.warmth
    }
}

// MARK: - Global display key handling

final class DisplayKeyMonitor {
    // Brightness is instant, so small steps feel precise. Night Shift ramps its
    // color change over about a second, so warmth needs coarser steps to feel
    // responsive. Both are overridable via "keySteps" in config.json.
    private let brightnessStep = max(1, CONFIG.keySteps?.brightness ?? 5)
    private let warmthStep = max(1, CONFIG.keySteps?.warmth ?? 20)
    private let model: Model

    /// macOS virtual key codes for the top-row keys we own.
    private static let vkF1: Int64 = 122
    private static let vkF2: Int64 = 120
    /// F14/F15: what keyboards like the NuPhy Gem80 send for brightness
    /// down/up without Fn (HID Scroll Lock/Pause).
    private static let vkF14: Int64 = 107
    private static let vkF15: Int64 = 113
    private static let downKeys: Set<Int64> = [vkF1, vkF14]
    private static let upKeys: Set<Int64> = [vkF2, vkF15]
    /// NX_KEYTYPE codes carried in an NSSystemDefined aux-button event.
    private static let auxBrightnessUp: Int64 = 2
    private static let auxBrightnessDown: Int64 = 3
    private static let auxSubtype: Int64 = 8
    /// NX_SYSDEFINED — not exposed as a CGEventType case.
    private static let systemDefined = CGEventType(rawValue: 14)!

    private static let logPath = NSString(string: "~/.local/state/night-vision/keys.log").expandingTildeInPath
    private static let debugFlag = NSString(string: "~/.local/state/night-vision/keydebug").expandingTildeInPath

    /// True once the event tap is installed, i.e. the brightness keys can end away.
    static var isLive = false

    /// Two-key chord state, keyed by direction (true = brightness up).
    private var held: [Bool: Date] = [:]
    private var lastDown: [Bool: Date] = [:]
    private var levelBeforePress: Double?
    /// Presses right after going away or coming back belong to that gesture.
    private var quietUntil = Date.distantPast
    /// Both keys count as pressed together when the second lands this soon.
    private static let chordWindow: TimeInterval = 0.15
    /// A key still counts as held this long after its last down or repeat, so
    /// a lost key-up cannot leave a stale hold that turns a later press into a chord.
    private static let holdLimit: TimeInterval = 2.5

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?

    init(model: Model) {
        self.model = model
        install()
    }

    deinit {
        retryTimer?.invalidate()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }

    // MARK: Logging

    /// Appends a line to the key log. Only ever called for the function-row and
    /// display-control events this class owns, so it is not a keystroke record.
    static func log(_ message: String) {
        guard FileManager.default.fileExists(atPath: debugFlag) else { return }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamped = "\(fmt.string(from: Date())) \(message)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: logPath)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    // MARK: Install

    private func install() {
        // Third-party keyboards send a plain F1/F2 keyDown; Apple keyboards send
        // an NSSystemDefined brightness event. Tap both so either hardware works.
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << Self.systemDefined.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<DisplayKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                return monitor.dispatch(proxy: proxy, type: type, event: event)
            },
            userInfo: context
        )

        guard let eventTap else {
            Self.log("tapCreate failed — Accessibility not granted for this build; retrying")
            scheduleRetry()
            return
        }

        retryTimer?.invalidate()
        retryTimer = nil
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        Self.isLive = true
        Self.log("event tap installed")
    }

    /// Accessibility can be granted after launch; keep trying so the user does
    /// not have to know the app must be restarted.
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.eventTap == nil else { return }
            guard AXIsProcessTrusted() else { return }
            self.install()
        }
    }

    // MARK: Dispatch

    private func dispatch(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that stalls or that the user interrupts.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            Self.log("tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            return Unmanaged.passUnretained(event)
        }
        return handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }

    /// Returns true when the event was consumed as a display control.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .keyDown: return handleFunctionKey(event)
        case .keyUp:
            // Observe only, to track holds for the two-key chord.
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if Self.downKeys.contains(code) || Self.upKeys.contains(code) { held[Self.upKeys.contains(code)] = nil }
            return false
        case Self.systemDefined: return handleAuxKey(event)
        default: return false
        }
    }

    private func handleFunctionKey(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard Self.downKeys.contains(code) || Self.upKeys.contains(code) else { return false }

        // Leave Cmd/Ctrl chords to apps; bare, Shift and Option belong to us.
        // Fn is not a discriminator here: with "use F1/F2 as function keys" off,
        // macOS stamps maskSecondaryFn on every top-row press, chord or not.
        let flags = event.flags
        Self.log("keyDown code=\(code) flags=\(String(flags.rawValue, radix: 16))")
        let others: CGEventFlags = [.maskCommand, .maskControl]
        guard flags.intersection(others).isEmpty else { return false }

        let up = Self.upKeys.contains(code)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        press(up: up, isRepeat: isRepeat, shift: flags.contains(.maskShift), option: flags.contains(.maskAlternate))
        return true
    }

    private func handleAuxKey(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }
        let data = Int64(nsEvent.data1)
        guard Int64(nsEvent.subtype.rawValue) == Self.auxSubtype else { return false }

        let keyCode = (data >> 16) & 0xffff
        Self.log("aux code=\(keyCode) flags=\(String(event.flags.rawValue, radix: 16))")
        guard keyCode == Self.auxBrightnessUp || keyCode == Self.auxBrightnessDown else { return false }

        // Swallow the key-up half too, so macOS never sees a half-press.
        let isKeyDown = ((data >> 8) & 0xff) == 0x0a
        let shift = event.flags.contains(.maskShift)
        let up = keyCode == Self.auxBrightnessUp
        Self.log("aux \(up ? "up" : "down") \(isKeyDown ? "keyDown" : "keyUp") shift=\(shift) flags=\(String(event.flags.rawValue, radix: 16))")
        guard isKeyDown else {
            held[up] = nil
            return true
        }
        let isRepeat = (data & 0x1) != 0
        press(up: up, isRepeat: isRepeat, shift: shift, option: event.flags.contains(.maskAlternate))
        return true
    }

    /// Both brightness keys together (or Option with brightness down) go away.
    /// While away, any brightness key only brings the screen back.
    /// The tap runs on the main run loop, so the model is safe to touch here.
    private func press(up: Bool, isRepeat: Bool, shift: Bool, option: Bool) {
        MainActor.assumeIsolated {
            let now = Date()
            let other = !up
            let otherHeld = held[other].map { now.timeIntervalSince($0) < Self.holdLimit } ?? false
            let otherJustPressed = lastDown[other].map { now.timeIntervalSince($0) < Self.chordWindow } ?? false
            held[up] = now
            if !isRepeat { lastDown[up] = now }

            guard now >= quietUntil else { return }
            if model.away {
                guard !isRepeat else { return }
                model.comeBack()
                quietUntil = now.addingTimeInterval(0.6)
                return
            }
            if !isRepeat && (otherHeld || otherJustPressed) {
                Self.log("chord: away")
                model.goAway(restoreTo: levelBeforePress)
                quietUntil = now.addingTimeInterval(0.6)
                return
            }
            if option && !up {
                model.goAway()
                quietUntil = now.addingTimeInterval(0.6)
                return
            }
            let sign = up ? 1 : -1
            if shift {
                model.stepWarmth(sign * warmthStep)
            } else {
                levelBeforePress = model.lum
                model.stepLum(sign * brightnessStep)
            }
        }
    }
}

// MARK: - App

struct MenuBarLabel: View {
    @ObservedObject var model: Model
    var body: some View {
        Image(systemName: model.menuSymbol)
    }
}

@main
struct NightVisionApp: App {
    @StateObject private var model: Model
    private let keyMonitor: DisplayKeyMonitor

    init() {
        let model = Model()
        _model = StateObject(wrappedValue: model)
        keyMonitor = DisplayKeyMonitor(model: model)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
