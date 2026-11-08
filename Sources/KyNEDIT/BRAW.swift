import Foundation
import CoreGraphics
import CBRAW

/// Clip Blackmagic RAW ouvert par le SDK du fabricant (chargé à l'exécution depuis BlackmagicRawAPI.framework).
final class BRAWClipHandle: @unchecked Sendable {
    private let ptr: OpaquePointer
    let width: Int, height: Int, fps: Double, frameCount: Int
    let audio: (channels: Int, rate: Int, bits: Int, samples: Int)?
    var duration: Double { fps > 0 ? Double(frameCount) / fps : 0 }

    /// Dossiers où chercher BlackmagicRawAPI.framework : l'appli d'abord, puis l'installation officielle de Blackmagic RAW.
    static let frameworkDirs: [String] = [Bundle.main.privateFrameworksPath,
                                          "/Applications/Blackmagic RAW/Blackmagic RAW Player.app/Contents/Frameworks",
                                          "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries"].compactMap { $0 }
        .filter { FileManager.default.fileExists(atPath: $0 + "/BlackmagicRawAPI.framework") }

    /// Le SDK est-il présent sur cette machine ?
    static var available: Bool { !frameworkDirs.isEmpty }

    init?(path: String) {
        guard Self.available, let c = braw_open(path, Self.frameworkDirs.joined(separator: ":")) else { return nil }
        var w: UInt32 = 0, h: UInt32 = 0, f: Float = 0, n: UInt64 = 0
        guard braw_info(c, &w, &h, &f, &n) == 0 else { braw_close(c); return nil }
        ptr = c; width = Int(w); height = Int(h); fps = Double(f); frameCount = Int(n)
        var ch: UInt32 = 0, rate: UInt32 = 0, bits: UInt32 = 0, samples: UInt64 = 0
        audio = braw_audio_info(c, &ch, &rate, &bits, &samples) == 0 && samples > 0 ? (Int(ch), Int(rate), Int(bits), Int(samples)) : nil
    }

    deinit { braw_close(ptr) }

    var cameraName: String {
        var buf = [CChar](repeating: 0, count: 256)
        return braw_camera(ptr, &buf, 256) == 0 ? String(cString: buf) : ""
    }

    func timecode(_ frame: Int) -> String {
        var buf = [CChar](repeating: 0, count: 32)
        return braw_timecode(ptr, UInt64(frame), &buf, 32) == 0 ? String(cString: buf) : ""
    }

    /// Taille d'une image à l'échelle `scale` (0 pleine, 1 moitié, 2 quart, 3 huitième).
    func size(scale: Int) -> (Int, Int) { let d = 1 << scale; return (max(1, width / d), max(1, height / d)) }

    /// Décode une image en BGRA 8 bits dans `buffer` (au moins largeur × hauteur × 4 octets de cette échelle).
    func decode(_ frame: Int, scale: Int, into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> (width: Int, height: Int)? {
        var w: UInt32 = 0, h: UInt32 = 0
        guard braw_decode(ptr, UInt64(frame), Int32(scale), buffer, UInt32(capacity), &w, &h) == 0 else { return nil }
        return (Int(w), Int(h))
    }

    /// Image décodée sous forme de CGImage (BGRA 8 bits).
    func cgImage(_ frame: Int, scale: Int) -> CGImage? {
        let (mw, mh) = size(scale: scale)
        let capacity = (mw + 64) * (mh + 64) * 4
        var data = Data(count: capacity)
        let result: (Int, Int)? = data.withUnsafeMutableBytes { raw in
            decode(frame, scale: scale, into: raw.bindMemory(to: UInt8.self).baseAddress!, capacity: capacity).map { ($0.width, $0.height) }
        }
        guard let (w, h) = result, let provider = CGDataProvider(data: data.prefix(w * h * 4) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Échantillons audio PCM entrelacés. Retourne les octets lus.
    func readAudio(from start: Int, maxSamples: Int) -> Data? {
        guard let a = audio else { return nil }
        let bytesPerSample = a.channels * a.bits / 8
        var data = Data(count: maxSamples * bytesPerSample)
        let n: Int64 = data.withUnsafeMutableBytes { raw in braw_audio_read(ptr, Int64(start), raw.bindMemory(to: UInt8.self).baseAddress!, UInt32(raw.count), UInt32(maxSamples)) }
        return n > 0 ? data.prefix(Int(n) * bytesPerSample) : nil
    }

    var mediaInfo: MediaInfo { MediaInfo(duration: duration, width: width, height: height, fps: fps, codec: "Blackmagic RAW") }
}
