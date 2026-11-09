import SwiftUI
import AppKit

/// Cadence avec l'unité de la langue (« i/s », « fps », « f/s »).
func fpsText(_ f: Double) -> String {
    var t = String(format: "%.3f", f)
    while t.hasSuffix("0") { t.removeLast() }
    if t.hasSuffix(".") { t.removeLast() }
    return t + " " + L("unit.fps")
}

func formatDuration(_ s: Double) -> String {
    let t = Int(s.rounded()); let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

func formatInfo(_ i: MediaInfo) -> String {
    var parts: [String] = []
    if i.width > 0 { parts.append("\(i.width)×\(i.height)") }
    if i.fps > 0 { parts.append(fpsText(i.fps)) }
    return parts.joined(separator: " · ")
}

struct ClipGrid: View {
    let model: AppModel
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)], spacing: 12) {
                ForEach(model.clips) { c in ClipCard(clip: c, service: model.thumbs, selected: model.selection.contains(c.path), meta: model.meta[c.path]).onTapGesture { model.click(c) } }
            }.padding(16)
        }
    }
}

struct ClipCard: View {
    let clip: Clip
    let service: ThumbService
    var selected = false
    var meta: ClipMeta?
    @State private var loaded: Loaded?
    @State private var scrub = HoverScrub()
    @State private var hoverWidth: CGFloat = 200
    private var line1: String { loaded?.info.map { formatInfo($0) } ?? "" }
    private var line2: String { loaded?.info?.codec ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(Color(hex: 0x2A2A2A)).aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let cg = scrub.image {
                            Image(decorative: cg, scale: 1).resizable().scaledToFill()
                        } else if let d = loaded?.jpeg, let img = NSImage(data: d) {
                            Image(nsImage: img).resizable().scaledToFill()
                        } else if loaded != nil {
                            Text(clip.ext.uppercased()).font(.system(size: 13, weight: .semibold)).foregroundColor(Socle.subtle)
                        }
                    }.clipped()
                    .overlay(alignment: .bottomLeading) {
                        if scrub.image != nil { GeometryReader { g in Rectangle().fill(Socle.action).frame(width: g.size.width * scrub.fraction, height: 3).frame(maxHeight: .infinity, alignment: .bottom) } }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): if let d = loaded?.info?.duration { scrub.move(clip: clip, duration: d, fraction: p.x / hoverWidth) }
                        case .ended: scrub.end()
                        }
                    }
                    .background(GeometryReader { g in Color.clear.onAppear { hoverWidth = g.size.width }.onChange(of: g.size.width) { _, w in hoverWidth = w } })
                if clip.isRaw {
                    Text(L("raw.badge")).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color(hex: 0x0369A1), in: RoundedRectangle(cornerRadius: 3))
                        .padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if let m = meta, m.rating > 0 || m.color > 0 {
                    HStack(spacing: 4) {
                        if m.color > 0 { Circle().fill(labelColors[m.color]).frame(width: 8, height: 8) }
                        if m.rating > 0 { Text(String(repeating: "★", count: m.rating)).font(.system(size: 10)).foregroundColor(Socle.action) }
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                    .padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
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
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color(hex: 0x0EA5E9) : .clear, lineWidth: 2))
        .task(id: clip.path) { loaded = await service.load(clip) }
    }
}

extension String { var nonEmpty: String? { isEmpty ? nil : self } }
