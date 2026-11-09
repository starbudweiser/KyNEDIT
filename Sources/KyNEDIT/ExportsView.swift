import SwiftUI
import AppKit

struct ExportsView: View {
    let queue: ExportQueue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("tab.exports")).font(.system(size: 13, weight: .semibold)).foregroundColor(Socle.textStrong)
                Spacer()
                if queue.jobs.contains(where: { $0.state == .done || $0.state == .failed || $0.state == .cancelled }) {
                    button(L("action.clear")) { queue.clearFinished() }
                }
            }.padding(.horizontal, 28).padding(.vertical, 12)
            Divider().overlay(Socle.border)
            if queue.jobs.isEmpty {
                Text(L("exports.empty")).foregroundColor(Socle.subtle).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(queue.jobs) { j in JobRow(job: j, queue: queue) }
                    }.padding(28).frame(maxWidth: 900).frame(maxWidth: .infinity)
                }
            }
        }.background(Socle.bg)
    }
}

struct JobRow: View {
    let job: ExportJob
    let queue: ExportQueue

    private var stateColor: Color {
        switch job.state { case .done: Color(hex: 0x4ADE80); case .failed: Color(hex: 0xF87171); case .running: Socle.accentText; default: Socle.muted }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Socle.textStrong).lineLimit(1)
                Text(job.error ?? (job.outputPath.map { ($0 as NSString).lastPathComponent } ?? job.label))
                    .font(.system(size: 11)).foregroundColor(job.state == .failed ? Color(hex: 0xF87171) : Socle.subtle).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(job.label).font(.system(size: 11)).foregroundColor(Socle.muted).frame(width: 110, alignment: .leading)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Socle.control).frame(height: 5)
                GeometryReader { g in RoundedRectangle(cornerRadius: 3).fill(job.state == .done ? Color(hex: 0x4ADE80) : Color(hex: 0x0EA5E9)).frame(width: g.size.width * job.progress, height: 5) }.frame(height: 5)
            }.frame(width: 140)
            VStack(alignment: .trailing, spacing: 2) {
                Text(L("export.state.\(job.state.rawValue)")).font(.system(size: 11)).foregroundColor(stateColor)
                if job.state == .done, let s = job.seconds, let e = job.elapsed, e > 0 { Text(L("export.speed", s / e)).font(.system(size: 10)).foregroundColor(Socle.subtle) }
                else if job.state == .running { Text("\(Int(job.progress * 100)) %").font(.system(size: 10).monospacedDigit()).foregroundColor(Socle.subtle) }
            }.frame(width: 110, alignment: .trailing)
            HStack(spacing: 10) {
                if job.state == .failed || job.state == .cancelled { Text("↻").foregroundColor(Socle.accentText).onTapGesture { queue.retry(job.id) }.help(L("export.retry")) }
                if job.state == .done, let p = job.outputPath { Text("⌕").foregroundColor(Socle.accentText).onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }
                Text("✕").foregroundColor(Socle.subtle).onTapGesture { queue.remove(job.id) }
            }.font(.system(size: 13)).frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(Socle.surface, in: RoundedRectangle(cornerRadius: 6))
    }
}
