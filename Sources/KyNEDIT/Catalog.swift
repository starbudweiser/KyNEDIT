import Foundation
import SQLite3

enum MediaKind: Int, Sendable { case video = 0, audio, image }

struct Clip: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let ext: String
    let size: Int64
    let mtime: Double
    let kind: MediaKind
    /// Formats RAW de caméra : leur décodage demande le SDK du fabricant (BRAW, R3D, ARRIRAW, Canon RAW).
    var isRaw: Bool { ["braw", "r3d", "ari", "arx", "crm"].contains(ext) }
}

struct KnownDirs: Sendable {
    var info: [String: (mtime: Double, count: Int)] = [:]
    var children: [String: [String]] = [:]
}

/// Métadonnées de l'utilisateur sur un clip : note 0–5, étiquette de couleur (0 aucune, 1 validé, 2 à revoir, 3 rejeté), commentaire, mots-clés.
struct ClipMeta: Sendable, Equatable { var rating = 0; var color = 0; var note = ""; var tags: [String] = [] }

struct Marker: Identifiable, Sendable, Hashable { let id: Int64; var time: Double; var label: String }
struct Subclip: Identifiable, Sendable, Hashable { let id: Int64; var tin: Double; var tout: Double; var name: String }

struct DirEntry: Sendable {
    let path: String
    let mtime: Double
    let count: Int
    let clips: [Clip]?
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Catalogue SQLite (WAL) + index plein texte FTS5. Isolé dans un acteur : une seule connexion, accès sérialisé.
actor Catalog {
    private var db: OpaquePointer?

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kYNEDIT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.sqlite")
    }

    init(url: URL = Catalog.defaultURL()) {
        var handle: OpaquePointer?
        sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        db = handle
        for sql in [
            "PRAGMA journal_mode=WAL", "PRAGMA synchronous=NORMAL",
            """
            CREATE TABLE IF NOT EXISTS files(
              path TEXT PRIMARY KEY, name TEXT NOT NULL, folder TEXT NOT NULL, ext TEXT NOT NULL,
              size INTEGER NOT NULL, mtime REAL NOT NULL, kind INTEGER NOT NULL, seen INTEGER NOT NULL DEFAULT 0)
            """,
            "CREATE INDEX IF NOT EXISTS files_folder ON files(folder)",
            "CREATE TABLE IF NOT EXISTS dirs(path TEXT PRIMARY KEY, parent TEXT NOT NULL, mtime REAL NOT NULL, count INTEGER NOT NULL, seen INTEGER NOT NULL)",
            "CREATE INDEX IF NOT EXISTS dirs_parent ON dirs(parent)",
            "CREATE TABLE IF NOT EXISTS markers(id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL, time REAL NOT NULL, label TEXT NOT NULL DEFAULT '')",
            "CREATE INDEX IF NOT EXISTS markers_path ON markers(path)",
            "CREATE TABLE IF NOT EXISTS subclips(id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL, tin REAL NOT NULL, tout REAL NOT NULL, name TEXT NOT NULL DEFAULT '')",
            "CREATE INDEX IF NOT EXISTS subclips_path ON subclips(path)",
            "CREATE TABLE IF NOT EXISTS meta(path TEXT PRIMARY KEY, rating INTEGER NOT NULL DEFAULT 0, color INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '')",
            "CREATE TABLE IF NOT EXISTS tags(path TEXT NOT NULL, tag TEXT NOT NULL, PRIMARY KEY(path, tag))",
            "CREATE INDEX IF NOT EXISTS tags_tag ON tags(tag)",
            "CREATE TABLE IF NOT EXISTS probe(path TEXT PRIMARY KEY, mtime REAL NOT NULL, duration REAL, width INTEGER, height INTEGER, fps REAL, codec TEXT)",
            "CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(name, content='files', content_rowid='rowid', tokenize='unicode61')",
        ] { sqlite3_exec(handle, sql, nil, nil, nil) }
    }


    private static func likePattern(_ root: String) -> String {
        root.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "/%"
    }

    /// Dossiers connus sous `root` : date, nombre de médias et enfants, pour ignorer ceux qui n'ont pas changé.
    func knownDirs(root: String) -> KnownDirs {
        var known = KnownDirs()
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT path,parent,mtime,count FROM dirs WHERE path=? OR path LIKE ? ESCAPE '\\'", -1, &st, nil)
        sqlite3_bind_text(st, 1, root, -1, transient)
        sqlite3_bind_text(st, 2, Catalog.likePattern(root), -1, transient)
        while sqlite3_step(st) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(st, 0)), parent = String(cString: sqlite3_column_text(st, 1))
            known.info[path] = (sqlite3_column_double(st, 2), Int(sqlite3_column_int(st, 3)))
            known.children[parent, default: []].append(path)
        }
        sqlite3_finalize(st)
        return known
    }

    /// Enregistre un lot de dossiers visités. Un dossier relu (`clips` non nil) voit ses fichiers remplacés ;
    /// un dossier inchangé (`clips` nil) est seulement marqué comme revu.
    func commit(_ entries: [DirEntry], scanID: Int) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var dirSt: OpaquePointer?, delSt: OpaquePointer?, fileSt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO dirs(path,parent,mtime,count,seen) VALUES(?,?,?,?,?)", -1, &dirSt, nil)
        sqlite3_prepare_v2(db, "DELETE FROM files WHERE folder=?", -1, &delSt, nil)
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO files(path,name,folder,ext,size,mtime,kind,seen) VALUES(?,?,?,?,?,?,?,0)", -1, &fileSt, nil)
        for e in entries {
            sqlite3_reset(dirSt)
            sqlite3_bind_text(dirSt, 1, e.path, -1, transient)
            sqlite3_bind_text(dirSt, 2, (e.path as NSString).deletingLastPathComponent, -1, transient)
            sqlite3_bind_double(dirSt, 3, e.mtime)
            sqlite3_bind_int(dirSt, 4, Int32(e.count))
            sqlite3_bind_int(dirSt, 5, Int32(scanID))
            sqlite3_step(dirSt)
            guard let clips = e.clips else { continue }
            sqlite3_reset(delSt); sqlite3_bind_text(delSt, 1, e.path, -1, transient); sqlite3_step(delSt)
            for c in clips {
                sqlite3_reset(fileSt)
                sqlite3_bind_text(fileSt, 1, c.path, -1, transient)
                sqlite3_bind_text(fileSt, 2, c.name, -1, transient)
                sqlite3_bind_text(fileSt, 3, e.path, -1, transient)
                sqlite3_bind_text(fileSt, 4, c.ext, -1, transient)
                sqlite3_bind_int64(fileSt, 5, c.size)
                sqlite3_bind_double(fileSt, 6, c.mtime)
                sqlite3_bind_int(fileSt, 7, Int32(c.kind.rawValue))
                sqlite3_step(fileSt)
            }
        }
        sqlite3_finalize(dirSt); sqlite3_finalize(delSt); sqlite3_finalize(fileSt)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Fin d'analyse : retire les dossiers non revus (supprimés ou déplacés) et leurs fichiers, réindexe la recherche
    /// (seulement si quelque chose a changé). Retourne le nombre de médias sous `root`.
    func finishScan(root: String, scanID: Int, changed: Bool) -> Int {
        let like = Catalog.likePattern(root)
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM files WHERE (folder=?1 OR folder LIKE ?2 ESCAPE '\\') AND folder NOT IN (SELECT path FROM dirs WHERE seen=?3)", -1, &st, nil)
        sqlite3_bind_text(st, 1, root, -1, transient); sqlite3_bind_text(st, 2, like, -1, transient); sqlite3_bind_int(st, 3, Int32(scanID))
        sqlite3_step(st); let removed = sqlite3_changes(db); sqlite3_finalize(st)
        sqlite3_prepare_v2(db, "DELETE FROM dirs WHERE (path=?1 OR path LIKE ?2 ESCAPE '\\') AND seen<>?3", -1, &st, nil)
        sqlite3_bind_text(st, 1, root, -1, transient); sqlite3_bind_text(st, 2, like, -1, transient); sqlite3_bind_int(st, 3, Int32(scanID))
        sqlite3_step(st); sqlite3_finalize(st)
        if changed || removed > 0 { sqlite3_exec(db, "INSERT INTO files_fts(files_fts) VALUES('rebuild')", nil, nil, nil) }
        sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(count),0) FROM dirs WHERE path=?1 OR path LIKE ?2 ESCAPE '\\'", -1, &st, nil)
        sqlite3_bind_text(st, 1, root, -1, transient); sqlite3_bind_text(st, 2, like, -1, transient)
        var total = 0
        if sqlite3_step(st) == SQLITE_ROW { total = Int(sqlite3_column_int64(st, 0)) }
        sqlite3_finalize(st)
        return total
    }

    /// En-têtes déjà lus pour ce fichier (valables tant que sa date n'a pas changé).
    func info(path: String, mtime: Double) -> MediaInfo? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT duration,width,height,fps,codec FROM probe WHERE path=? AND mtime=?", -1, &st, nil)
        sqlite3_bind_text(st, 1, path, -1, transient); sqlite3_bind_double(st, 2, mtime)
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        return MediaInfo(duration: sqlite3_column_double(st, 0), width: Int(sqlite3_column_int(st, 1)), height: Int(sqlite3_column_int(st, 2)),
                         fps: sqlite3_column_double(st, 3), codec: sqlite3_column_text(st, 4).map { String(cString: $0) } ?? "")
    }

    func saveInfo(_ i: MediaInfo, path: String, mtime: Double) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO probe(path,mtime,duration,width,height,fps,codec) VALUES(?,?,?,?,?,?,?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, path, -1, transient); sqlite3_bind_double(st, 2, mtime)
        sqlite3_bind_double(st, 3, i.duration); sqlite3_bind_int(st, 4, Int32(i.width)); sqlite3_bind_int(st, 5, Int32(i.height))
        sqlite3_bind_double(st, 6, i.fps); sqlite3_bind_text(st, 7, i.codec, -1, transient)
        sqlite3_step(st); sqlite3_finalize(st)
    }

    func markers(path: String) -> [Marker] {
        var st: OpaquePointer?; var out: [Marker] = []
        sqlite3_prepare_v2(db, "SELECT id,time,label FROM markers WHERE path=? ORDER BY time", -1, &st, nil)
        sqlite3_bind_text(st, 1, path, -1, transient)
        while sqlite3_step(st) == SQLITE_ROW { out.append(Marker(id: sqlite3_column_int64(st, 0), time: sqlite3_column_double(st, 1), label: String(cString: sqlite3_column_text(st, 2)))) }
        sqlite3_finalize(st); return out
    }

    func addMarker(path: String, time: Double, label: String) -> Marker {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO markers(path,time,label) VALUES(?,?,?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, path, -1, transient); sqlite3_bind_double(st, 2, time); sqlite3_bind_text(st, 3, label, -1, transient)
        sqlite3_step(st); sqlite3_finalize(st)
        return Marker(id: sqlite3_last_insert_rowid(db), time: time, label: label)
    }

    func deleteMarker(id: Int64) { sqlite3_exec(db, "DELETE FROM markers WHERE id=\(id)", nil, nil, nil) }

    func subclips(path: String) -> [Subclip] {
        var st: OpaquePointer?; var out: [Subclip] = []
        sqlite3_prepare_v2(db, "SELECT id,tin,tout,name FROM subclips WHERE path=? ORDER BY tin", -1, &st, nil)
        sqlite3_bind_text(st, 1, path, -1, transient)
        while sqlite3_step(st) == SQLITE_ROW { out.append(Subclip(id: sqlite3_column_int64(st, 0), tin: sqlite3_column_double(st, 1), tout: sqlite3_column_double(st, 2), name: String(cString: sqlite3_column_text(st, 3)))) }
        sqlite3_finalize(st); return out
    }

    func addSubclip(path: String, tin: Double, tout: Double, name: String) -> Subclip {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO subclips(path,tin,tout,name) VALUES(?,?,?,?)", -1, &st, nil)
        sqlite3_bind_text(st, 1, path, -1, transient); sqlite3_bind_double(st, 2, tin); sqlite3_bind_double(st, 3, tout); sqlite3_bind_text(st, 4, name, -1, transient)
        sqlite3_step(st); sqlite3_finalize(st)
        return Subclip(id: sqlite3_last_insert_rowid(db), tin: tin, tout: tout, name: name)
    }

    func deleteSubclip(id: Int64) { sqlite3_exec(db, "DELETE FROM subclips WHERE id=\(id)", nil, nil, nil) }

    // MARK: métadonnées
    /// Toutes les métadonnées des clips sous `root` (seuls les clips annotés ont une ligne).
    func allMeta(root: String) -> [String: ClipMeta] {
        var out: [String: ClipMeta] = [:]
        let like = Catalog.likePattern(root).replacingOccurrences(of: "/%", with: "/%")
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT path,rating,color,note FROM meta WHERE path LIKE ? ESCAPE '\\'", -1, &st, nil)
        sqlite3_bind_text(st, 1, like, -1, transient)
        while sqlite3_step(st) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(st, 0))] = ClipMeta(rating: Int(sqlite3_column_int(st, 1)), color: Int(sqlite3_column_int(st, 2)), note: String(cString: sqlite3_column_text(st, 3)))
        }
        sqlite3_finalize(st)
        sqlite3_prepare_v2(db, "SELECT path,tag FROM tags WHERE path LIKE ? ESCAPE '\\' ORDER BY tag", -1, &st, nil)
        sqlite3_bind_text(st, 1, like, -1, transient)
        while sqlite3_step(st) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(st, 0)), default: ClipMeta()].tags.append(String(cString: sqlite3_column_text(st, 1)))
        }
        sqlite3_finalize(st)
        return out
    }

    func saveMeta(path: String, rating: Int, color: Int, note: String) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO meta(path,rating,color,note) VALUES(?,?,?,?) ON CONFLICT(path) DO UPDATE SET rating=excluded.rating, color=excluded.color, note=excluded.note", -1, &st, nil)
        sqlite3_bind_text(st, 1, path, -1, transient); sqlite3_bind_int(st, 2, Int32(rating)); sqlite3_bind_int(st, 3, Int32(color)); sqlite3_bind_text(st, 4, note, -1, transient)
        sqlite3_step(st); sqlite3_finalize(st)
    }

    func setTags(path: String, tags: [String]) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM tags WHERE path=?", -1, &st, nil)
        sqlite3_bind_text(st, 1, path, -1, transient); sqlite3_step(st); sqlite3_finalize(st)
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO tags(path,tag) VALUES(?,?)", -1, &st, nil)
        for t in tags { sqlite3_reset(st); sqlite3_bind_text(st, 1, path, -1, transient); sqlite3_bind_text(st, 2, t, -1, transient); sqlite3_step(st) }
        sqlite3_finalize(st)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Fichiers sous un dossier (récursif), filtrés par recherche plein texte (préfixes) si `query` n'est pas vide.
    func list(root: String, query: String, ratingMin: Int = 0, color: Int = 0, limit: Int = 50_000) -> [Clip] {
        enum Bind { case text(String), int(Int) }
        var conds = ["(f.folder=? OR f.folder LIKE ? ESCAPE '\\')"]
        var binds: [Bind] = [.text(root), .text(Catalog.likePattern(root))]
        let q = query.trimmingCharacters(in: .whitespaces)
        let terms = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
        if !terms.isEmpty {
            // le nom (recherche plein texte par préfixes), un mot-clé ou le commentaire
            conds.append("(f.rowid IN (SELECT rowid FROM files_fts WHERE files_fts MATCH ?) OR f.path IN (SELECT path FROM tags WHERE tag LIKE ?) OR f.path IN (SELECT path FROM meta WHERE note LIKE ?))")
            binds += [.text(terms.joined(separator: " ")), .text("%" + q + "%"), .text("%" + q + "%")]
        }
        if ratingMin > 0 { conds.append("f.path IN (SELECT path FROM meta WHERE rating>=?)"); binds.append(.int(ratingMin)) }
        if color > 0 { conds.append("f.path IN (SELECT path FROM meta WHERE color=?)"); binds.append(.int(color)) }
        let sql = "SELECT f.path,f.name,f.ext,f.size,f.mtime,f.kind FROM files f WHERE " + conds.joined(separator: " AND ") + " ORDER BY f.name COLLATE NOCASE LIMIT ?"
        binds.append(.int(limit))
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        for (i, b) in binds.enumerated() {
            switch b { case .text(let t): sqlite3_bind_text(st, Int32(i + 1), t, -1, transient); case .int(let n): sqlite3_bind_int(st, Int32(i + 1), Int32(n)) }
        }
        var out: [Clip] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(Clip(path: String(cString: sqlite3_column_text(st, 0)), name: String(cString: sqlite3_column_text(st, 1)),
                            ext: String(cString: sqlite3_column_text(st, 2)), size: sqlite3_column_int64(st, 3),
                            mtime: sqlite3_column_double(st, 4), kind: MediaKind(rawValue: Int(sqlite3_column_int(st, 5))) ?? .video))
        }
        sqlite3_finalize(st)
        return out
    }
}
