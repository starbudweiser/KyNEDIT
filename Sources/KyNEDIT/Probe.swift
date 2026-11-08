import Foundation
import AVFoundation
import ImageIO

struct MediaInfo: Sendable, Equatable {
    var duration: Double = 0
    var width = 0, height = 0
    var fps: Double = 0
    var codec = ""
}

enum Prober {
    /// Nom lisible d'un codec vidéo (code FourCC).
    static func codecName(_ fourCC: FourCharCode) -> String {
        let raw = String(format: "%c%c%c%c", (fourCC >> 24) & 255, (fourCC >> 16) & 255, (fourCC >> 8) & 255, fourCC & 255)
        switch raw {
        case "apco": return "ProRes Proxy"
        case "apcs": return "ProRes LT"
        case "apcn": return "ProRes 422"
        case "apch": return "ProRes 422 HQ"
        case "ap4h": return "ProRes 4444"
        case "ap4x": return "ProRes 4444 XQ"
        case "aprn", "aprh": return "ProRes RAW"
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4v": return "MPEG-4"
        case "jpeg", "mjpa": return "Motion JPEG"
        case "AVdn", "AVdh": return "DNxHD/HR"
        default: return raw.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Lit les en-têtes du fichier (sans décoder d'images). nil si le format n'est pas lisible par AVFoundation / ImageIO.
    static func probe(_ clip: Clip) async -> MediaInfo? {
        let url = URL(fileURLWithPath: clip.path)
        switch clip.kind {
        case .image:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
            var i = MediaInfo()
            i.width = (p[kCGImagePropertyPixelWidth] as? Int) ?? 0
            i.height = (p[kCGImagePropertyPixelHeight] as? Int) ?? 0
            return i
        case .audio, .video:
            if clip.ext == "braw" { return BRAWClipHandle(path: clip.path)?.mediaInfo }
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration.isNumeric else { return await FFmpegTool.probe(clip.path) }
            var info = MediaInfo(duration: duration.seconds)
            if clip.kind == .video, let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, fps, transform, descs) = try? await track.load(.naturalSize, .nominalFrameRate, .preferredTransform, .formatDescriptions) {
                let s = size.applying(transform)
                info.width = Int(abs(s.width).rounded()); info.height = Int(abs(s.height).rounded())
                info.fps = Double(fps)
                if let d = descs.first { info.codec = codecName(CMFormatDescriptionGetMediaSubType(d)) }
            }
            return info
        }
    }
}
