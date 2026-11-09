import SwiftUI

@MainActor @Observable
final class PerfModel {
    var rows: [BenchRow] = []
    var best: [String: Int] = [:]
    var running = false
    var thermalTick = 0
    struct VolumeRow: Identifiable, Sendable { let id: String; let name: String; let kind: StorageKind; let workers: Int }
    var volumes: [VolumeRow] = []

    /// Type de stockage de chaque volume : lu hors du fil principal (la commande diskutil bloque).
    func loadVolumes() async {
        volumes = await Task.detached(priority: .utility) {
            (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []).map { v in
                let name = (try? v.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? v.lastPathComponent
                return VolumeRow(id: v.path, name: name, kind: StorageProbe.kind(of: v.path), workers: Scheduler.scanWorkers(for: v.path))
            }
        }.value
    }

    init() { if let r = BenchStore.load() { rows = r.rows; best = r.bestSessions } }

    func runBench() {
        guard !running else { return }
        running = true; rows = []; best = [:]
        Task {
            let result = await VTBench.run { row in Task { @MainActor in self.rows.append(row) } }
            rows = result.rows; best = result.bestSessions; running = false
        }
    }
}

struct PerformanceView: View {
    @State private var model = PerfModel()
    private let hw = HardwareProfile.current

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    card(L("perf.machine")) { machine }
                    card(L("perf.slots")) { slots }
                }
                card(L("perf.storage")) { storage }
                card(L("perf.bench")) { bench }
            }
            .frame(maxWidth: 900).padding(28).frame(maxWidth: .infinity)
        }.background(Socle.bg)
        .task { await model.loadVolumes() }
    }

    private var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: L("thermal.nominal"); case .fair: L("thermal.fair"); case .serious: L("thermal.serious"); default: L("thermal.critical")
        }
    }

    private var machine: some View {
        VStack(spacing: 6) {
            row(L("perf.chip"), hw.chip)
            row("CPU", L("perf.cpu", hw.perfCores, hw.effCores))
            if hw.gpuCores > 0 { row("GPU", L("perf.gpu", hw.gpuCores)) }
            row(L("perf.memory"), "\(hw.memoryGB) " + L("unit.gb"))
            row(L("perf.engines"), "\(hw.videoEngines) + \(hw.proResEngines)")
            Text(L("perf.engines.note", hw.videoEngines, hw.proResEngines)).font(.system(size: 11)).foregroundColor(Socle.subtle)
                .frame(maxWidth: .infinity, alignment: .leading)
            row(L("perf.thermal"), thermalText, color: ProcessInfo.processInfo.thermalState == .nominal ? Color(hex: 0x4ADE80) : Socle.action)
            row(L("perf.lowpower"), ProcessInfo.processInfo.isLowPowerModeEnabled ? L("perf.on") : L("perf.off"))
        }
    }

    private var slots: some View {
        VStack(spacing: 6) {
            row(L("perf.thumbs"), "\(Scheduler.thumbSlots)")
            row(L("perf.export") + " · HEVC / H.264", "\(Scheduler.exportSlots(proRes: false))")
            row(L("perf.export") + " · ProRes", "\(Scheduler.exportSlots(proRes: true))")
            Text(L("perf.parallel")).font(.system(size: 11)).foregroundColor(Socle.subtle).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var storage: some View {
        VStack(spacing: 6) {
            ForEach(model.volumes) { v in
                row(v.name, "\(L("storage.\(v.kind.rawValue)")) · \(L("perf.scan")) \(v.workers)")
            }
        }
    }

    private var bench: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("perf.bench.note")).font(.system(size: 11)).foregroundColor(Socle.subtle)
            if model.rows.isEmpty && !model.running { Text(L("perf.bench.never")).foregroundColor(Socle.muted) }
            if !model.rows.isEmpty {
                VStack(spacing: 4) {
                    HStack { head(L("perf.col.codec"), nil); head(L("perf.col.sessions"), 80); head(L("perf.col.fps"), 90); head("", 90) }
                    ForEach(model.rows) { r in
                        HStack {
                            Text(r.codec).foregroundColor(Socle.textStrong).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(r.sessions)").frame(width: 80, alignment: .leading)
                            Text(String(format: "%.0f", r.fps)).monospacedDigit().foregroundColor(Socle.textStrong).frame(width: 90, alignment: .leading)
                            Text(r.hardware ? L("perf.hw") : L("perf.sw")).foregroundColor(r.hardware ? Color(hex: 0x4ADE80) : Socle.action).frame(width: 90, alignment: .leading)
                        }.font(.system(size: 12)).foregroundColor(Socle.text)
                    }
                }
                ForEach(model.best.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    Text("\(k) · " + L("perf.best", v)).font(.system(size: 12)).foregroundColor(Socle.accentText)
                }
            }
            HStack {
                button(model.running ? L("perf.bench.running") : L("action.bench"), main: !model.running) { model.runBench() }
                    .opacity(model.running ? 0.6 : 1)
            }
        }
    }

    private func head(_ t: String, _ w: CGFloat?) -> some View {
        Text(t.uppercased()).font(.system(size: 10.5)).tracking(0.6).foregroundColor(Socle.subtle)
            .frame(maxWidth: w == nil ? .infinity : w, alignment: .leading).frame(width: w)
    }

    private func row(_ k: String, _ v: String, color: Color = Socle.textStrong) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 12)).foregroundColor(Socle.subtle)
            Spacer(minLength: 8)
            Text(v).font(.system(size: 12)).foregroundColor(color).lineLimit(1)
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: @escaping () -> C) -> some View { SCard(title: title) { content() } }
}
