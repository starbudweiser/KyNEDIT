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
            "CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(name, content='files', content_rowid='rowid', tokenize='unicode61')",
        ] { sqlite3_exec(handle, sql, nil, nil, nil) }
    }


    /// Insère ou met à jour un lot de fichiers dans une seule transaction.
    func upsert(_ clips: [Clip], scanID: Int) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO files(path,name,folder,ext,size,mtime,kind,seen) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, seen=excluded.seen
            """, -1, &st, nil)
        for c in clips {
            sqlite3_reset(st)
            sqlite3_bind_text(st, 1, c.path, -1, transient)
            sqlite3_bind_text(st, 2, c.name, -1, transient)
            sqlite3_bind_text(st, 3, (c.path as NSString).deletingLastPathComponent, -1, transient)
            sqlite3_bind_text(st, 4, c.ext, -1, transient)
            sqlite3_bind_int64(st, 5, c.size)
            sqlite3_bind_double(st, 6, c.mtime)
            sqlite3_bind_int(st, 7, Int32(c.kind.rawValue))
            sqlite3_bind_int(st, 8, Int32(scanID))
            sqlite3_step(st)
        }
        sqlite3_finalize(st)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Fin d'analyse : retire les fichiers du dossier qui n'ont pas été revus (supprimés ou déplacés) et réindexe la recherche.
    func finishScan(root: String, scanID: Int) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM files WHERE (folder=? OR folder LIKE ? ESCAPE '\\') AND seen<>?", -1, &st, nil)
        sqlite3_bind_text(st, 1, root, -1, transient)
        let escaped = root.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        sqlite3_bind_text(st, 2, escaped + "/%", -1, transient)
        sqlite3_bind_int(st, 3, Int32(scanID))
        sqlite3_step(st); sqlite3_finalize(st)
        sqlite3_exec(db, "INSERT INTO files_fts(files_fts) VALUES('rebuild')", nil, nil, nil)
    }

    /// Fichiers sous un dossier (récursif), filtrés par recherche plein texte (préfixes) si `query` n'est pas vide.
    func list(root: String, query: String, limit: Int = 50_000) -> [Clip] {
        var sql = "SELECT f.path,f.name,f.ext,f.size,f.mtime,f.kind FROM files f"
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
        if !terms.isEmpty { sql += " JOIN files_fts ON files_fts.rowid=f.rowid AND files_fts MATCH ?" }
        sql += " WHERE (f.folder=? OR f.folder LIKE ? ESCAPE '\\') ORDER BY f.name COLLATE NOCASE LIMIT ?"
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        var i: Int32 = 1
        if !terms.isEmpty { sqlite3_bind_text(st, i, terms.joined(separator: " "), -1, transient); i += 1 }
        sqlite3_bind_text(st, i, root, -1, transient); i += 1
        let escaped = root.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        sqlite3_bind_text(st, i, escaped + "/%", -1, transient); i += 1
        sqlite3_bind_int(st, i, Int32(limit))
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
