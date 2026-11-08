import Foundation
import AVFoundation

/// Un clip prêt à être envoyé à un logiciel de montage, avec ce que kYNEDIT y a ajouté.
struct ExchangeClip: Sendable {
    let path: String
    let name: String
    let duration: Double
    let fps: Double
    let width: Int, height: Int
    let audioChannels: Int, audioRate: Int
    var markers: [Marker] = []
    var subclips: [Subclip] = []
    var tags: [String] = []
    var rating = 0
    var color = 0
    var note = ""

    var hasAudio: Bool { audioChannels > 0 }
}

enum NLE: String, CaseIterable, Sendable { case resolve, finalCut, premiere
    var title: String { switch self { case .resolve: "DaVinci Resolve"; case .finalCut: "Final Cut Pro"; case .premiere: "Premiere Pro" } }
    /// Format d'échange : Resolve et Final Cut lisent le FCPXML, Premiere lit le XML « xmeml ».
    var ext: String { self == .premiere ? "xml" : "fcpxml" }
    var bundleHints: [String] {
        switch self {
        case .resolve: ["DaVinci Resolve"]
        case .finalCut: ["Final Cut Pro"]
        case .premiere: ["Adobe Premiere Pro 2026", "Adobe Premiere Pro (Beta)"]
        }
    }
}

enum Exchange {
    // MARK: temps
    /// Cadences NTSC fractionnaires : 23,976 / 29,97 / 59,94 ont une durée d'image de 1001/(n×1000).
    private static func frameParts(_ fps: Double) -> (num: Int, den: Int, timebase: Int, ntsc: Bool) {
        let rounded = Int(fps.rounded())
        if abs(fps - Double(rounded) * 1000.0 / 1001.0) < 0.02 { return (1001, rounded * 1000, rounded, true) }
        return (1, max(1, rounded), max(1, rounded), false)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// Durée exacte de `frames` images, en secondes rationnelles FCPXML (« 1001/24000s »).
    private static func fcpTime(frames: Int, fps: Double) -> String {
        let f = frameParts(fps)
        let n = frames * f.num, d = f.den
        if n == 0 { return "0s" }
        let g = gcd(n, d)
        return d / g == 1 ? "\(n / g)s" : "\(n / g)/\(d / g)s"
    }

    private static func frames(_ seconds: Double, _ fps: Double) -> Int { Int((seconds * fps).rounded()) }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Segments du montage : les sous-clips de chaque clip, ou le clip entier s'il n'en a pas.
    private struct Segment { let clip: ExchangeClip; let name: String; let tin: Int; let tout: Int }
    private static func segments(_ clips: [ExchangeClip]) -> [Segment] {
        clips.flatMap { c -> [Segment] in
            let total = frames(c.duration, c.fps)
            if c.subclips.isEmpty { return [Segment(clip: c, name: c.name, tin: 0, tout: total)] }
            return c.subclips.map { Segment(clip: c, name: "\(c.name) · \($0.name)", tin: frames($0.tin, c.fps), tout: min(total, frames($0.tout, c.fps))) }
        }.filter { $0.tout > $0.tin }
    }

    // MARK: FCPXML 1.11 (Final Cut Pro, DaVinci Resolve)
    static func fcpxml(_ clips: [ExchangeClip], eventName: String) -> String {
        struct Fmt: Hashable { let w: Int, h: Int, fps: Double }
        var formats: [Fmt] = [], assets = "", clipsXML = ""
        var fmtID: [Fmt: String] = [:], assetID: [String: String] = [:]
        var nextID = 1
        func id() -> String { defer { nextID += 1 }; return "r\(nextID)" }
        for c in clips {
            let f = Fmt(w: c.width, h: c.height, fps: c.fps)
            if fmtID[f] == nil { fmtID[f] = id(); formats.append(f) }
        }
        for c in clips {
            let fid = fmtID[Fmt(w: c.width, h: c.height, fps: c.fps)]!
            let aid = id(); assetID[c.path] = aid
            let dur = fcpTime(frames: frames(c.duration, c.fps), fps: c.fps)
            let src = URL(fileURLWithPath: c.path).absoluteString
            assets += "    <asset id=\"\(aid)\" name=\"\(esc(c.name))\" start=\"0s\" duration=\"\(dur)\" hasVideo=\"1\" format=\"\(fid)\""
            assets += c.hasAudio ? " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(c.audioChannels)\" audioRate=\"\(c.audioRate)\">\n" : ">\n"
            assets += "      <media-rep kind=\"original-media\" src=\"\(esc(src))\"/>\n    </asset>\n"
            // Clip entier dans l'événement, avec marqueurs, mots-clés, note et commentaire.
            let total = frames(c.duration, c.fps)
            clipsXML += "      <asset-clip ref=\"\(aid)\" name=\"\(esc(c.name))\" duration=\"\(dur)\" start=\"0s\" format=\"\(fid)\" tcFormat=\"NDF\">\n"
            if !c.note.isEmpty { clipsXML += "        <note>\(esc(c.note))</note>\n" }
            let oneFrame = fcpTime(frames: 1, fps: c.fps)
            for m in c.markers { clipsXML += "        <marker start=\"\(fcpTime(frames: min(total - 1, frames(m.time, c.fps)), fps: c.fps))\" duration=\"\(oneFrame)\" value=\"\(esc(m.label))\"/>\n" }
            var keywords = c.tags
            if c.rating > 0 { keywords.append(String(repeating: "★", count: c.rating)) }
            if !keywords.isEmpty { clipsXML += "        <keyword start=\"0s\" duration=\"\(dur)\" value=\"\(esc(keywords.joined(separator: ", ")))\"/>\n" }
            if c.color == 1 { clipsXML += "        <rating start=\"0s\" duration=\"\(dur)\" value=\"favorite\"/>\n" }
            if c.color == 3 { clipsXML += "        <rating start=\"0s\" duration=\"\(dur)\" value=\"reject\"/>\n" }
            clipsXML += "      </asset-clip>\n"
        }
        // Projet : les segments à la suite.
        let segs = segments(clips)
        var spine = "", offset = 0
        let seqFmt = segs.first.map { fmtID[Fmt(w: $0.clip.width, h: $0.clip.height, fps: $0.clip.fps)]! } ?? formats.first.flatMap { fmtID[$0] } ?? "r1"
        let seqFPS = segs.first?.clip.fps ?? clips.first?.fps ?? 25
        for s in segs {
            let len = s.tout - s.tin
            // Un clip d'une autre cadence que la séquence garde sa durée en secondes : on convertit en images de la séquence.
            let lenSeq = s.clip.fps == seqFPS ? len : max(1, Int((Double(len) / s.clip.fps * seqFPS).rounded()))
            spine += "            <asset-clip ref=\"\(assetID[s.clip.path]!)\" name=\"\(esc(s.name))\" offset=\"\(fcpTime(frames: offset, fps: seqFPS))\" start=\"\(fcpTime(frames: s.tin, fps: s.clip.fps))\" duration=\"\(fcpTime(frames: lenSeq, fps: seqFPS))\" format=\"\(fmtID[Fmt(w: s.clip.width, h: s.clip.height, fps: s.clip.fps)]!)\" tcFormat=\"NDF\"/>\n"
            offset += lenSeq
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n<fcpxml version=\"1.11\">\n  <resources>\n"
        for f in formats {
            out += "    <format id=\"\(fmtID[f]!)\" frameDuration=\"\(fcpTime(frames: 1, fps: f.fps))\" width=\"\(f.w)\" height=\"\(f.h)\"/>\n"
        }
        out += assets + "  </resources>\n  <library>\n    <event name=\"\(esc(eventName))\">\n" + clipsXML
        if !segs.isEmpty {
            out += "      <project name=\"\(esc(eventName))\">\n        <sequence format=\"\(seqFmt)\" duration=\"\(fcpTime(frames: offset, fps: seqFPS))\" tcStart=\"0s\" tcFormat=\"NDF\">\n          <spine>\n" + spine + "          </spine>\n        </sequence>\n      </project>\n"
        }
        out += "    </event>\n  </library>\n</fcpxml>\n"
        return out
    }

    // MARK: xmeml 4 (Premiere Pro)
    static func xmeml(_ clips: [ExchangeClip], name: String) -> String {
        let segs = segments(clips)
        let seqFPS = segs.first?.clip.fps ?? clips.first?.fps ?? 25
        let seq = frameParts(seqFPS)
        let seqW = segs.first?.clip.width ?? clips.first?.width ?? 1920, seqH = segs.first?.clip.height ?? clips.first?.height ?? 1080
        func rate(_ fps: Double) -> String { let f = frameParts(fps); return "<rate><timebase>\(f.timebase)</timebase><ntsc>\(f.ntsc ? "TRUE" : "FALSE")</ntsc></rate>" }
        var fileIDs: [String: String] = [:]
        var video = "", audioTracks: [Int: String] = [:]
        var position = 0, itemNo = 0
        func fileXML(_ c: ExchangeClip) -> String {
            if let id = fileIDs[c.path] { return "<file id=\"\(id)\"/>" }
            let id = "file-\(fileIDs.count + 1)"; fileIDs[c.path] = id
            let url = "file://localhost" + (URL(fileURLWithPath: c.path).absoluteString.replacingOccurrences(of: "file://", with: ""))
            var x = "<file id=\"\(id)\"><name>\(esc((c.path as NSString).lastPathComponent))</name><pathurl>\(esc(url))</pathurl>\(rate(c.fps))<duration>\(frames(c.duration, c.fps))</duration>"
            x += "<timecode>\(rate(c.fps))<string>00:00:00:00</string><frame>0</frame><displayformat>NDF</displayformat></timecode><media><video><samplecharacteristics>\(rate(c.fps))<width>\(c.width)</width><height>\(c.height)</height><pixelaspectratio>square</pixelaspectratio></samplecharacteristics></video>"
            if c.hasAudio { x += "<audio><samplecharacteristics><depth>16</depth><samplerate>\(c.audioRate)</samplerate></samplecharacteristics><channelcount>\(c.audioChannels)</channelcount></audio>" }
            return x + "</media></file>"
        }
        for s in segs {
            let c = s.clip, len = s.tout - s.tin
            let lenSeq = c.fps == seqFPS ? len : max(1, Int((Double(len) / c.fps * seqFPS).rounded()))
            itemNo += 1
            let file = fileXML(c)
            var item = "<clipitem id=\"clipitem-\(itemNo)\"><name>\(esc(s.name))</name><enabled>TRUE</enabled><duration>\(frames(c.duration, c.fps))</duration>\(rate(c.fps))<start>\(position)</start><end>\(position + lenSeq)</end><in>\(s.tin)</in><out>\(s.tout)</out>"
            item += file
            for m in c.markers where frames(m.time, c.fps) >= s.tin && frames(m.time, c.fps) < s.tout {
                let f = frames(m.time, c.fps)
                item += "<marker><name>\(esc(m.label))</name><comment></comment><in>\(f)</in><out>\(f)</out></marker>"
            }
            if !c.note.isEmpty { item += "<comments><mastercomment1>\(esc(c.note))</mastercomment1></comments>" }
            video += item + "<link><linkclipref>clipitem-\(itemNo)</linkclipref><mediatype>video</mediatype><trackindex>1</trackindex><clipindex>\(itemNo)</clipindex></link></clipitem>"
            if c.hasAudio {
                for ch in 1...min(c.audioChannels, 2) {
                    audioTracks[ch, default: ""] += "<clipitem id=\"clipitem-a\(ch)-\(itemNo)\"><name>\(esc(s.name))</name><enabled>TRUE</enabled><duration>\(frames(c.duration, c.fps))</duration>\(rate(c.fps))<start>\(position)</start><end>\(position + lenSeq)</end><in>\(s.tin)</in><out>\(s.tout)</out><file id=\"\(fileIDs[c.path]!)\"/><sourcetrack><mediatype>audio</mediatype><trackindex>\(ch)</trackindex></sourcetrack></clipitem>"
                }
            }
            position += lenSeq
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE xmeml>\n<xmeml version=\"4\">\n<sequence id=\"sequence-1\"><name>\(esc(name))</name><duration>\(position)</duration>\(rate(seqFPS))"
        out += "<timecode>\(rate(seqFPS))<string>00:00:00:00</string><frame>0</frame><displayformat>NDF</displayformat></timecode>"
        out += "<media><video><format><samplecharacteristics>\(rate(seqFPS))<width>\(seqW)</width><height>\(seqH)</height><pixelaspectratio>square</pixelaspectratio><fielddominance>none</fielddominance></samplecharacteristics></format><track>\(video)</track></video>"
        if !audioTracks.isEmpty {
            out += "<audio><numOutputChannels>2</numOutputChannels>"
            for k in audioTracks.keys.sorted() { out += "<track>\(audioTracks[k]!)</track>" }
            out += "</audio>"
        }
        _ = seq
        return out + "</media></sequence>\n</xmeml>\n"
    }

    // MARK: lecture des clips
    /// Rassemble pour chaque clip ce qu'il faut à l'échange : infos média, piste audio, marqueurs, sous-clips, notes.
    static func collect(_ clips: [Clip], catalog: Catalog, thumbs: ThumbService, meta: [String: ClipMeta]) async -> [ExchangeClip] {
        var out: [ExchangeClip] = []
        for c in clips where c.kind == .video {
            guard let info = await thumbs.load(c).info, info.duration > 0 else { continue }
            var channels = 0, rate = 48000
            if let raw = Raw.open(c.path) { if let a = raw.audio { channels = a.channels; rate = a.rate } }
            else if let track = try? await AVURLAsset(url: URL(fileURLWithPath: c.path)).loadTracks(withMediaType: .audio).first,
                    let d = try? await track.load(.formatDescriptions).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                channels = Int(asbd.mChannelsPerFrame); rate = Int(asbd.mSampleRate)
            }
            let m = meta[c.path] ?? ClipMeta()
            out.append(ExchangeClip(path: c.path, name: c.name, duration: info.duration, fps: info.fps > 0 ? info.fps : 25, width: max(info.width, 1), height: max(info.height, 1),
                                    audioChannels: channels, audioRate: rate, markers: await catalog.markers(path: c.path), subclips: await catalog.subclips(path: c.path),
                                    tags: m.tags, rating: m.rating, color: m.color, note: m.note))
        }
        return out
    }

    /// Écrit le fichier d'échange dans `dir` et retourne son chemin. Un nom déjà pris reçoit un numéro.
    static func write(_ clips: [ExchangeClip], for nle: NLE, to dir: String, title: String) throws -> URL {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let text = nle == .premiere ? xmeml(clips, name: title) : fcpxml(clips, eventName: title)
        var url = URL(fileURLWithPath: dir).appendingPathComponent("\(title)_\(nle == .premiere ? "Premiere" : nle == .resolve ? "Resolve" : "FinalCut").\(nle.ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = URL(fileURLWithPath: dir).appendingPathComponent("\(title)_\(nle.rawValue)_\(n).\(nle.ext)"); n += 1 }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
