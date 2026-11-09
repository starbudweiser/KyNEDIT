import Foundation

/// Une partie d'un assemblage : un clip (ou une plage) avec ses métadonnées.
struct AssemblyPart: Codable, Equatable, Sendable {
    var path: String
    var tin: Double?
    var tout: Double?
    var meta: SourceMeta
    var clipName: String
}

/// Exécution fractionnée : la sortie est faite de segments convertis séparément (en parallèle ou l'un après l'autre),
/// puis réunis sans réencodage (concat ffmpeg). Sert à l'assemblage de plusieurs clips (essayé aussi pour la conversion parallèle d'un seul clip : aucun gain mesuré, l'encodeur n'est pas le goulot, et une image en trop apparaissait à la jonction).
final class SegmentedTranscoder: @unchecked Sendable {
    struct Segment { var part: AssemblyPart; var settings: ConvertSettings }
    private let segments: [Segment], output: URL, parallel: Int, wrap: Wrap
    private let lock = NSLock()
    private var cancelled = false
    private var children: [ConvertTranscoder] = []
    private var proc: Process?

    init(segments: [Segment], output: URL, parallel: Int, wrap: Wrap) { self.segments = segments; self.output = output; self.parallel = max(1, parallel); self.wrap = wrap }

    func cancel() {
        lock.lock(); cancelled = true; let c = children; lock.unlock()
        c.forEach { $0.cancel() }; proc?.terminate()
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kynedit-seg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = segments.count
        let done = ProgressBox(n)
        let files = segments.indices.map { dir.appendingPathComponent(String(format: "seg%03d.%@", $0, wrap.ext)) }
        var total = 0.0
        // Les segments partent par vagues de `parallel`.
        var next = 0
        try await withThrowingTaskGroup(of: Double.self) { group in
            func launch() {
                guard next < n else { return }
                let i = next; next += 1
                let seg = segments[i]
                let t = ConvertTranscoder(path: seg.part.path, tin: seg.part.tin, tout: seg.part.tout, settings: seg.settings, meta: seg.part.meta, clipName: seg.part.clipName, output: files[i])
                lock.lock(); children.append(t); let c = cancelled; lock.unlock()
                if c { t.cancel() }
                group.addTask { try await t.run { p in progress(done.set(i, p) * 0.97) } }
            }
            for _ in 0..<min(parallel, n) { launch() }
            while let d = try await group.next() { total += d; launch() }
        }
        if isCancelled { throw ExportError(message: "Annulé.") }
        try concat(files, dir: dir)
        progress(1)
        return total
    }

    private func concat(_ files: [URL], dir: URL) throws {
        guard let ff = FFmpegTool.ffmpeg else { throw ExportError(message: "L'assemblage demande ffmpeg (introuvable).") }
        let list = dir.appendingPathComponent("list.txt")
        try files.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let part = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: part)
        let p = Process(); p.executableURL = ff
        p.arguments = ["-hide_banner", "-y", "-loglevel", "error", "-nostdin", "-f", "concat", "-safe", "0", "-i", list.path, "-map", "0", "-c", "copy", "-f", wrap == .mp4 ? "mp4" : wrap == .mxf ? "mxf" : "mov", part.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        proc = p
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { try? FileManager.default.removeItem(at: part); throw ExportError(message: "Assemblage impossible (flux incompatibles).") }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: part, to: output)
    }
}

/// Progression cumulée de plusieurs segments (verrouillée).
final class ProgressBox: @unchecked Sendable {
    private var v: [Double]; private let l = NSLock()
    init(_ n: Int) { v = Array(repeating: 0, count: n) }
    func set(_ i: Int, _ p: Double) -> Double { l.lock(); defer { l.unlock() }; v[i] = p; return v.reduce(0, +) / Double(v.count) }
}
