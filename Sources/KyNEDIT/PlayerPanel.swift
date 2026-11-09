import SwiftUI
import AVFoundation
import AppKit

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerView { let v = PlayerLayerView(); v.playerLayer.player = player; return v }
    func updateNSView(_ v: PlayerLayerView, context: Context) { v.playerLayer.player = player }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer = CALayer(); layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect; layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}

struct PlayerPanel: View {
    let model: AppModel
    private var p: PlayerModel { model.player }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                if p.usesBRAW { if let img = p.brawImage { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit) } }
                else if p.playable { VideoSurface(player: p.player) }
                else { Text(L(p.clip?.isRaw == true ? "player.raw" : "player.unsupported")).font(.system(size: 12)).foregroundColor(Socle.subtle).multilineTextAlignment(.center).padding(16) }
            }
            .frame(width: 400, height: 225).frame(maxHeight: .infinity)
            Divider().overlay(Socle.border)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(p.clip?.name ?? "").font(.system(size: 13, weight: .semibold)).foregroundColor(Socle.textStrong).lineLimit(1)
                    Spacer()
                    Text("✕").foregroundColor(Socle.muted).contentShape(Rectangle()).onTapGesture { model.deselect() }
                }
                HStack(spacing: 14) {
                    Text(p.timecode).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundColor(Socle.textStrong).fixedSize()
                    Text(p.rate == 0 ? "■" : String(format: "%@%.0f×", p.rate < 0 ? "◀ " : "▶ ", abs(p.rate))).foregroundColor(Socle.muted)
                    Spacer()
                    Text("I \(p.markIn.map { PlayerModel.timecode($0, fps: p.fps) } ?? "—")   O \(p.markOut.map { PlayerModel.timecode($0, fps: p.fps) } ?? "—")")
                        .font(.system(size: 11).monospacedDigit()).foregroundColor(Socle.subtle)
                }
                Timeline(model: p)
                HStack(spacing: 8) {
                    button(L("player.marker")) { p.addMarker() }
                    button(L("player.subclip"), main: true) { p.addSubclip() }
                    button(p.lutName.map { $0.count > 12 ? String($0.prefix(12)) + "…" : $0 } ?? L("player.lut")) { chooseLUT() }
                    if p.lutName != nil { button("✕") { p.applyLUT(nil) }.help(L("player.nolut")) }
                    Spacer(minLength: 4)
                    ForEach(NLE.allCases, id: \.self) { n in button(n.title.uppercased()) { model.sendToNLE(n) }.help(L("exchange.hint")) }
                }
                if let m = model.exchangeMessage {
                    HStack(spacing: 10) {
                        Text(m.text).font(.system(size: 11)).foregroundColor(Socle.muted).lineLimit(1).truncationMode(.middle)
                        if m.url.pathExtension == "fcpxml" || m.url.pathExtension == "xml" { button(L("exchange.open", m.nle.title.uppercased())) { model.openExchange() } }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    list(L("player.markers"), p.markers.map { m in (m.id, "\(PlayerModel.timecode(m.time, fps: p.fps))  \(m.label)", { p.seek(m.time) }, { p.removeMarker(m) }) })
                    list(L("player.subclips"), p.subclips.map { c in (c.id, "\(PlayerModel.shortTimecode(c.tin, fps: p.fps)) → \(PlayerModel.shortTimecode(c.tout, fps: p.fps))  \(c.name)", { p.seek(c.tin) }, { p.removeSubclip(c) }) })
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: 300).background(Socle.surface)
    }

    private func chooseLUT() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "cube")!]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { p.applyLUT(url) }
    }

    @ViewBuilder private func list(_ title: String, _ rows: [(Int64, String, () -> Void, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 10.5)).tracking(0.8).foregroundColor(Socle.subtle)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.0) { r in
                        HStack { Text(r.1).font(.system(size: 11).monospacedDigit()).foregroundColor(Socle.text).lineLimit(1)
                            Spacer(minLength: 4); Text("✕").font(.system(size: 10)).foregroundColor(Socle.subtle).onTapGesture { r.3() } }
                            .contentShape(Rectangle()).onTapGesture { r.2() }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct Timeline: View {
    let model: PlayerModel
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(model.duration, 0.001)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Socle.sunken)
                ForEach(model.subclips) { s in
                    Rectangle().fill(Color(hex: 0x0EA5E9).opacity(0.35)).frame(width: max(2, w * (s.tout - s.tin) / d)).offset(x: w * s.tin / d)
                }
                if let a = model.markIn { Rectangle().fill(Color(hex: 0x38BDF8)).frame(width: 2).offset(x: w * a / d) }
                if let b = model.markOut { Rectangle().fill(Color(hex: 0x38BDF8)).frame(width: 2).offset(x: w * b / d) }
                ForEach(model.markers) { m in Rectangle().fill(Socle.action).frame(width: 2).offset(x: w * m.time / d) }
                Rectangle().fill(.white).frame(width: 2).offset(x: w * min(model.time, d) / d)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in model.scrub(Double(g.location.x / max(w, 1)) * d) }.onEnded { _ in model.endScrub() })
        }.frame(height: 36)
    }
}
