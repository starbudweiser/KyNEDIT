import Foundation
import Darwin

struct ScanStats: Sendable { var total = 0; var finishSeconds = 0.0 }

enum MediaScanner {
    static let video: Set<String> = ["mov", "mp4", "m4v", "mxf", "mkv", "avi", "mts", "m2ts", "mpg", "webm", "braw", "r3d", "ari", "crm"]
    static let audio: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "flac", "aac"]
    static let image: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "dng", "exr", "psd"]
    /// Dossiers traités comme des fichiers (paquets) : on n'y descend pas.
    static let packages: Set<String> = ["app", "bundle", "framework", "photoslibrary", "fcpbundle", "xcodeproj", "plugin", "lrdata"]

    static func kind(of ext: String) -> MediaKind? {
        if video.contains(ext) { return .video }
        if audio.contains(ext) { return .audio }
        if image.contains(ext) { return .image }
        return nil
    }

    /// Lit un dossier avec getattrlistbulk : nom, type, date et taille de tous ses éléments en quelques appels système.
    /// Retourne les médias trouvés et les sous-dossiers à parcourir.
    static func readDirectory(_ dir: String) -> (clips: [Clip], subdirs: [String]) {
        let fd = open(dir, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return ([], []) }
        defer { close(fd) }
        var al = attrlist()
        al.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
        al.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }
        var clips: [Clip] = [], subdirs: [String] = []
        while true {
            let n = getattrlistbulk(fd, &al, buf, bufSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if n <= 0 { break }
            var p = buf
            for _ in 0..<Int(n) {
                let length = Int(p.loadUnaligned(as: UInt32.self))
                defer { p += length }
                var o = 4
                let returned = p.loadUnaligned(fromByteOffset: o, as: attribute_set_t.self); o += MemoryLayout<attribute_set_t>.size
                guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { continue }
                let nameRefPos = o
                let nameOff = Int(p.loadUnaligned(fromByteOffset: o, as: Int32.self)); o += MemoryLayout<attrreference_t>.size
                let name = String(cString: (p + nameRefPos + nameOff).assumingMemoryBound(to: CChar.self))
                var objType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { objType = p.loadUnaligned(fromByteOffset: o, as: UInt32.self); o += 4 }
                var mtime = 0.0
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    let ts = p.loadUnaligned(fromByteOffset: o, as: timespec.self); o += MemoryLayout<timespec>.size
                    mtime = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
                }
                var size: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 { size = p.loadUnaligned(fromByteOffset: o, as: Int64.self) }
                if name.hasPrefix(".") { continue }
                let path = dir == "/" ? "/" + name : dir + "/" + name
                if objType == UInt32(VDIR.rawValue) {
                    if !packages.contains((name as NSString).pathExtension.lowercased()) { subdirs.append(path) }
                } else if objType == UInt32(VREG.rawValue) {
                    let ext = (name as NSString).pathExtension.lowercased()
                    if let k = kind(of: ext) { clips.append(Clip(path: path, name: name, ext: ext, size: size, mtime: mtime, kind: k)) }
                }
            }
        }
        return (clips, subdirs)
    }

    static let ioQueue = DispatchQueue(label: "kynedit.scan.io", qos: .userInitiated, attributes: .concurrent)

    /// Résultat du traitement d'un dossier.
    struct DirResult: Sendable { let entry: DirEntry; let subdirs: [String]; let unchanged: Bool }

    /// Date de modification d'un dossier (stat) ; nil s'il est illisible.
    static func dirMTime(_ path: String) -> Double? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    /// Un dossier dont la date n'a pas changé garde ses fichiers : on ne le relit pas, ses sous-dossiers viennent du catalogue.
    static func process(_ dir: String, known: KnownDirs) -> DirResult? {
        guard let mtime = dirMTime(dir) else { return nil }
        if let k = known.info[dir], k.mtime == mtime {
            return DirResult(entry: DirEntry(path: dir, mtime: mtime, count: k.count, clips: nil),
                             subdirs: known.children[dir] ?? [], unchanged: true)
        }
        let r = readDirectory(dir)
        return DirResult(entry: DirEntry(path: dir, mtime: mtime, count: r.clips.count, clips: r.clips), subdirs: r.subdirs, unchanged: false)
    }

    /// Parcours parallèle incrémental (`workers` dossiers traités en même temps), écriture dans le catalogue par lots.
    static func scan(root: URL, catalog: Catalog, scanID: Int,
                     workers: Int? = nil,
                     progress: @escaping @Sendable (Int) -> Void) async -> ScanStats {
        let workers = workers ?? Int(ProcessInfo.processInfo.environment["KYNEDIT_WORKERS"] ?? "") ?? Scheduler.scanWorkers(for: root.path)
        var stats = ScanStats()
        let known = await catalog.knownDirs(root: root.path)
        var pending = [root.path]
        var batch: [DirEntry] = []
        var batchClips = 0, counted = 0, changed = false
        await withTaskGroup(of: DirResult?.self) { group in
            var running = 0
            while !pending.isEmpty || running > 0 {
                while running < workers, let dir = pending.popLast() {
                    group.addTask {
                        // appels système bloquants : file GCD concurrente, pour ne pas bloquer le pool de Swift
                        await withCheckedContinuation { (c: CheckedContinuation<DirResult?, Never>) in
                            ioQueue.async { c.resume(returning: process(dir, known: known)) }
                        }
                    }
                    running += 1
                }
                guard let next = await group.next() else { break }
                running -= 1
                if let r = next {
                    pending.append(contentsOf: r.subdirs)
                    batch.append(r.entry); batchClips += r.entry.clips?.count ?? 0
                    counted += r.entry.count
                    if !r.unchanged { changed = true }
                }
                if batch.count >= 2000 || batchClips >= 2000 {
                    await catalog.commit(batch, scanID: scanID); batch.removeAll(keepingCapacity: true); batchClips = 0
                    progress(counted)
                }
                if Task.isCancelled { group.cancelAll(); pending.removeAll() }
            }
        }
        if !batch.isEmpty { await catalog.commit(batch, scanID: scanID); progress(counted) }
        if !Task.isCancelled {
            let t = Date(); stats.total = await catalog.finishScan(root: root.path, scanID: scanID, changed: changed)
            stats.finishSeconds = Date().timeIntervalSince(t)
        }
        return stats
    }
}
