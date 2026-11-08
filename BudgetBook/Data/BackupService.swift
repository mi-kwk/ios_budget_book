import Foundation
import CryptoKit
import CommonCrypto
import Security

enum BackupError: LocalizedError {
    case passwordRequired, passwordTooShort, invalidFormat, unsupportedVersion, wrongPasswordOrDamaged, invalidData, tooLarge, noRollback, expiredRollback, keyUnavailable
    var errorDescription: String? {
        switch self {
        case .passwordRequired: "パスワードを入力してください。"
        case .passwordTooShort: "書き出し用パスワードは8文字以上で設定してください。"
        case .invalidFormat: "家計簿の暗号化バックアップファイルではありません。"
        case .unsupportedVersion: "このバージョンのバックアップには対応していません。アプリの更新を確認してください。"
        case .wrongPasswordOrDamaged: "パスワードが違うか、ファイルが破損・変更されています。現在のデータは変更していません。"
        case .invalidData: "データの関連や形式に問題があります。現在のデータは変更していません。"
        case .tooLarge: "このファイルは大きすぎます。対応上限は32MBです。"
        case .noRollback: "復元前の退避データがありません。"
        case .expiredRollback: "退避データの保持期限（7日間）が過ぎています。"
        case .keyUnavailable: "端末の暗号鍵を使用できません。端末のロックを解除して再試行してください。"
        }
    }
}

struct BackupPayload: Codable {
    let version: Int
    let createdAt: Date
    let snapshot: BudgetSnapshot
    init(snapshot: BudgetSnapshot, createdAt: Date = Date()) {
        version = 1; self.createdAt = createdAt; self.snapshot = snapshot
    }
}

struct EncryptedBackup: Codable {
    let format: String
    let version: Int
    let algorithm: String
    let iterations: UInt32
    let salt: Data
    let sealed: Data
}

/// パスワード付きポータブルファイル。平文の家計簿・件数・日時は外側に保存しない。
enum BackupCodec {
    static let maxBytes = 32 * 1024 * 1024
    static let iterations: UInt32 = 600_000
    static func encrypt(_ payload: BackupPayload, password: String) throws -> Data {
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackupError.passwordRequired }
        guard password.count >= 8 else { throw BackupError.passwordTooShort }
        guard password.utf8.count <= 4096 else { throw BackupError.invalidData }
        try payload.snapshot.validateBackup()
        let plaintext = try JSONEncoder().encode(payload)
        guard plaintext.count <= maxBytes / 2 else { throw BackupError.tooLarge }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BackupError.keyUnavailable }
        let key = try deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header(salt: salt)).combined!
        return try JSONEncoder().encode(EncryptedBackup(format: "BudgetBookEncrypted", version: 1, algorithm: "PBKDF2-SHA256/AES-256-GCM", iterations: iterations, salt: salt, sealed: sealed))
    }
    static func decrypt(_ data: Data, password: String) throws -> BackupPayload {
        guard data.count <= maxBytes else { throw BackupError.tooLarge }
        guard !password.isEmpty, password.utf8.count <= 4096 else { throw BackupError.passwordRequired }
        guard let envelope = try? JSONDecoder().decode(EncryptedBackup.self, from: data), envelope.format == "BudgetBookEncrypted" else { throw BackupError.invalidFormat }
        guard envelope.version == 1, envelope.algorithm == "PBKDF2-SHA256/AES-256-GCM", envelope.iterations == iterations else { throw BackupError.unsupportedVersion }
        guard envelope.salt.count == 16, envelope.sealed.count >= 28 else { throw BackupError.invalidFormat }
        let key = try deriveKey(password: password, salt: envelope.salt)
        let plaintext: Data
        do { plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key, authenticating: header(salt: envelope.salt)) }
        catch { throw BackupError.wrongPasswordOrDamaged }
        guard let payload = try? JSONDecoder().decode(BackupPayload.self, from: plaintext) else { throw BackupError.invalidData }
        guard payload.version == 1 else { throw BackupError.unsupportedVersion }
        guard payload.createdAt.timeIntervalSince1970.isFinite else { throw BackupError.invalidData }
        try payload.snapshot.validateBackup()
        return BackupPayload(snapshot: try payload.snapshot.preparedForUse(), createdAt: payload.createdAt)
    }
    private static func header(salt: Data) -> Data {
        Data("BudgetBookEncrypted|1|PBKDF2-SHA256/AES-256-GCM|\(iterations)|\(salt.base64EncodedString())".utf8)
    }
    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var passwordBytes = Array(password.utf8)
        var keyBytes = [UInt8](repeating: 0, count: 32)
        defer { _ = passwordBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }; _ = keyBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                keyBytes.withUnsafeMutableBytes { keyBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBuffer.baseAddress!.assumingMemoryBound(to: Int8.self), passwordBuffer.count,
                                        saltBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), saltBuffer.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                        keyBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), keyBuffer.count)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupError.keyUnavailable }
        return SymmetricKey(data: keyBytes)
    }
}

struct RollbackRecord: Codable {
    let createdAt: Date
    let expiresAt: Date
    let sealed: Data
    static func make(snapshot: BudgetSnapshot, now: Date, key: SymmetricKey) throws -> Self {
        let expires = now.addingTimeInterval(7 * 24 * 60 * 60)
        let plaintext = try JSONEncoder().encode(snapshot)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: metadata(now, expires)).combined!
        return Self(createdAt: now, expiresAt: expires, sealed: sealed)
    }
    func snapshot(now: Date, key: SymmetricKey) throws -> BudgetSnapshot {
        guard now < expiresAt else { throw BackupError.expiredRollback }
        do {
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Self.metadata(createdAt, expiresAt))
            let state = try JSONDecoder().decode(BudgetSnapshot.self, from: plaintext)
            try state.validateBackup()
            return try state.preparedForUse()
        } catch { throw BackupError.invalidData }
    }
    private static func metadata(_ createdAt: Date, _ expiresAt: Date) -> Data {
        Data("BudgetBookRollback|1|\(createdAt.timeIntervalSince1970)|\(expiresAt.timeIntervalSince1970)".utf8)
    }
}

protocol RollbackKeyStore {
    func key(createIfMissing: Bool) throws -> SymmetricKey
}
struct DeviceRollbackKeyStore: RollbackKeyStore {
    func key(createIfMissing: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.mikwk.budgetbook.rollback",
                                    kSecAttrAccount as String: "aes256-v1"]
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, createIfMissing else { throw BackupError.keyUnavailable }
        let key = SymmetricKey(size: .bits256)
        var write = query
        write[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        write[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        write[kSecAttrSynchronizable as String] = false
        guard SecItemAdd(write as CFDictionary, nil) == errSecSuccess else { throw BackupError.keyUnavailable }
        return key
    }
}

struct RestoreCoordinator {
    let repository: any RestoreRepository
    let keys: any RollbackKeyStore
    @discardableResult
    func restore(_ snapshot: BudgetSnapshot, now: Date = Date()) throws -> RollbackRecord {
        let snapshot = try snapshot.preparedForUse()
        try snapshot.validateBackup()
        guard let current = try repository.load() else { throw BackupError.invalidData }
        try current.validateBackup()
        let record = try RollbackRecord.make(snapshot: current, now: now, key: keys.key(createIfMissing: true))
        // 退避と復元先を同じファイルへ原子的に保存。退避できなければ置換しない。
        try repository.replace(snapshot, rollback: record)
        return record
    }
    @discardableResult
    func undo(now: Date = Date(), transform: (inout BudgetSnapshot) -> Void = { _ in }) throws -> BudgetSnapshot {
        guard let record = try repository.rollback() else { throw BackupError.noRollback }
        var original = try record.snapshot(now: now, key: keys.key(createIfMissing: false))
        transform(&original)
        try original.validateBackup()
        try repository.replace(original, rollback: nil)
        return original
    }
}
