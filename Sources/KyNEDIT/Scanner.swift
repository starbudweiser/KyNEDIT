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

    /// Parcours seul (sans base), pour le banc d'essai.
    static func walkOnly(root: URL, workers: Int = Int(ProcessInfo.processInfo.environment["KYNEDIT_WORKERS"] ?? "") ?? 8) async -> Int {
        var pending = [root.path]; var total = 0
        await withTaskGroup(of: (clips: [Clip], subdirs: [String]).self) { group in
            var running = 0
            while !pending.isEmpty || running > 0 {
                while running < workers, let dir = pending.popLast() { group.addTask { readDirectory(dir) }; running += 1 }
                guard let r = await group.next() else { break }
                running -= 1; pending.append(contentsOf: r.subdirs); total += r.clips.count
            }
        }
        return total
    }

    /// Parcours parallèle (`workers` dossiers lus en même temps), écriture dans le catalogue par lots.
    static func scan(root: URL, catalog: Catalog, scanID: Int, workers: Int = Int(ProcessInfo.processInfo.environment["KYNEDIT_WORKERS"] ?? "") ?? 8,
                     progress: @escaping @Sendable (Int) -> Void) async -> ScanStats {
        var stats = ScanStats()
        var pending = [root.path]
        var batch: [Clip] = []
        await withTaskGroup(of: (clips: [Clip], subdirs: [String]).self) { group in
            var running = 0
            while !pending.isEmpty || running > 0 {
                while running < workers, let dir = pending.popLast() {
                    group.addTask { readDirectory(dir) }
                    running += 1
                }
                guard let result = await group.next() else { break }
                running -= 1
                pending.append(contentsOf: result.subdirs)
                batch.append(contentsOf: result.clips)
                if batch.count >= 2000 {
                    await catalog.upsert(batch, scanID: scanID); stats.total += batch.count; batch.removeAll(keepingCapacity: true)
                    progress(stats.total)
                }
                if Task.isCancelled { group.cancelAll(); pending.removeAll() }
            }
        }
        if !batch.isEmpty { await catalog.upsert(batch, scanID: scanID); stats.total += batch.count; progress(stats.total) }
        if !Task.isCancelled {
            let t = Date(); await catalog.finishScan(root: root.path, scanID: scanID)
            stats.finishSeconds = Date().timeIntervalSince(t)
        }
        return stats
    }
}
