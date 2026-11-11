import XCTest
@testable import CompanionCore

final class PersistenceTests: XCTestCase {
    func testMigrationCreatesSchemaAndIsIdempotent() throws {
        let db = try SQLiteDatabase.inMemory()
        try Migrator.migrate(db)
        XCTAssertEqual(db.userVersion, Schema.currentVersion)
        try Migrator.migrate(db)
        XCTAssertEqual(db.userVersion, Schema.currentVersion)
        XCTAssertNoThrow(try db.query("SELECT * FROM projects"))
    }

    func testOlderExecutableRefusesNewerDatabase() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.setUserVersion(Schema.currentVersion + 1)
        XCTAssertThrowsError(try Migrator.migrate(db)) { error in
            XCTAssertEqual(error as? CompanionError, .incompatibleDatabase(found: Schema.currentVersion + 1, supported: Schema.currentVersion))
        }
    }

    func testTransactionRollsBackOnError() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.execute("CREATE TABLE t (x INTEGER)")
        XCTAssertThrowsError(try db.transaction {
            try db.execute("INSERT INTO t VALUES (1)")
            throw CompanionError.cancelled
        })
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM t"), 0)
        try db.transaction {
            try db.execute("INSERT INTO t VALUES (1)")
            try? db.transaction { try db.execute("INSERT INTO t VALUES (2)"); throw CompanionError.cancelled }
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM t"), 1, "nested savepoint rolls back only inner work")
    }

    func testFileDatabaseBackup() throws {
        let tmp = TempDir()
        let db = try SQLiteDatabase(path: tmp.url.appendingPathComponent("a.sqlite").path)
        try Migrator.migrate(db)
        try db.execute("INSERT INTO settings(key, value) VALUES('k','v')")
        let backup = tmp.url.appendingPathComponent("b.sqlite")
        try db.backup(to: backup)
        let copy = try SQLiteDatabase(path: backup.path)
        XCTAssertEqual(try copy.queryOne("SELECT value FROM settings WHERE key='k'")?.string("value"), "v")
    }

    func testSettingsDefaultsAreSafe() throws {
        let db = try SQLiteDatabase.inMemory(); try Migrator.migrate(db)
        let s = SettingsStore(db: db)
        XCTAssertEqual(s.get(Settings.safetyMode), .observeAndSuggest)
        XCTAssertFalse(s.get(Settings.launchAtLogin))
        XCTAssertFalse(s.get(Settings.notificationsEnabled))
        XCTAssertEqual(s.get(Settings.avatarSize), 56)
        XCTAssertEqual(s.get(Settings.maxOperationsPerApproval), 20)
        XCTAssertEqual(s.get(Settings.approvalTTLSeconds), 60)
        XCTAssertEqual(s.get(Settings.monthlyBudgetUSD), 10)
        s.set(Settings.avatarSize, 72)
        XCTAssertEqual(s.get(Settings.avatarSize), 72)
    }

    func testContentCipherRoundTripAndKeyPersistence() throws {
        let secrets = InMemorySecretStore()
        let a = try ContentCipher(secrets: secrets)
        let sealed = try a.sealString("private excerpt")
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("private"))
        let b = try ContentCipher(secrets: secrets)
        XCTAssertEqual(try b.openString(sealed), "private excerpt")
    }

    func testRedactorRemovesSecrets() {
        let text = "key sk-ant-abcdefghijklmnop token ya29.a0AfH6SMB refresh 1//0gABCDEFGHIJKLMN Bearer abc.def access_token=xyz&x=1"
        let r = Redactor.redact(text)
        XCTAssertFalse(r.contains("abcdefghijklmnop"))
        XCTAssertFalse(r.contains("ya29.a0"))
        XCTAssertFalse(r.contains("1//0gABC"))
        XCTAssertFalse(r.contains("abc.def"))
        XCTAssertFalse(r.contains("xyz"))
    }

    func testSingleInstanceLock() {
        let tmp = TempDir()
        let url = tmp.url.appendingPathComponent("lock")
        let a = SingleInstanceLock()
        XCTAssertTrue(a.acquire(at: url))
        let b = SingleInstanceLock()
        XCTAssertFalse(b.acquire(at: url))
    }
}
