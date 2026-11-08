import Foundation

enum MediaScanner {
    static let video: Set<String> = ["mov", "mp4", "m4v", "mxf", "mkv", "avi", "mts", "m2ts", "mpg", "webm", "braw", "r3d", "ari", "crm"]
    static let audio: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "flac", "aac"]
    static let image: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "dng", "exr", "psd"]

    static func kind(of ext: String) -> MediaKind? {
        if video.contains(ext) { return .video }
        if audio.contains(ext) { return .audio }
        if image.contains(ext) { return .image }
        return nil
    }

    /// Parcourt un dossier (sans suivre les paquets ni les fichiers cachés), écrit par lots de 500 dans le catalogue.
    /// Retourne le nombre de fichiers médias vus ; `progress` est appelé à chaque lot.
    static func scan(root: URL, catalog: Catalog, scanID: Int, progress: @escaping @Sendable (Int) -> Void) async -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var batch: [Clip] = []
        var total = 0
        while let url = en.nextObject() as? URL {
            if Task.isCancelled { break }
            let ext = url.pathExtension.lowercased()
            guard let kind = kind(of: ext),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            batch.append(Clip(path: url.path, name: url.lastPathComponent, ext: ext, size: Int64(v.fileSize ?? 0),
                              mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, kind: kind))
            if batch.count >= 500 {
                await catalog.upsert(batch, scanID: scanID); total += batch.count; batch.removeAll(keepingCapacity: true)
                progress(total)
            }
        }
        if !batch.isEmpty { await catalog.upsert(batch, scanID: scanID); total += batch.count; progress(total) }
        if !Task.isCancelled { await catalog.finishScan(root: root.path, scanID: scanID) }
        return total
    }
}
