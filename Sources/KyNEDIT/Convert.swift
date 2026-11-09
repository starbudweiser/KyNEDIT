import Foundation
import AVFoundation
import VideoToolbox

// MARK: - Réglages de conversion (module « Convertir », inspiré d'EditReady)

enum VCodec: String, Codable, CaseIterable, Sendable {
    case proRes422Proxy, proRes422LT, proRes422, proRes422HQ, proRes4444, proRes4444XQ
    case dnxhrLB, dnxhrSQ, dnxhrHQ, dnxhrHQX, dnxhr444, dnxhdHQ, dnxhdHQX
    case h264, hevc

    var isProRes: Bool { rawValue.hasPrefix("proRes") }
    var isDNx: Bool { rawValue.hasPrefix("dnx") }
    var isHD: Bool { self == .dnxhdHQ || self == .dnxhdHQX }          // DNxHD : 1080p à cadences imposées
    var tenBit: Bool { switch self { case .dnxhrLB, .dnxhrSQ, .dnxhrHQ, .dnxhdHQ, .h264: false; default: true } }
    var avCodec: AVVideoCodecType? {
        switch self {
        case .proRes422Proxy: .proRes422Proxy; case .proRes422LT: .proRes422LT; case .proRes422: .proRes422; case .proRes422HQ: .proRes422HQ
        case .proRes4444: .proRes4444; case .proRes4444XQ: AVVideoCodecType(rawValue: "ap4x"); case .h264: .h264; case .hevc: .hevc; default: nil
        }
    }
    var label: String {
        switch self {
        case .proRes422Proxy: "ProRes 422 Proxy"; case .proRes422LT: "ProRes 422 LT"; case .proRes422: "ProRes 422"; case .proRes422HQ: "ProRes 422 HQ"
        case .proRes4444: "ProRes 4444"; case .proRes4444XQ: "ProRes 4444 XQ"
        case .dnxhrLB: "DNxHR LB"; case .dnxhrSQ: "DNxHR SQ"; case .dnxhrHQ: "DNxHR HQ"; case .dnxhrHQX: "DNxHR HQX"; case .dnxhr444: "DNxHR 444"
        case .dnxhdHQ: "DNxHD (1080p, 8 bits)"; case .dnxhdHQX: "DNxHD (1080p, 10 bits)"; case .h264: "H.264"; case .hevc: "H.265 (HEVC)"
        }
    }
    var tag: String { label.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "").replacingOccurrences(of: ",", with: "") }
    var allowedWraps: [Wrap] { isProRes ? [.mov] : isDNx ? [.mov, .mxf, .mxfAtom] : [.mp4, .mov] }
    var ffProfile: String {
        switch self { case .dnxhrLB: "dnxhr_lb"; case .dnxhrSQ: "dnxhr_sq"; case .dnxhrHQ: "dnxhr_hq"; case .dnxhrHQX: "dnxhr_hqx"; case .dnxhr444: "dnxhr_444"; default: "" }
    }
    /// Débit DNxHD (Mb/s) selon la cadence, nil si la cadence n'existe pas en 1080p.
    func dnxhdRate(fps: Double) -> Int? {
        let table: [(Double, Int, Int)] = [(23.976, 115, 175), (24, 115, 175), (25, 120, 185), (29.97, 145, 220), (30, 145, 220), (50, 240, 365), (59.94, 290, 440), (60, 290, 440)]
        guard let row = table.first(where: { abs($0.0 - fps) < 0.05 }) else { return nil }
        return self == .dnxhdHQX ? row.2 : row.1
    }
}

enum Wrap: String, Codable, CaseIterable, Sendable {
    case mov, mp4, mxf, mxfAtom
    var ext: String { switch self { case .mov: "mov"; case .mp4: "mp4"; default: "mxf" } }
    var label: String { switch self { case .mov: "MOV"; case .mp4: "MP4"; case .mxf: "MXF OP1a"; case .mxfAtom: "MXF OP-Atom" } }
}

/// Courbe + gamut d'origine converti en Rec.709 (calculs fournis par Colour.swift).
enum CamLog: String, Codable, CaseIterable, Sendable {
    case none, logC3, slog3Cine, slog3, vlog, canonLog3, bmdFilmGen5, log3G10
    var label: String {
        switch self {
        case .none: "—"; case .logC3: "ARRI LogC3 / Wide Gamut"; case .slog3Cine: "Sony S-Log3 / S-Gamut3.Cine"; case .slog3: "Sony S-Log3 / S-Gamut3"
        case .vlog: "Panasonic V-Log / V-Gamut"; case .canonLog3: "Canon Log 3 / Cinema Gamut"; case .bmdFilmGen5: "Blackmagic Film Gen 5"; case .log3G10: "RED Log3G10 / RedWideGamut"
        }
    }
}

enum Pos: String, Codable, CaseIterable, Sendable { case tl, tc, tr, bl, bc, br }
enum BurnField: String, Codable, CaseIterable, Sendable { case timecode, reel, clipName, date, custom }
struct BurnItem: Codable, Equatable, Sendable, Hashable { var field: BurnField; var pos: Pos }

enum AudioMode: String, Codable, CaseIterable, Sendable { case all, first, none }
enum AudioChannels: String, Codable, CaseIterable, Sendable { case keep, stereo, mono }

struct ConvertSettings: Codable, Equatable, Sendable {
    var codec: VCodec = .proRes422HQ
    var wrap: Wrap = .mov
    var width = 0, height = 0           // 0 = taille de la source ; sinon boîte dans laquelle l'image est ajustée
    var pad = false                     // remplit la boîte avec des bandes noires (sinon proportions conservées)
    var fps: Double = 0                 // 0 = cadence de la source
    var colorIn: CamLog = .none
    var lutPath: String?
    var audio: AudioMode = .all
    var channels: AudioChannels = .keep
    var burn: [BurnItem] = []
    var customText = ""
    var fontPercent = 3.0               // hauteur du texte en % de la hauteur d'image
    var logoPath: String?
    var logoPos: Pos = .br
    var logoPercent = 12.0              // largeur du logo en % de la largeur d'image
    var logoOpacity = 1.0
    var template = "{name}_{codec}"     // renommage : {name} {reel} {date} {codec} {res} {fps} {tc}
    var recreateFolders = false
    var ale = false

    /// Aucun traitement d'image : les images décodées vont telles quelles à l'encodeur (chemin le plus rapide).
    var passthroughVideo: Bool { width == 0 && fps == 0 && colorIn == .none && lutPath == nil && burn.isEmpty && logoPath == nil }
    var isProResClass: Bool { codec.isProRes }
}

struct ConvertPreset: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var group: String
    var settings: ConvertSettings
    var builtin = false
}

// MARK: - Préréglages fournis + préréglages de l'utilisateur

enum Presets {
    private static func mk(_ id: String, _ name: String, _ group: String, _ codec: VCodec, wrap: Wrap? = nil, _ edit: (inout ConvertSettings) -> Void = { _ in }) -> ConvertPreset {
        var s = ConvertSettings(); s.codec = codec; s.wrap = wrap ?? codec.allowedWraps[0]; edit(&s)
        return ConvertPreset(id: id, name: name, group: group, settings: s, builtin: true)
    }
    private static func size(_ s: inout ConvertSettings, _ w: Int, _ h: Int, pad: Bool = false) { s.width = w; s.height = h; s.pad = pad }
    private static func daily(_ s: inout ConvertSettings) {
        s.burn = [BurnItem(field: .timecode, pos: .bl), BurnItem(field: .clipName, pos: .tl), BurnItem(field: .reel, pos: .br)]
        s.template = "{name}_{reel}"; s.ale = true
    }

    static let builtin: [ConvertPreset] = {
        var p: [ConvertPreset] = []
        let g1 = "group.edit", g2 = "group.proxy", g3 = "group.avid", g4 = "group.delivery", g5 = "group.dailies", g6 = "group.camera"
        // Montage : ProRes à la taille d'origine
        for c in [VCodec.proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy, .proRes4444, .proRes4444XQ] { p.append(mk("edit.\(c.rawValue)", c.label, g1, c)) }
        p.append(mk("edit.prores422hq.hd", "ProRes 422 HQ · 1080p", g1, .proRes422HQ) { size(&$0, 1920, 1080) })
        p.append(mk("edit.prores422hq.uhd", "ProRes 422 HQ · UHD", g1, .proRes422HQ) { size(&$0, 3840, 2160) })
        // Proxys
        p.append(mk("proxy.prores.hd", "ProRes Proxy · 1080p", g2, .proRes422Proxy) { size(&$0, 1920, 1080); $0.template = "{name}_proxy" })
        p.append(mk("proxy.prores.hd.tc", "ProRes Proxy · 1080p + timecode", g2, .proRes422Proxy) { size(&$0, 1920, 1080); $0.burn = [BurnItem(field: .timecode, pos: .bl)]; $0.template = "{name}_proxy" })
        p.append(mk("proxy.prores.720", "ProRes Proxy · 720p", g2, .proRes422Proxy) { size(&$0, 1280, 720); $0.template = "{name}_proxy" })
        p.append(mk("proxy.dnx.lb", "DNxHR LB · 1080p", g2, .dnxhrLB) { size(&$0, 1920, 1080); $0.template = "{name}_proxy" })
        p.append(mk("proxy.h264.720", "H.264 proxy · 720p", g2, .h264) { size(&$0, 1280, 720); $0.template = "{name}_proxy" })
        p.append(mk("proxy.h264.1080.tc", "H.264 proxy · 1080p + timecode", g2, .h264) { size(&$0, 1920, 1080); $0.burn = [BurnItem(field: .timecode, pos: .bl), BurnItem(field: .clipName, pos: .tl)]; $0.template = "{name}_proxy" })
        p.append(mk("proxy.hevc.1080", "H.265 proxy · 1080p", g2, .hevc) { size(&$0, 1920, 1080); $0.template = "{name}_proxy" })
        // Avid
        for c in [VCodec.dnxhrLB, .dnxhrSQ, .dnxhrHQ, .dnxhrHQX, .dnxhr444] { p.append(mk("avid.\(c.rawValue)", "\(c.label) · MOV", g3, c)) }
        p.append(mk("avid.hq.mxf", "DNxHR HQ · MXF OP1a", g3, .dnxhrHQ, wrap: .mxf))
        p.append(mk("avid.hqx.mxf", "DNxHR HQX · MXF OP1a", g3, .dnxhrHQX, wrap: .mxf))
        p.append(mk("avid.hqx.atom", "DNxHR HQX · MXF OP-Atom + ALE", g3, .dnxhrHQX, wrap: .mxfAtom) { $0.ale = true })
        p.append(mk("avid.dnxhd.hq", "DNxHD 1080p · MXF OP1a", g3, .dnxhdHQ, wrap: .mxf) { size(&$0, 1920, 1080, pad: true) })
        p.append(mk("avid.dnxhd.hqx", "DNxHD 1080p 10 bits · MXF OP1a", g3, .dnxhdHQX, wrap: .mxf) { size(&$0, 1920, 1080, pad: true) })
        // Diffusion
        p.append(mk("web.h264.uhd", "H.264 · UHD (YouTube)", g4, .h264) { size(&$0, 3840, 2160); $0.template = "{name}_UHD" })
        p.append(mk("web.h264.1080", "H.264 · 1080p (web, Vimeo)", g4, .h264) { size(&$0, 1920, 1080); $0.template = "{name}_1080p" })
        p.append(mk("web.h264.720", "H.264 · 720p", g4, .h264) { size(&$0, 1280, 720); $0.template = "{name}_720p" })
        p.append(mk("web.h264.540", "H.264 · 540p (aperçu léger)", g4, .h264) { size(&$0, 960, 540); $0.template = "{name}_540p" })
        p.append(mk("web.h264.square", "H.264 · carré 1080 (réseaux sociaux)", g4, .h264) { size(&$0, 1080, 1080, pad: true); $0.template = "{name}_carre" })
        p.append(mk("web.h264.vertical", "H.264 · vertical 1080×1920", g4, .h264) { size(&$0, 1080, 1920, pad: true); $0.template = "{name}_vertical" })
        p.append(mk("web.hevc.uhd", "H.265 · UHD", g4, .hevc) { size(&$0, 3840, 2160); $0.template = "{name}_UHD" })
        p.append(mk("web.hevc.1080", "H.265 · 1080p", g4, .hevc) { size(&$0, 1920, 1080); $0.template = "{name}_1080p" })
        for f in [(24.0, "24"), (25.0, "25"), (30.0, "30")] {
            p.append(mk("web.h264.1080.\(f.1)", "H.264 · 1080p · \(f.1) i/s", g4, .h264) { size(&$0, 1920, 1080); $0.fps = f.0; $0.template = "{name}_1080p\(f.1)" })
        }
        // Rushes
        p.append(mk("daily.h264.1080", "Rushes H.264 · 1080p (timecode, bobine, nom) + ALE", g5, .h264) { size(&$0, 1920, 1080); daily(&$0) })
        p.append(mk("daily.h264.720", "Rushes H.264 · 720p (timecode, nom)", g5, .h264) { size(&$0, 1280, 720); $0.burn = [BurnItem(field: .timecode, pos: .bl), BurnItem(field: .clipName, pos: .tl)]; $0.template = "{name}_rushes" })
        p.append(mk("daily.prores.lt", "Rushes ProRes LT · 1080p + ALE", g5, .proRes422LT) { size(&$0, 1920, 1080); daily(&$0) })
        p.append(mk("daily.dnx.sq", "Rushes DNxHR SQ · 1080p + ALE", g5, .dnxhrSQ) { size(&$0, 1920, 1080); daily(&$0) })
        // Caméras : log vers Rec.709
        let cams: [(CamLog, String)] = [(.logC3, "ARRI LogC3"), (.slog3Cine, "Sony S-Log3"), (.canonLog3, "Canon Log 3"), (.vlog, "Panasonic V-Log"), (.bmdFilmGen5, "Blackmagic Gen 5"), (.log3G10, "RED Log3G10")]
        for (cam, name) in cams {
            p.append(mk("cam.\(cam.rawValue).prores", "\(name) → Rec.709 · ProRes 422 HQ", g6, .proRes422HQ) { $0.colorIn = cam; $0.template = "{name}_709" })
            p.append(mk("cam.\(cam.rawValue).h264", "\(name) → Rec.709 · H.264 1080p", g6, .h264) { $0.colorIn = cam; size(&$0, 1920, 1080); $0.template = "{name}_709_1080p" })
        }
        return p
    }()

    private static var fileURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("kYNEDIT/presets.json") }
    static func loadCustom() -> [ConvertPreset] { (try? JSONDecoder().decode([ConvertPreset].self, from: Data(contentsOf: fileURL))) ?? [] }
    static func saveCustom(_ list: [ConvertPreset]) { try? JSONEncoder().encode(list).write(to: fileURL, options: .atomic) }
}

// MARK: - Métadonnées de la source (renommage, incrustations, ALE)

struct SourceMeta: Codable, Equatable, Sendable {
    var startFrames = 0          // timecode de départ, en images
    var tcFps = 24               // base de comptage du timecode
    var reel = ""
    var date = ""                // AAAA-MM-JJ
    var width = 0, height = 0
    var fps = 0.0
    var codec = ""
    var duration = 0.0
}

enum Timecode {
    static func string(frames: Int, fps: Int) -> String {
        let f = max(1, fps), t = max(0, frames)
        return String(format: "%02d:%02d:%02d:%02d", t / (f * 3600), (t / (f * 60)) % 60, (t / f) % 60, t % f)
    }

    /// Timecode de départ d'un fichier QuickTime/MP4 (piste « tmcd »), à défaut 0.
    static func start(of asset: AVURLAsset) async -> (frames: Int, fps: Int)? {
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let descs = try? await track.load(.formatDescriptions), let d = descs.first else { return nil }
        let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(d))
        guard quanta > 0, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading(), let buf = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) else { return nil }
        var n: UInt32 = 0
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &n) == noErr else { return nil }
        return (Int(UInt32(bigEndian: n)), quanta)
    }
}

enum Naming {
    static func name(template: String, clipName: String, meta: SourceMeta, settings s: ConvertSettings) -> String {
        let res = meta.width > 0 ? "\(meta.width)x\(meta.height)" : ""
        let fps = meta.fps > 0 ? String(format: meta.fps.rounded() == meta.fps ? "%.0f" : "%.2f", meta.fps) : ""
        let tc = Timecode.string(frames: meta.startFrames, fps: meta.tcFps).replacingOccurrences(of: ":", with: "")
        var t = template.isEmpty ? "{name}" : template
        for (k, v) in ["{name}": clipName, "{reel}": meta.reel, "{date}": meta.date, "{codec}": s.codec.tag, "{res}": res, "{fps}": fps, "{tc}": tc] { t = t.replacingOccurrences(of: k, with: v) }
        return t.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
    }
}

enum ALE {
    /// Fichier Avid Log Exchange : une ligne par clip converti.
    static func write(to url: URL, rows: [(name: String, reel: String, source: String, meta: SourceMeta, duration: Double)]) throws {
        let fps = rows.first.map { $0.meta.tcFps } ?? 24
        var out = "Heading\nFIELD_DELIM\tTABS\nVIDEO_FORMAT\t1080\nAUDIO_FORMAT\t48khz\nFPS\t\(fps)\n\nColumn\nName\tTracks\tStart\tEnd\tTape\tSource File\tDuration\n\nData\n"
        for r in rows {
            let start = r.meta.startFrames, frames = Int((r.duration * Double(fps)).rounded())
            out += "\(r.name)\tVA1A2\t\(Timecode.string(frames: start, fps: fps))\t\(Timecode.string(frames: start + frames, fps: fps))\t\(r.reel)\t\(r.source)\t\(Timecode.string(frames: frames, fps: fps))\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
}
