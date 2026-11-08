import SwiftUI
import AppKit

func formatDuration(_ s: Double) -> String {
    let t = Int(s.rounded()); let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

func formatInfo(_ i: MediaInfo) -> String {
    var parts: [String] = []
    if i.width > 0 { parts.append("\(i.width)×\(i.height)") }
    if i.fps > 0 { parts.append(String(format: i.fps.rounded() == i.fps ? "%.0f i/s" : "%.2f i/s", i.fps)) }
    return parts.joined(separator: " · ")
}

struct ClipGrid: View {
    let model: AppModel
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)], spacing: 12) {
                ForEach(model.clips) { c in ClipCard(clip: c, service: model.thumbs) }
            }.padding(16)
        }
    }
}

struct ClipCard: View {
    let clip: Clip
    let service: ThumbService
    @State private var loaded: Loaded?
    private var line1: String { loaded?.info.map { formatInfo($0) } ?? "" }
    private var line2: String { loaded?.info?.codec ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(Color(hex: 0x2A2A2A)).aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let d = loaded?.jpeg, let img = NSImage(data: d) {
                            Image(nsImage: img).resizable().scaledToFill()
                        } else if loaded != nil {
                            Text(clip.ext.uppercased()).font(.system(size: 13, weight: .semibold)).foregroundColor(Socle.subtle)
                        }
                    }.clipped()
                if let i = loaded?.info, i.duration > 0 {
                    Text(formatDuration(i.duration)).font(.system(size: 10).monospacedDigit()).foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).font(.system(size: 12)).foregroundColor(Socle.textStrong).lineLimit(1)
                Text(line1.nonEmpty ?? " ").font(.system(size: 11)).foregroundColor(Socle.subtle).lineLimit(1)
                Text(line2.nonEmpty ?? " ").font(.system(size: 11)).foregroundColor(Socle.subtle).lineLimit(1)
            }.padding(.horizontal, 8).padding(.vertical, 6)
        }
        .background(Socle.surface, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: clip.path) { loaded = await service.load(clip) }
    }
}

extension String { var nonEmpty: String? { isEmpty ? nil : self } }
