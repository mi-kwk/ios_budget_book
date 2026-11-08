import Foundation

protocol BudgetRepository {
    func load() throws -> BudgetSnapshot?
    func save(_ snapshot: BudgetSnapshot) throws
}
protocol RestoreRepository: BudgetRepository {
    func rollback() throws -> RollbackRecord?
    func replace(_ snapshot: BudgetSnapshot, rollback: RollbackRecord?) throws
    func clearRollback() throws
    func purgeExpiredRollback(now: Date) throws
}

struct BudgetStorage: Codable {
    var storageVersion = 1
    var snapshot: BudgetSnapshot
    var rollback: RollbackRecord?
}

/// 通常データと暗号化退避を一つのファイルとして原子的に更新する。
struct JSONBudgetRepository: RestoreRepository {
    let url: URL
    static func applicationDefault() -> Self {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BudgetBook", isDirectory: true)
        return Self(url: folder.appendingPathComponent("budget-v1.json"))
    }
    private func storage() throws -> BudgetStorage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let storage: BudgetStorage
        if object?["storageVersion"] != nil {
            storage = try JSONDecoder().decode(BudgetStorage.self, from: data)
            guard storage.storageVersion == 1 else { throw BackupError.unsupportedVersion }
        } else {
            // 既存の単体Snapshot形式を読み、次の保存時に移行する。
            storage = BudgetStorage(snapshot: try JSONDecoder().decode(BudgetSnapshot.self, from: data), rollback: nil)
        }
        guard [1, 2].contains(storage.snapshot.schemaVersion) else { throw BackupError.unsupportedVersion }
        return storage
    }
    func load() throws -> BudgetSnapshot? {
        guard let current = try storage() else { return nil }
        let migrated = try current.snapshot.preparedForUse()
        if migrated != current.snapshot { try replace(migrated, rollback: current.rollback) }
        return migrated
    }
    func rollback() throws -> RollbackRecord? { try storage()?.rollback }
    func save(_ snapshot: BudgetSnapshot) throws {
        try replace(snapshot, rollback: storage()?.rollback)
    }
    func replace(_ snapshot: BudgetSnapshot, rollback: RollbackRecord?) throws {
        let data = try JSONEncoder().encode(BudgetStorage(snapshot: snapshot, rollback: rollback))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
    func clearRollback() throws {
        guard let current = try storage() else { return }
        try replace(current.snapshot, rollback: nil)
    }
    func purgeExpiredRollback(now: Date) throws {
        if let record = try rollback(), now >= record.expiresAt { try clearRollback() }
    }
}
