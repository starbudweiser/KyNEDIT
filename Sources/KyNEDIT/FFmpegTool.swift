import Foundation

/// Repli ffmpeg pour les formats qu'AVFoundation ne lit pas (MOV PNG/Animation, MXF, MKV, AVI…).
/// Cherche d'abord un ffmpeg embarqué dans l'appli, puis Homebrew. Optionnel : sans lui, la carte affiche l'extension.
enum FFmpegTool {
    static let ffmpeg: URL? = locate("ffmpeg")
    static let ffprobe: URL? = locate("ffprobe")
    static var available: Bool { ffmpeg != nil && ffprobe != nil }

    private static func locate(_ name: String) -> URL? {
        var candidates: [String] = []
        if let res = Bundle.main.resourcePath { candidates.append(res + "/bin/" + name) }
        candidates += ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
        return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static let queue = DispatchQueue(label: "kynedit.ffmpeg", qos: .utility, attributes: .concurrent)

    /// Lance un exécutable hors du pool Swift ; délai maximal 20 s. Retourne la sortie standard.
    private static func run(_ exe: URL, _ args: [String]) async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            queue.async {
                let p = Process()
                p.executableURL = exe; p.arguments = args
                let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { c.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                queue.asyncAfter(deadline: .now() + 20, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); killer.cancel()
                c.resume(returning: p.terminationStatus == 0 ? data : nil)
            }
        }
    }

    private static func codecName(_ n: String) -> String {
        switch n {
        case "prores": return "ProRes"
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "png": return "PNG"
        case "qtrle": return "Animation (RLE)"
        case "dnxhd": return "DNxHD/HR"
        case "mjpeg": return "Motion JPEG"
        case "mpeg2video": return "MPEG-2"
        case "vp9": return "VP9"
        case "av1": return "AV1"
        default: return n.uppercased()
        }
    }

    static func probe(_ path: String) async -> MediaInfo? {
        guard let probe = ffprobe,
              let data = await run(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                           "stream=codec_name,width,height,r_frame_rate,duration:format=duration", "-of", "json", path]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var info = MediaInfo()
        if let s = (json["streams"] as? [[String: Any]])?.first {
            info.width = s["width"] as? Int ?? 0; info.height = s["height"] as? Int ?? 0
            info.codec = codecName(s["codec_name"] as? String ?? "")
            if let r = s["r_frame_rate"] as? String {
                let p = r.split(separator: "/").compactMap { Double($0) }
                if p.count == 2, p[1] > 0 { info.fps = p[0] / p[1] } else if p.count == 1 { info.fps = p[0] }
            }
            if let d = (s["duration"] as? String).flatMap(Double.init) { info.duration = d }
        }
        if info.duration == 0, let d = ((json["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init) { info.duration = d }
        return info.width > 0 || info.duration > 0 ? info : nil
    }

    /// Image JPEG (côté max `side`) prise à `time` secondes.
    static func thumbnail(_ path: String, time: Double, side: Int) async -> Data? {
        guard let ff = ffmpeg else { return nil }
        let data = await run(ff, ["-v", "error", "-ss", String(format: "%.3f", time), "-i", path, "-frames:v", "1",
                                  "-vf", "scale='if(gt(iw,ih),min(\(side),iw),-2)':'if(gt(iw,ih),-2,min(\(side),ih))'",
                                  "-f", "image2pipe", "-c:v", "mjpeg", "-q:v", "4", "-"])
        return (data?.isEmpty ?? true) ? nil : data
    }
}
