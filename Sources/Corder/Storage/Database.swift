import Foundation
import GRDB

enum Database {
    static func openShared() throws -> DatabaseQueue {
        try AppPaths.ensureExists()
        return try open(path: AppPaths.databaseURL.path)
    }

    static func open(path: String) throws -> DatabaseQueue {
        let migrator = Migrations.register()

        // A second Corder process (dev build, a copy run from the DMG)
        // can hold the write lock for a moment; wait instead of failing.
        var config = Configuration()
        config.busyMode = .timeout(5)

        // First attempt, the happy path.
        let firstError: Error
        do {
            let dbq = try DatabaseQueue(path: path, configuration: config)
            try migrator.migrate(dbq)
            return dbq
        } catch {
            FileLogger.log("Database.openShared: first open/migrate failed (\(error))")
            firstError = error
        }

        // Only a file SQLite itself calls corrupt or "not a database" is
        // quarantined and recreated. Everything else keeps the user's data
        // and fails visibly: a full disk (SQLITE_FULL on a migration), a busy
        // lock from another process, an I/O error, or a migration bug would
        // all fail the same way on a fresh file, and quarantining would hide
        // the whole Library behind an empty one.
        let corrupt: Bool = {
            guard let dbError = firstError as? DatabaseError else { return false }
            return dbError.resultCode == .SQLITE_CORRUPT || dbError.resultCode == .SQLITE_NOTADB
        }()
        guard corrupt else {
            FileLogger.log("Database.openShared: not a corruption error, NOT recreating (data preserved)")
            throw firstError
        }

        FileLogger.log("Database.openShared: DB is corrupt, quarantining + recreating fresh")
        // If the quarantine move fails (file locked, permissions) the corrupt
        // file stays where it is and we fail; deleting it would lose the only
        // copy a recovery tool could still read.
        try quarantineCorrupt(path: path)
        let dbq = try DatabaseQueue(path: path, configuration: config)
        try migrator.migrate(dbq)
        return dbq
    }

    /// Rename `corder.db` (+ `-wal`/`-shm` sidecars) to a timestamped
    /// `.corrupt-<ts>` backup so a failed open never destroys data.
    private static func quarantineCorrupt(path: String) throws {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let src = path + suffix
            guard fm.fileExists(atPath: src) else { continue }
            try fm.moveItem(atPath: src, toPath: "\(path).corrupt-\(stamp)\(suffix)")
        }
    }
}
