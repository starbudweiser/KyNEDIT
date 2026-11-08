import SwiftUI

let labelColors: [Color] = [.clear, Color(hex: 0x4ADE80), Color(hex: 0xFBBF24), Color(hex: 0xF87171)]

struct StarRating: View {
    let value: Int
    var size: CGFloat = 16
    let onChange: (Int) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Text(i <= value ? "★" : "☆").font(.system(size: size)).foregroundColor(i <= value ? Socle.action : Socle.subtle)
                    .contentShape(Rectangle()).onTapGesture { onChange(i) }
            }
        }
    }
}

/// Retour à la ligne automatique des mots-clés.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 300, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, f) in r.frames.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: .unspecified) }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        var frames: [CGRect] = []
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(x: x, y: y, width: s.width, height: s.height))
            x += s.width + spacing; rowH = max(rowH, s.height); maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), frames)
    }
}

struct InspectorPanel: View {
    let model: AppModel
    let clip: Clip
    @State private var tagText = ""
    @State private var noteText = ""

    var body: some View {
        let m = model.metaFor(clip)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("inspector.title").uppercased()).font(.system(size: 10.5)).tracking(0.8).foregroundColor(Socle.subtle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.name).font(.system(size: 13, weight: .semibold)).foregroundColor(Socle.textStrong).lineLimit(2)
                    if let i = model.selectedInfo, !formatInfo(i).isEmpty { Text(formatInfo(i)).font(.system(size: 11)).foregroundColor(Socle.subtle) }
                }
                VStack(spacing: 3) {
                    if let i = model.selectedInfo {
                        if i.width > 0 { row(L("info.resolution"), "\(i.width) × \(i.height)") }
                        if !i.codec.isEmpty { row(L("info.codec"), i.codec) }
                        if i.duration > 0 { row(L("info.duration"), PlayerModel.timecode(i.duration, fps: i.fps > 0 ? i.fps : 25)) }
                    }
                    row(L("info.size"), ByteCountFormatter.string(fromByteCount: clip.size, countStyle: .file))
                    row(L("info.modified"), Date(timeIntervalSince1970: clip.mtime).formatted(date: .abbreviated, time: .shortened))
                }
                section(L("inspector.rating")) { StarRating(value: m.rating) { model.setRating(clip, $0) } }
                section(L("inspector.label")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(1...3, id: \.self) { c in
                            HStack(spacing: 8) {
                                Circle().fill(labelColors[c]).frame(width: 9, height: 9)
                                Text(L("label.\(c)")).font(.system(size: 12)).foregroundColor(m.color == c ? Socle.textStrong : Socle.text)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(m.color == c ? Color(hex: 0x303030) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle()).onTapGesture { model.setColor(clip, c) }
                        }
                    }
                }
                section(L("inspector.tags")) {
                    VStack(alignment: .leading, spacing: 6) {
                        FlowLayout { ForEach(m.tags, id: \.self) { t in
                            HStack(spacing: 4) { Text(t); Text("✕").font(.system(size: 9)).foregroundColor(Socle.subtle) }
                                .font(.system(size: 11)).foregroundColor(Socle.text).padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Socle.control, in: Capsule()).onTapGesture { model.removeTag(clip, t) }
                        } }
                        TextField(L("inspector.tag.add"), text: $tagText).textFieldStyle(.plain).font(.system(size: 12))
                            .padding(.horizontal, 8).padding(.vertical, 5).background(Socle.sunken, in: RoundedRectangle(cornerRadius: 4))
                            .onSubmit { model.addTag(clip, tagText); tagText = "" }
                    }
                }
                if clip.kind == .video {
                    section(L("export.title")) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 4) {
                                ForEach(ExportPreset.allCases, id: \.self) { p in
                                    Text(p.label).font(.system(size: 11)).lineLimit(1).fixedSize()
                                        .padding(.horizontal, 7).padding(.vertical, 4)
                                        .background(model.exports.preset == p ? Color(hex: 0x404040) : Socle.control, in: RoundedRectangle(cornerRadius: 4))
                                        .foregroundColor(model.exports.preset == p ? Socle.textStrong : Socle.text)
                                        .onTapGesture { model.exports.preset = p }
                                }
                            }
                            HStack {
                                Text(URL(fileURLWithPath: model.exports.outputDir).lastPathComponent).font(.system(size: 11)).foregroundColor(Socle.muted).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(L("export.choose")).font(.system(size: 11)).foregroundColor(Socle.accentText).onTapGesture { model.exports.chooseFolder() }
                            }
                            let subs = model.player.clip?.path == clip.path ? model.player.subclips.count : 0 // même source que le bouton après chargement
                            Text(subs > 0 ? L("export.subclips", subs) : L("export.whole")).font(.system(size: 11)).foregroundColor(Socle.subtle)
                            button(L("action.queue"), main: true) { model.addExport(clip) }
                        }
                    }
                }
                section(L("inspector.note")) {
                    TextEditor(text: $noteText).font(.system(size: 12)).scrollContentBackground(.hidden).foregroundColor(Socle.text)
                        .padding(4).frame(height: 70).background(Socle.sunken, in: RoundedRectangle(cornerRadius: 4))
                        .onChange(of: noteText) { _, n in if n != m.note { model.setNote(clip, n) } }
                }
            }.padding(16)
        }
        .frame(width: 270).background(Socle.surface)
        .onAppear { noteText = m.note }
        .onChange(of: clip.path) { noteText = model.metaFor(clip).note; tagText = "" }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 12)).foregroundColor(Socle.subtle)
            Spacer(minLength: 8)
            Text(v).font(.system(size: 12)).foregroundColor(Socle.textStrong).lineLimit(1)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5)).tracking(0.8).foregroundColor(Socle.subtle)
            content()
        }
    }
}
