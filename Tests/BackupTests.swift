import Foundation
import CryptoKit

struct TestRollbackKeys: RollbackKeyStore {
    var available = true
    func key(createIfMissing: Bool) throws -> SymmetricKey {
        guard available else { throw BackupError.keyUnavailable }
        return SymmetricKey(data: Data(repeating: 42, count: 32))
    }
}
final class FaultRestoreRepository: RestoreRepository {
    let base: JSONBudgetRepository
    var fail = false
    init(base: JSONBudgetRepository) { self.base = base }
    func load() throws -> BudgetSnapshot? { try base.load() }
    func save(_ snapshot: BudgetSnapshot) throws { try base.save(snapshot) }
    func rollback() throws -> RollbackRecord? { try base.rollback() }
    func clearRollback() throws { try base.clearRollback() }
    func purgeExpiredRollback(now: Date) throws { try base.purgeExpiredRollback(now: now) }
    func replace(_ snapshot: BudgetSnapshot, rollback: RollbackRecord?) throws {
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        try base.replace(snapshot, rollback: rollback)
    }
}

func expectBackup(_ condition: Bool, _ message: String) { expect(condition, message) }

func runBackupChecks() throws {
    let password = "backup-test-password-2026"
    let now = Date(timeIntervalSince1970: 1_793_491_200)
    var original = testSnapshot()
    let bookID = original.books[0].id
    let wallet = original.accounts.first { $0.bookID == bookID }!.id
    let tag = try original.saveTag(bookID: bookID, name: "保存確認")
    original.books[0].hiddenTagIDs = [tag]
    original.entries = [try original.validated(BudgetEntry(bookID: bookID, kind: .expense, amount: 3210, date: now, sourceID: wallet, tagIDs: [tag], memo: "バックアップ検証"))]
    try original.setTagArchived(id: tag, bookID: bookID, archived: true)
    try original.validateBackup()
    let payload = BackupPayload(snapshot: original, createdAt: now)
    let encrypted = try BackupCodec.encrypt(payload, password: password)
    let reopened = try BackupCodec.decrypt(encrypted, password: password)
    expectBackup(reopened.snapshot == original && reopened.createdAt == now, "暗号化バックアップで全データ・設定・関連・日時を復元")
    expectBackup(!String(decoding: encrypted, as: UTF8.self).contains("バックアップ検証"), "外側に平文の取引メモを含めない")
    let anotherCipher = try BackupCodec.encrypt(payload, password: password)
    expectBackup(encrypted != anotherCipher, "同じデータ・パスワードでもsalt/nonceを再利用しない")
    rejects("空パスワードの出力を禁止") { _ = try BackupCodec.encrypt(payload, password: "") }
    rejects("短いパスワードの出力を禁止") { _ = try BackupCodec.encrypt(payload, password: "1234567") }
    rejects("誤ったパスワードを拒否") { _ = try BackupCodec.decrypt(encrypted, password: "wrong-password") }
    rejects("空パスワードでの読み込みを拒否") { _ = try BackupCodec.decrypt(encrypted, password: "") }
    rejects("平文JSONを暗号化バックアップとして読まない") { _ = try BackupCodec.decrypt(JSONEncoder().encode(original), password: password) }
    rejects("途中で切れたファイルを拒否") { _ = try BackupCodec.decrypt(encrypted.prefix(encrypted.count / 2), password: password) }
    rejects("上限を超えるファイルを拒否") { _ = try BackupCodec.decrypt(Data(count: BackupCodec.maxBytes + 1), password: password) }
    let outer = try JSONDecoder().decode(EncryptedBackup.self, from: encrypted)
    var damaged = outer.sealed; damaged[damaged.count / 2] ^= 1
    let corrupted = EncryptedBackup(format: outer.format, version: outer.version, algorithm: outer.algorithm, iterations: outer.iterations, salt: outer.salt, sealed: damaged)
    rejects("暗号文の改ざんを拒否") { _ = try BackupCodec.decrypt(JSONEncoder().encode(corrupted), password: password) }
    let unsupported = EncryptedBackup(format: outer.format, version: 99, algorithm: outer.algorithm, iterations: outer.iterations, salt: outer.salt, sealed: outer.sealed)
    rejects("未対応のファイル版を拒否") { _ = try BackupCodec.decrypt(JSONEncoder().encode(unsupported), password: password) }
    let heavyKDF = EncryptedBackup(format: outer.format, version: 1, algorithm: outer.algorithm, iterations: UInt32.max, salt: outer.salt, sealed: outer.sealed)
    rejects("不正なKDF反復数を計算前に拒否") { _ = try BackupCodec.decrypt(JSONEncoder().encode(heavyKDF), password: password) }
    var invalid = original; invalid.entries[0].sourceID = UUID()
    rejects("存在しない入出金元の参照を拒否") { try invalid.validateBackup() }
    invalid = original; invalid.entries[0].sourceID = original.accounts.first { $0.bookID != bookID }!.id
    rejects("入出金元の家計簿越境を拒否") { try invalid.validateBackup() }
    invalid = original; invalid.tags.append(invalid.tags[0])
    rejects("重複IDを辞書構築前に拒否") { try invalid.validateBackup() }
    invalid = original; invalid.accounts.removeAll { $0.bookID == bookID && $0.isWallet }
    rejects("標準お財布の欠落を拒否") { try invalid.validateBackup() }
    invalid = original; invalid.books[0].hiddenTagIDs.insert(UUID())
    rejects("表示設定の参照切れを拒否") { try invalid.validateBackup() }
    invalid = original; if let index = invalid.categories.firstIndex(where: { $0.isUncategorized }) { invalid.categories[index].isArchived = true }
    rejects("未分類の不正なアーカイブを拒否") { try invalid.validateBackup() }
    invalid = original; invalid.entries[0].categoryID = UUID()
    rejects("存在しないカテゴリを拒否") { try invalid.validateBackup() }
    invalid = original; invalid.entries[0].tagIDs = [UUID()]
    rejects("存在しないタグを拒否") { try invalid.validateBackup() }
    invalid = original; invalid.entries[0].amount = -1
    rejects("不正な金額を拒否") { try invalid.validateBackup() }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let repo = JSONBudgetRepository(url: folder.appendingPathComponent("budget.json"))
    // 実際の旧保存形式を読み、次の保存時に新しいコンテナ形式へ移行。
    try JSONEncoder().encode(original).write(to: repo.url)
    expectBackup(try repo.load() == original, "旧Snapshot単体ファイルを読み込める")
    try repo.save(original)
    expectBackup(try JSONDecoder().decode(BudgetStorage.self, from: Data(contentsOf: repo.url)).snapshot == original, "通常保存で旧データを損なわずコンテナへ移行")
    let fault = FaultRestoreRepository(base: repo)
    let coordinator = RestoreCoordinator(repository: fault, keys: TestRollbackKeys())
    var replacement = original
    replacement.entries = []
    replacement.books[0].name = "復元後"
    let before = try Data(contentsOf: repo.url)
    fault.fail = true
    rejects("保存容量不足で復元を中止") { try coordinator.restore(replacement, now: now) }
    expectBackup(try Data(contentsOf: repo.url) == before, "退避と復元先の保存に失敗したら元ファイル全体を維持")
    fault.fail = false
    rejects("端末鍵が使えなければ復元しない") { try RestoreCoordinator(repository: repo, keys: TestRollbackKeys(available: false)).restore(replacement, now: now) }
    expectBackup(try repo.load() == original && repo.rollback() == nil, "鍵取得失敗で現行データ・退避状態を変更しない")
    try coordinator.restore(replacement, now: now)
    expectBackup(try repo.load() == replacement, "復元対象で全件置換し元の取引を混在させない")
    let checkpoint = try repo.rollback()!
    expectBackup(checkpoint.expiresAt == now.addingTimeInterval(604800), "復元時から7日間保持する")
    expectBackup(try checkpoint.snapshot(now: now, key: TestRollbackKeys().key(createIfMissing: false)) == original, "退避から全設定を取り出せる")
    expectBackup((try? JSONDecoder().decode(BudgetSnapshot.self, from: checkpoint.sealed)) == nil, "退避は平文JSONで保存しない")
    var changed = replacement; changed.books[0].name = "復元後の追記"
    try repo.save(changed)
    expectBackup(try repo.rollback()?.createdAt == now, "通常の編集で退避の保持期限を延長しない")
    let beforeUndo = try Data(contentsOf: repo.url)
    fault.fail = true
    rejects("戻す処理の保存失敗を検出") { try coordinator.undo(now: now.addingTimeInterval(60)) }
    expectBackup(try Data(contentsOf: repo.url) == beforeUndo, "戻す保存失敗でも現行データと退避を維持")
    fault.fail = false
    try coordinator.undo(now: now.addingTimeInterval(60))
    expectBackup(try repo.load() == original && repo.rollback() == nil, "戻す操作で元に全置換し、使用済み退避を削除")
    try coordinator.restore(replacement, now: now)
    try coordinator.restore(changed, now: now.addingTimeInterval(60))
    expectBackup(try repo.rollback()!.snapshot(now: now.addingTimeInterval(120), key: TestRollbackKeys().key(createIfMissing: false)) == replacement, "連続復元では直前1件だけを退避")
    let expires = try repo.rollback()!.expiresAt
    rejects("期限切れの退避へは戻せない") { try coordinator.undo(now: expires) }
    try repo.purgeExpiredRollback(now: expires.addingTimeInterval(-1))
    expectBackup(try repo.rollback() != nil, "期限の直前には退避を消さない")
    try repo.purgeExpiredRollback(now: expires)
    expectBackup(try repo.rollback() == nil && repo.load() == changed, "期限切れ退避だけを削除し現行データを維持")
    try coordinator.restore(original, now: now)
    try repo.clearRollback()
    expectBackup(try repo.load() == original && repo.rollback() == nil, "早期削除で現行データは維持")
    let invalidBefore = try Data(contentsOf: repo.url)
    rejects("不正な復元先は退避作成前に拒否") { try coordinator.restore(invalid, now: now) }
    expectBackup(try Data(contentsOf: repo.url) == invalidBefore, "検証失敗は全ファイルを変更しない")
}
