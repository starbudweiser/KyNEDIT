import Foundation
import AppKit

struct ExportJob: Identifiable, Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case waiting, running, done, failed, cancelled }
    var id = UUID()
    var path: String
    var name: String          // nom affiché (clip, ou clip · sous-clip)
    var tin: Double?
    var tout: Double?
    var preset: ExportPreset
    var outputDir: String
    var suffix: String        // ajouté au nom de fichier (nom du sous-clip)
    var state: State = .waiting
    var progress = 0.0
    var error: String?
    var outputPath: String?
    var seconds: Double?      // durée du média écrit
    var elapsed: Double?      // temps de calcul
}

/// File d'export : lance les tâches selon le planificateur (une classe de moteur ProRes, une classe vidéo), mémorise la file sur disque.
@MainActor @Observable
final class ExportQueue {
    var jobs: [ExportJob] = []
    var preset: ExportPreset = ExportPreset(rawValue: UserDefaults.standard.string(forKey: "exportPreset") ?? "") ?? .proRes422HQ {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: "exportPreset") }
    }
    var outputDir: String = UserDefaults.standard.string(forKey: "exportDir")
        ?? (FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("kYNEDIT").path) {
        didSet { UserDefaults.standard.set(outputDir, forKey: "exportDir") }
    }
    private var transcoders: [UUID: Transcoder] = [:]

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("kYNEDIT/exports.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode([ExportJob].self, from: d) {
            // Reprise : ce qui tournait au moment de l'arrêt repart de zéro (le fichier partiel est écrasé).
            jobs = saved.map { var j = $0; if j.state == .running { j.state = .waiting; j.progress = 0 }; return j }
            DispatchQueue.main.async { [weak self] in self?.pump() }
        }
    }

    var pendingCount: Int { jobs.filter { $0.state == .waiting || $0.state == .running }.count }

    private func save() { try? JSONEncoder().encode(jobs).write(to: Self.fileURL, options: .atomic) }

    func add(clip: Clip, subclips: [Subclip]) {
        guard clip.kind == .video else { return }
        if subclips.isEmpty {
            jobs.append(ExportJob(path: clip.path, name: clip.name, preset: preset, outputDir: outputDir, suffix: ""))
        } else {
            for s in subclips {
                jobs.append(ExportJob(path: clip.path, name: "\(clip.name) · \(s.name)", tin: s.tin, tout: s.tout, preset: preset, outputDir: outputDir, suffix: "_" + s.name.replacingOccurrences(of: " ", with: "")))
            }
        }
        save(); pump()
    }

    func cancel(_ id: UUID) {
        transcoders[id]?.cancel()
        if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .waiting { jobs[i].state = .cancelled }
        save()
    }

    func remove(_ id: UUID) { cancel(id); jobs.removeAll { $0.id == id }; save() }
    func clearFinished() { jobs.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }; save() }
    func retry(_ id: UUID) { if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = .waiting; jobs[i].progress = 0; jobs[i].error = nil; save(); pump() } }

    /// Démarre les tâches en attente tant qu'il reste de la place dans leur classe (ProRes / vidéo).
    func pump() {
        for proRes in [true, false] {
            let slots = Scheduler.exportSlots(proRes: proRes)
            var running = jobs.filter { $0.state == .running && $0.preset.isProRes == proRes }.count
            while running < slots, let i = jobs.firstIndex(where: { $0.state == .waiting && $0.preset.isProRes == proRes }) {
                start(index: i); running += 1
            }
        }
    }

    private func outputURL(for job: ExportJob) -> URL {
        let dir = URL(fileURLWithPath: job.outputDir, isDirectory: true)
        let base = ((job.path as NSString).lastPathComponent as NSString).deletingPathExtension
        var url = dir.appendingPathComponent("\(base)\(job.suffix)_\(job.preset.tag).\(job.preset.ext)")
        var n = 2
        // Un nom déjà pris (autre tâche ou fichier existant) reçoit un numéro : jamais d'écrasement d'un fichier existant.
        let taken = Set(jobs.filter { $0.id != job.id }.compactMap(\.outputPath))
        while FileManager.default.fileExists(atPath: url.path) || taken.contains(url.path) {
            url = dir.appendingPathComponent("\(base)\(job.suffix)_\(job.preset.tag)_\(n).\(job.preset.ext)"); n += 1
        }
        return url
    }

    private func start(index i: Int) {
        var job = jobs[i]
        try? FileManager.default.createDirectory(atPath: job.outputDir, withIntermediateDirectories: true)
        let out = outputURL(for: job)
        job.state = .running; job.progress = 0; job.error = nil; job.outputPath = out.path
        jobs[i] = job
        let id = job.id
        let t = Transcoder(path: job.path, tin: job.tin, tout: job.tout, preset: job.preset, output: out)
        transcoders[id] = t
        save()
        Task {
            let t0 = Date()
            do {
                let secs = try await t.run { p in Task { @MainActor in self.setProgress(id, p) } }
                finish(id) { $0.state = .done; $0.progress = 1; $0.seconds = secs; $0.elapsed = Date().timeIntervalSince(t0) }
            } catch {
                finish(id) {
                    $0.state = (error as? ExportError)?.message == "Annulé." ? .cancelled : .failed
                    $0.error = error.localizedDescription; $0.outputPath = nil
                }
            }
        }
    }

    private func setProgress(_ id: UUID, _ p: Double) {
        if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .running { jobs[i].progress = p }
    }

    private func finish(_ id: UUID, _ change: (inout ExportJob) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]) }
        transcoders[id] = nil
        save(); pump()
    }

    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { outputDir = u.path }
    }
}
