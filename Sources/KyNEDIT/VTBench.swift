import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia

struct BenchRow: Codable, Sendable, Identifiable {
    var id: String { "\(codec)-\(sessions)" }
    let codec: String; let sessions: Int; let fps: Double; let hardware: Bool
}

struct BenchResult: Codable, Sendable {
    var fingerprint: String
    var date: Date
    var rows: [BenchRow]
    /// Par codec : le plus petit nombre de sessions atteignant 90 % du débit maximal.
    var bestSessions: [String: Int]
}

enum BenchStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("kYNEDIT/bench.json")
    }
    /// Empreinte de la machine : modèle, puce, mémoire, version du système.
    static var fingerprint: String {
        let p = HardwareProfile.current
        return "\(p.model)|\(p.chip)|\(p.memoryGB)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
    static func load() -> BenchResult? {
        guard let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(BenchResult.self, from: d), r.fingerprint == fingerprint else { return nil }
        return r
    }
    static func save(_ r: BenchResult) { try? JSONEncoder().encode(r).write(to: url, options: .atomic) }
}

/// Banc d'essai des encodeurs matériels : encode des images 4K synthétiques avec 1, 2 puis 4 sessions parallèles.
/// Le gain de débit selon le nombre de sessions révèle le nombre de moteurs média réellement disponibles.
enum VTBench {
    static let codecs: [(name: String, type: CMVideoCodecType, pixel: OSType)] = [
        ("HEVC", kCMVideoCodecType_HEVC, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        ("H.264", kCMVideoCodecType_H264, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        ("ProRes 422 HQ", kCMVideoCodecType_AppleProRes422HQ, kCVPixelFormatType_422YpCbCr10),
    ]
    static let sessionCounts = [1, 2, 4]
    static let width = 3840, height = 2160, frames = 60

    /// Une session : encode `frames` images. Retourne (secondes, matériel ?) ou nil si l'encodeur ne démarre pas.
    private static func runSession(type: CMVideoCodecType, pixel: OSType) -> (seconds: Double, hardware: Bool)? {
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: type, encoderSpecification: spec,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                         compressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        var hw: CFTypeRef?
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hw)
        let hardware = (hw as? Bool) ?? false
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { return nil }

        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, pixel, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        fillNoise(pb)
        let t0 = DispatchTime.now()
        for i in 0..<frames {
            let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30),
                                                     duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
            if st != noErr { return nil }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return (Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9, hardware)
    }

    private static func fillNoise(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        var x: UInt64 = 0x9E3779B97F4A7C15
        let planes = max(1, CVPixelBufferGetPlaneCount(pb))
        for p in 0..<planes {
            let base = planes > 1 ? CVPixelBufferGetBaseAddressOfPlane(pb, p) : CVPixelBufferGetBaseAddress(pb)
            let bytes = planes > 1 ? CVPixelBufferGetBytesPerRowOfPlane(pb, p) * CVPixelBufferGetHeightOfPlane(pb, p) : CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
            guard let base else { continue }
            let words = base.bindMemory(to: UInt64.self, capacity: bytes / 8)
            for i in 0..<(bytes / 8) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; words[i] = x & 0x3F3F3F3F3F3F3F3F | 0x2020202020202020 }
        }
    }

    /// Lance tout le banc d'essai ; `progress` reçoit chaque ligne dès qu'elle est mesurée.
    static func run(progress: @escaping @Sendable (BenchRow) -> Void) async -> BenchResult {
        await withCheckedContinuation { (c: CheckedContinuation<BenchResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var rows: [BenchRow] = []
                for codec in codecs {
                    for k in sessionCounts {
                        nonisolated(unsafe) var results = [(Double, Bool)?](repeating: nil, count: k)
                        let t0 = DispatchTime.now()
                        let lock = NSLock()
                        DispatchQueue.concurrentPerform(iterations: k) { i in
                            let r = runSession(type: codec.type, pixel: codec.pixel)
                            lock.lock(); results[i] = r.map { ($0.seconds, $0.hardware) }; lock.unlock()
                        }
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
                        let ok = results.compactMap { $0 }
                        guard ok.count == k else { continue }
                        let row = BenchRow(codec: codec.name, sessions: k, fps: Double(k * frames) / elapsed, hardware: ok.allSatisfy { $0.1 })
                        rows.append(row); progress(row)
                    }
                }
                var best: [String: Int] = [:]
                for name in Set(rows.map(\.codec)) {
                    let r = rows.filter { $0.codec == name }
                    let top = r.map(\.fps).max() ?? 0
                    best[name] = r.sorted { $0.sessions < $1.sessions }.first { $0.fps >= 0.9 * top }?.sessions ?? 1
                }
                let result = BenchResult(fingerprint: BenchStore.fingerprint, date: Date(), rows: rows, bestSessions: best)
                BenchStore.save(result)
                c.resume(returning: result)
            }
        }
    }
}
