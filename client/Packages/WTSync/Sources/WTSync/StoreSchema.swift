import GRDB

/// The local store's tables (docs/spec/offline.adoc, "Local store").  SQLite integers are signed,
/// so replica ids, seqs and server sequences are stored as the bit pattern of the `UInt64`.
enum StoreSchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("offline-1") { db in
            try db.execute(sql: """
                CREATE TABLE meta (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    document_id TEXT NOT NULL,
                    replica_id INTEGER NOT NULL,
                    hardware_uuid TEXT NOT NULL,
                    last_server_seq INTEGER NOT NULL,
                    next_seq INTEGER NOT NULL,
                    feature_level INTEGER NOT NULL,
                    merge_table_version TEXT NOT NULL
                );
                CREATE TABLE snapshot (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    server_seq INTEGER NOT NULL,
                    raw_size INTEGER NOT NULL,
                    data BLOB NOT NULL,
                    written_at REAL NOT NULL
                );
                CREATE TABLE changes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    replica INTEGER NOT NULL,
                    seq INTEGER NOT NULL,
                    server_seq INTEGER,
                    local INTEGER NOT NULL,
                    sent_at REAL,
                    in_snapshot INTEGER NOT NULL DEFAULT 0,
                    label TEXT NOT NULL,
                    data BLOB NOT NULL
                );
                CREATE UNIQUE INDEX changes_by_replica_seq ON changes(replica, seq);
                CREATE INDEX changes_outbox ON changes(local, server_seq);
                CREATE TABLE undo (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    stack TEXT NOT NULL CHECK (stack IN ('undo', 'redo')),
                    label TEXT NOT NULL,
                    inverse BLOB NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE blobs_pending (
                    hash TEXT PRIMARY KEY,
                    path TEXT NOT NULL,
                    tag TEXT,
                    size INTEGER NOT NULL
                );
                CREATE UNIQUE INDEX blobs_pending_by_tag ON blobs_pending(tag) WHERE tag IS NOT NULL;
                CREATE TABLE view (
                    key TEXT PRIMARY KEY,
                    value BLOB NOT NULL
                );
                """)
        }
        // SYNC-006, SYNC-008, SYNC-010: when the store last synced, a review holding the outbox
        // (the head it measures from, its kind, a salvage report), blob media types, and the
        // changes waiting to be re-issued by salvage.
        migrator.registerMigration("offline-2") { db in
            try db.execute(sql: """
                ALTER TABLE meta ADD COLUMN last_synced_at REAL;
                ALTER TABLE meta ADD COLUMN review_base_seq INTEGER;
                ALTER TABLE meta ADD COLUMN review_kind TEXT;
                ALTER TABLE meta ADD COLUMN salvage_report BLOB;
                ALTER TABLE blobs_pending ADD COLUMN media_type TEXT NOT NULL DEFAULT '';
                CREATE TABLE salvage (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    reason TEXT NOT NULL,
                    data BLOB NOT NULL
                );
                """)
        }
        return migrator
    }
}

extension UInt64 {
    /// The signed bit pattern SQLite stores.
    var sql: Int64 { Int64(bitPattern: self) }

    init(sql: Int64) {
        self.init(bitPattern: sql)
    }
}
