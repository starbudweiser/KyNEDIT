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
    var lutPath: String?
    var state: State = .waiting
    var progress = 0.0
    var error: String?
    var outputPath: String?
    var seconds: Double?      // durée du média écrit
    var elapsed: Double?      // temps de calcul
    // Module « Convertir » : réglages complets, métadonnées de la source, lot (pour le fichier ALE) et sous-dossier relatif.
    var convert: ConvertSettings?
    var meta: SourceMeta?
    var clipName: String?
    var batch: UUID?
    var relDir: String?

    var label: String { convert?.codec.label ?? preset.label }
    var proResClass: Bool { convert?.isProResClass ?? preset.isProRes }
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
    var useLUT = false   // applique le LUT chargé dans le lecteur aux prochains exports
    private var cancellers: [UUID: () -> Void] = [:]

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

    func add(clip: Clip, subclips: [Subclip], lutPath: String? = nil) {
        guard clip.kind == .video else { return }
        if subclips.isEmpty {
            jobs.append(ExportJob(path: clip.path, name: clip.name, preset: preset, outputDir: outputDir, suffix: "", lutPath: lutPath))
        } else {
            for s in subclips {
                jobs.append(ExportJob(path: clip.path, name: "\(clip.name) · \(s.name)", tin: s.tin, tout: s.tout, preset: preset, outputDir: outputDir, suffix: "_" + s.name.replacingOccurrences(of: " ", with: ""), lutPath: lutPath))
            }
        }
        save(); pump()
    }

    func cancel(_ id: UUID) {
        cancellers[id]?()
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
            var running = jobs.filter { $0.state == .running && $0.proResClass == proRes }.count
            while running < slots, let i = jobs.firstIndex(where: { $0.state == .waiting && $0.proResClass == proRes }) {
                start(index: i); running += 1
            }
        }
    }

    private func outputURL(for job: ExportJob) -> URL {
        var dir = URL(fileURLWithPath: job.outputDir, isDirectory: true)
        let base = ((job.path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let c = job.convert {   // renommage par modèle, arborescence recréée, jamais d'écrasement
            if let r = job.relDir, !r.isEmpty { dir = dir.appendingPathComponent(r, isDirectory: true) }
            let stem = Naming.name(template: c.template, clipName: base, meta: job.meta ?? SourceMeta(), settings: c) + job.suffix
            var url = dir.appendingPathComponent("\(stem).\(c.wrap.ext)")
            var n = 2
            let taken = Set(jobs.filter { $0.id != job.id }.compactMap(\.outputPath))
            while FileManager.default.fileExists(atPath: url.path) || taken.contains(url.path) { url = dir.appendingPathComponent("\(stem)_\(n).\(c.wrap.ext)"); n += 1 }
            return url
        }
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
        let out = outputURL(for: job)
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        job.state = .running; job.progress = 0; job.error = nil; job.outputPath = out.path
        jobs[i] = job
        let id = job.id
        let canceller: () -> Void
        let runner: (@escaping @Sendable (Double) -> Void) async throws -> Double
        if let c = job.convert {
            let t = ConvertTranscoder(path: job.path, tin: job.tin, tout: job.tout, settings: c, meta: job.meta ?? SourceMeta(), clipName: job.clipName ?? ((job.path as NSString).lastPathComponent as NSString).deletingPathExtension, output: out)
            canceller = { t.cancel() }; runner = { try await t.run(progress: $0) }
        } else {
            let t = Transcoder(path: job.path, tin: job.tin, tout: job.tout, preset: job.preset, output: out, lutPath: job.lutPath)
            canceller = { t.cancel() }; runner = { try await t.run(progress: $0) }
        }
        cancellers[id] = canceller
        save()
        Task {
            let t0 = Date()
            do {
                let secs = try await runner { p in Task { @MainActor in self.setProgress(id, p) } }
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
        cancellers[id] = nil
        if let b = jobs.first(where: { $0.id == id })?.batch { writeALEIfComplete(b) }
        save(); pump()
    }

    /// Quand toutes les tâches d'un lot « Convertir » sont terminées et que l'ALE est demandé : écrit le fichier Avid Log Exchange.
    private func writeALEIfComplete(_ batch: UUID) {
        let group = jobs.filter { $0.batch == batch }
        guard !group.isEmpty, group.allSatisfy({ $0.state == .done || $0.state == .failed || $0.state == .cancelled }),
              group.first?.convert?.ale == true else { return }
        let done = group.filter { $0.state == .done }
        guard !done.isEmpty else { return }
        let dir = URL(fileURLWithPath: done[0].outputPath!).deletingLastPathComponent()
        let rows = done.map { j in (name: ((j.outputPath! as NSString).lastPathComponent as NSString).deletingPathExtension, reel: j.meta?.reel ?? "", source: (j.path as NSString).lastPathComponent, meta: j.meta ?? SourceMeta(), duration: j.seconds ?? 0) }
        let name = (done[0].path as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? "kYNEDIT"
        try? ALE.write(to: dir.appendingPathComponent("\(name).ale"), rows: rows)
    }

    /// Ajoute des clips à convertir avec les réglages du module « Convertir ».
    func addConvert(clips: [Clip], settings: ConvertSettings, outputDir: String, root: String?, subclips: (Clip) -> [Subclip]) async {
        let batch = UUID()
        var made: [ExportJob] = []
        for clip in clips where clip.kind == .video {
            let meta = await SourceMeta.load(clip)
            var rel: String?
            if settings.recreateFolders, let root, clip.path.hasPrefix(root) {
                rel = ((clip.path as NSString).deletingLastPathComponent as NSString).substring(from: min(root.count, (clip.path as NSString).deletingLastPathComponent.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            let subs = subclips(clip)
            func job(_ name: String, tin: Double?, tout: Double?, suffix: String) -> ExportJob {
                var j = ExportJob(path: clip.path, name: name, tin: tin, tout: tout, preset: .proRes422HQ, outputDir: outputDir, suffix: suffix, lutPath: nil)
                j.convert = settings; j.meta = meta; j.clipName = (clip.name as NSString).deletingPathExtension; j.batch = batch; j.relDir = rel
                return j
            }
            if subs.isEmpty { made.append(job(clip.name, tin: nil, tout: nil, suffix: "")) }
            else { for s in subs { made.append(job("\(clip.name) · \(s.name)", tin: s.tin, tout: s.tout, suffix: "_" + s.name.replacingOccurrences(of: " ", with: ""))) } }
        }
        jobs += made; save(); pump()
    }

    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { outputDir = u.path }
    }
}
