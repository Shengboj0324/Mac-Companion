import Foundation

/// Versioned schema migrations. Each step is applied in a transaction; the
/// database is backed up before any migration, and an executable refuses a
/// database newer than it understands (spec §18 "Updates, migrations").
public enum Schema {
    public static let currentVersion = 1

    public static let migrations: [Int: String] = [
        1: v1,
    ]

    static let v1 = """
    CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        default_provider TEXT,
        disclosure TEXT NOT NULL DEFAULT 'askBeforeSending',
        allowed_providers TEXT NOT NULL DEFAULT '[]',
        notes TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL,
        last_opened_at REAL,
        snoozed_until REAL
    );

    CREATE TABLE roots (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        bookmark BLOB,
        extract_content INTEGER NOT NULL DEFAULT 1,
        disclosure TEXT NOT NULL DEFAULT 'askBeforeSending',
        allowed_providers TEXT NOT NULL DEFAULT '[]',
        protected INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        added_at REAL NOT NULL,
        last_scan_at REAL
    );

    CREATE TABLE file_assets (
        id TEXT PRIMARY KEY,
        root_id TEXT REFERENCES roots(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        name TEXT NOT NULL,
        ext TEXT NOT NULL DEFAULT '',
        uti TEXT,
        size INTEGER NOT NULL DEFAULT 0,
        modified_at REAL,
        resource_identity TEXT,
        bookmark BLOB,
        content_hash TEXT,
        availability TEXT NOT NULL DEFAULT 'available',
        index_status TEXT NOT NULL DEFAULT 'pending',
        index_detail TEXT,
        is_managed_copy INTEGER NOT NULL DEFAULT 0,
        tags TEXT NOT NULL DEFAULT '[]',
        first_seen_at REAL NOT NULL,
        last_seen_at REAL NOT NULL,
        last_indexed_at REAL
    );
    CREATE UNIQUE INDEX file_assets_path ON file_assets(path);
    CREATE INDEX file_assets_identity ON file_assets(resource_identity);

    CREATE TABLE file_versions (
        id TEXT PRIMARY KEY,
        asset_id TEXT NOT NULL REFERENCES file_assets(id) ON DELETE CASCADE,
        content_hash TEXT NOT NULL,
        observed_at REAL NOT NULL,
        extraction_version INTEGER NOT NULL,
        snapshot_path TEXT
    );

    CREATE TABLE working_copies (
        id TEXT PRIMARY KEY,
        project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
        source_asset_id TEXT,
        source_path TEXT NOT NULL,
        base_hash TEXT NOT NULL,
        copy_path TEXT NOT NULL,
        copy_hash TEXT NOT NULL,
        created_at REAL NOT NULL,
        state TEXT NOT NULL DEFAULT 'current',
        rule_id TEXT
    );

    CREATE TABLE copy_rules (
        id TEXT PRIMARY KEY,
        root_id TEXT NOT NULL,
        pattern TEXT NOT NULL,
        destination TEXT NOT NULL,
        max_files INTEGER NOT NULL,
        max_bytes INTEGER NOT NULL,
        copied_files INTEGER NOT NULL DEFAULT 0,
        copied_bytes INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 0,
        expires_at REAL,
        created_at REAL NOT NULL
    );

    CREATE TABLE project_items (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        target_id TEXT NOT NULL,
        mode TEXT NOT NULL DEFAULT 'reference',
        reason TEXT,
        confirmed INTEGER NOT NULL DEFAULT 1,
        added_at REAL NOT NULL,
        UNIQUE(project_id, kind, target_id)
    );

    CREATE TABLE checkpoints (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        note TEXT NOT NULL,
        next_step TEXT,
        source_refs TEXT NOT NULL DEFAULT '[]',
        created_at REAL NOT NULL
    );

    CREATE TABLE calendar_items (
        id TEXT PRIMARY KEY,
        event_identifier TEXT,
        external_identifier TEXT,
        calendar_id TEXT NOT NULL,
        calendar_title TEXT NOT NULL,
        title TEXT NOT NULL,
        notes TEXT,
        location TEXT,
        start_at REAL NOT NULL,
        end_at REAL NOT NULL,
        is_all_day INTEGER NOT NULL DEFAULT 0,
        time_zone TEXT,
        is_recurring INTEGER NOT NULL DEFAULT 0,
        occurrence_date REAL,
        last_modified REAL,
        refreshed_at REAL NOT NULL,
        created_by_app INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX calendar_items_start ON calendar_items(start_at);

    CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
        title TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'open',
        deadline REAL,
        deadline_confirmed INTEGER NOT NULL DEFAULT 0,
        deadline_evidence TEXT,
        event_id TEXT,
        created_at REAL NOT NULL
    );

    CREATE TABLE requirements (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
        text TEXT NOT NULL,
        status TEXT NOT NULL,
        evidence TEXT NOT NULL,
        evidence_locator TEXT,
        confirmation TEXT NOT NULL DEFAULT 'unconfirmed',
        done INTEGER NOT NULL DEFAULT 0,
        ordinal INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE memories (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        kind TEXT NOT NULL,
        statement TEXT NOT NULL,
        provenance TEXT NOT NULL,
        source_ref TEXT,
        observed_at REAL NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
        sensitivity TEXT NOT NULL DEFAULT 'normal',
        allowed_providers TEXT NOT NULL DEFAULT '[]',
        supersedes TEXT,
        expires_at REAL
    );
    CREATE TABLE memory_tombstones (
        fingerprint TEXT PRIMARY KEY,
        forgotten_at REAL NOT NULL
    );

    CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        title TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        summary TEXT
    );
    CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        provider TEXT,
        model TEXT,
        source_refs TEXT NOT NULL DEFAULT '[]',
        adapter_state TEXT,
        created_at REAL NOT NULL
    );

    CREATE TABLE action_runs (
        id TEXT PRIMARY KEY,
        plan_hash TEXT NOT NULL,
        plan TEXT NOT NULL,
        summary TEXT NOT NULL,
        initiator TEXT NOT NULL,
        state TEXT NOT NULL,
        policy_decision TEXT,
        results TEXT NOT NULL DEFAULT '[]',
        error TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE approval_grants (
        id TEXT PRIMARY KEY,
        plan_hash TEXT NOT NULL,
        issued_at REAL NOT NULL,
        expires_at REAL NOT NULL,
        used INTEGER NOT NULL DEFAULT 0,
        policy_version INTEGER NOT NULL
    );

    CREATE TABLE recovery_records (
        id TEXT PRIMARY KEY,
        action_id TEXT NOT NULL,
        operation_index INTEGER NOT NULL,
        kind TEXT NOT NULL,
        before_path TEXT,
        snapshot_path TEXT,
        before_hash TEXT,
        cloud_payload BLOB,
        coverage TEXT,
        created_at REAL NOT NULL,
        restore_state TEXT NOT NULL DEFAULT 'available'
    );

    CREATE TABLE usage_entries (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        request_id TEXT,
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        price_version TEXT NOT NULL,
        estimated_cost REAL NOT NULL,
        is_estimate INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL
    );

    CREATE TABLE budget_reservations (
        id TEXT PRIMARY KEY,
        amount REAL NOT NULL,
        created_at REAL NOT NULL
    );

    CREATE TABLE connector_accounts (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        subject TEXT NOT NULL,
        display_identity TEXT NOT NULL,
        scopes TEXT NOT NULL,
        keychain_ref TEXT NOT NULL,
        status TEXT NOT NULL,
        last_refresh REAL,
        created_at REAL NOT NULL,
        UNIQUE(provider, subject)
    );

    CREATE TABLE cloud_assets (
        id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL REFERENCES connector_accounts(id) ON DELETE CASCADE,
        provider_file_id TEXT NOT NULL,
        name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        canonical_url TEXT,
        parents TEXT NOT NULL DEFAULT '[]',
        capabilities TEXT NOT NULL DEFAULT '{}',
        version TEXT,
        revision_id TEXT,
        modified_time REAL,
        retrieved_at REAL,
        freshness TEXT NOT NULL DEFAULT 'unknown',
        coverage TEXT,
        disclosure TEXT NOT NULL DEFAULT 'askBeforeSending',
        allowed_providers TEXT NOT NULL DEFAULT '[]',
        UNIQUE(account_id, provider_file_id)
    );

    CREATE TABLE document_segments (
        id TEXT PRIMARY KEY,
        asset_id TEXT NOT NULL,
        source_kind TEXT NOT NULL,
        tab_id TEXT,
        source_version TEXT,
        heading TEXT,
        start_index INTEGER,
        end_index INTEGER,
        ordinal INTEGER NOT NULL,
        content BLOB NOT NULL,
        encrypted INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX document_segments_asset ON document_segments(asset_id);

    CREATE TABLE organization_rules (
        id TEXT PRIMARY KEY,
        scope TEXT NOT NULL,
        field TEXT NOT NULL,
        statement TEXT NOT NULL,
        status TEXT NOT NULL,
        evidence TEXT NOT NULL DEFAULT '[]',
        observation_count INTEGER NOT NULL DEFAULT 0,
        exceptions TEXT NOT NULL DEFAULT '[]',
        confirmed_at REAL,
        superseded_by TEXT,
        created_at REAL NOT NULL
    );

    CREATE TABLE placement_feedback (
        id TEXT PRIMARY KEY,
        file_path TEXT NOT NULL,
        suggested TEXT NOT NULL,
        outcome TEXT NOT NULL,
        chosen TEXT,
        created_at REAL NOT NULL
    );

    CREATE TABLE sync_cursors (
        account_id TEXT PRIMARY KEY,
        cursor TEXT NOT NULL,
        last_success REAL,
        status TEXT NOT NULL DEFAULT 'ok',
        failures INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE activity (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        initiator TEXT NOT NULL,
        summary TEXT NOT NULL,
        detail TEXT,
        action_id TEXT,
        created_at REAL NOT NULL
    );
    CREATE INDEX activity_created ON activity(created_at);

    CREATE TABLE notifications_log (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        kind TEXT NOT NULL,
        sent_at REAL NOT NULL
    );

    -- Search: a contentless FTS5 index (stores tokens, not readable text) plus a
    -- row map. Extracted text itself lives AES-GCM encrypted in document_segments.
    CREATE TABLE search_docs (
        rowid INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        segment_id TEXT,
        title TEXT NOT NULL
    );
    CREATE INDEX search_docs_item ON search_docs(item_id);
    CREATE VIRTUAL TABLE search_index USING fts5(
        title,
        body,
        content = '',
        contentless_delete = 1,
        tokenize = 'porter unicode61 remove_diacritics 2'
    );
    """
}

public enum Migrator {
    /// Applies pending migrations. Backs up a file-backed database first and
    /// refuses databases created by a newer schema.
    public static func migrate(_ db: SQLiteDatabase, backupDirectory: URL? = nil, now: Date = Date()) throws {
        let current = db.userVersion
        if current > Schema.currentVersion {
            throw CompanionError.incompatibleDatabase(found: current, supported: Schema.currentVersion)
        }
        guard current < Schema.currentVersion else { return }
        if current > 0, let dir = backupDirectory, db.path != ":memory:" {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Int(now.timeIntervalSince1970)
            try db.backup(to: dir.appendingPathComponent("pre-migration-v\(current)-\(stamp).sqlite"))
        }
        for version in (current + 1)...Schema.currentVersion {
            guard let sql = Schema.migrations[version] else {
                throw CompanionError.database("Missing migration \(version)")
            }
            try db.transaction {
                try db.execute(sql)
                try db.setUserVersion(version)
            }
        }
        // Validate before normal operation.
        let check = try db.query("PRAGMA integrity_check")
        guard check.first?.string("integrity_check") == "ok" else {
            throw CompanionError.database("Integrity check failed after migration")
        }
    }
}
