import SwiftUI
import AppKit

// MARK: - Paths & phase model

enum NV {
    static let nightvision = NSString(string: "~/.local/bin/nightvision").expandingTildeInPath
    static let config = NSString(string: "~/.config/night-vision/config.json").expandingTildeInPath
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

struct NightVisionConfig: Codable {
    let display: String
    let phases: [PhaseSpec]
    let lights: [LightSpec]
}

let FALLBACK_CONFIG = NightVisionConfig(
    display: "ddc",
    phases: [
        .init(id: "day", title: "Day", symbol: "sun.max.fill", time: "07:00", lum: 41, warmth: 0),
        .init(id: "evening", title: "Evening", symbol: "sun.horizon.fill", time: "20:00", lum: 32, warmth: 60),
        .init(id: "winddown", title: "Wind-down", symbol: "moon.fill", time: "21:30", lum: 20, warmth: 85),
        .init(id: "cutoff", title: "Cutoff", symbol: "moon.zzz.fill", time: "22:15", lum: 8, warmth: 100),
    ],
    lights: [
        .init(title: "Bedroom On", shortcut: "Bedroom on"),
        .init(title: "Living Room Low", shortcut: "Living room low"),
        .init(title: "Hallway Low", shortcut: "Hallway Low"),
        .init(title: "Bathroom Low", shortcut: "Bathroom low"),
    ]
)

func loadConfig() -> NightVisionConfig {
    guard let data = FileManager.default.contents(atPath: NV.config),
          let config = try? JSONDecoder().decode(NightVisionConfig.self, from: data),
          config.phases.count >= 2 else { return FALLBACK_CONFIG }
    return config
}

let CONFIG = loadConfig()
let PHASES = CONFIG.phases
let SCENE_MAX = Double(PHASES.count - 1)

func curveValues(at t: Double) -> (lum: Double, warmth: Double) {
    let clamped = min(max(t, 0), SCENE_MAX)
    let i = min(Int(clamped), PHASES.count - 2)
    let f = clamped - Double(i)
    let a = PHASES[i], b = PHASES[i + 1]
    return (a.lum + (b.lum - a.lum) * f, a.warmth + (b.warmth - a.warmth) * f)
}

/// Project an arbitrary (lum, warmth) back onto the arc; residual > ~0.06 means "custom mix".
func curvePosition(lum: Double, warmth: Double) -> (t: Double, residual: Double) {
    var best = (t: 0.0, d: Double.greatestFiniteMagnitude)
    let px = lum / 100.0, py = warmth / 100.0
    for i in 0..<(PHASES.count - 1) {
        let ax = PHASES[i].lum / 100, ay = PHASES[i].warmth / 100
        let bx = PHASES[i + 1].lum / 100, by = PHASES[i + 1].warmth / 100
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

    func runCLI(_ args: [String]) {
        queue.async { self.run(NV.nightvision, args) }
    }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var lum: Double = 41
    @Published var warmth: Double = 0
    @Published var scenePos: Double = 0
    @Published var isCustom = false
    @Published var paused = false
    var isInteracting = false

    init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    var nearestIndex: Int { min(max(Int(scenePos.rounded()), 0), PHASES.count - 1) }

    var menuSymbol: String {
        paused ? "pause.circle" : PHASES[nearestIndex].symbol
    }

    var phaseName: String {
        if isCustom { return "Custom mix" }
        let i = min(Int(scenePos), PHASES.count - 2)
        let f = scenePos - Double(i)
        if f < 0.15 { return PHASES[i].title }
        if f > 0.85 { return PHASES[i + 1].title }
        return "\(PHASES[i].title) → \(PHASES[i + 1].title)"
    }

    var statusLine: String {
        if paused { return "Paused · schedule resumes tomorrow" }
        let w = warmth <= 0 ? "no warmth" : "\(Int(warmth))% warm"
        return "\(phaseName) · \(Int(lum))% bright · \(w)"
    }

    func refresh() {
        if isInteracting { return }
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
        let (t, r) = curvePosition(lum: lum, warmth: warmth)
        scenePos = t
        isCustom = r > 0.06
    }

    // Scene slider: interpolate along the arc, push both channels.
    func dragScene(_ t: Double) {
        isInteracting = true
        let v = curveValues(at: t)
        scenePos = min(max(t, 0), SCENE_MAX)
        lum = v.lum
        warmth = v.warmth
        isCustom = false
        DeviceIO.shared.send(lum: Int(v.lum.rounded()), warmth: Int(v.warmth.rounded()))
    }

    func commitScene(_ t: Double) {
        let snapped = t.rounded()
        if abs(t - snapped) < 0.1 && (0...SCENE_MAX).contains(snapped) {
            applyPhase(Int(snapped))
        } else {
            dragScene(t)
        }
        isInteracting = false
    }

    func applyPhase(_ index: Int) {
        let p = PHASES[index]
        scenePos = Double(index)
        lum = p.lum
        warmth = p.warmth
        isCustom = false
        DeviceIO.shared.runCLI([p.id])
    }

    func setLum(_ v: Double) {
        lum = v
        DeviceIO.shared.send(lum: Int(v.rounded()))
        recomputeScene()
    }

    func setWarmth(_ v: Double) {
        warmth = v
        DeviceIO.shared.send(warmth: Int(v.rounded()))
        recomputeScene()
    }

    func setPaused(_ on: Bool) {
        paused = on
        DeviceIO.shared.runCLI([on ? "pause" : "resume"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    var nextTransition: String {
        let cal = Calendar.current
        let now = Date()
        var best: (Date, String)?
        for phase in PHASES {
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
            let cx = pad + usable * CGFloat(model.scenePos / SCENE_MAX)
            let cy = geo.size.height / 2
            ZStack {
                Capsule()
                    .fill(trackGradient)
                    .frame(height: 10)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                ForEach(0..<PHASES.count, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 3.5, height: 3.5)
                        .position(x: pad + usable * CGFloat(i) / CGFloat(SCENE_MAX), y: cy)
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
        return Double((x - pad) / usable) * SCENE_MAX
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
            lights
            footer
        }
        .padding(14)
        .frame(width: 300)
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
            ForEach(0..<PHASES.count, id: \.self) { i in
                let p = PHASES[i]
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

    private var lights: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lights")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(CONFIG.lights, id: \.shortcut) { light in
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
            ForEach(0..<PHASES.count, id: \.self) { i in
                let p = PHASES[i]
                Label(p.time, systemImage: p.symbol)
                    .font(.caption2)
                    .foregroundStyle(!model.isCustom && model.nearestIndex == i ? Color.primary : Color.secondary)
                if i < PHASES.count - 1 { Spacer() }
            }
        }
        .overlay(alignment: .bottomLeading) {
            EmptyView()
        }
        .padding(.top, 2)
        .help(model.nextTransition)
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
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
