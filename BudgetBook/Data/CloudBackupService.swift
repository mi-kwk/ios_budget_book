import Foundation
import CryptoKit
import CloudKit
import Security

struct CloudBackupSettings: Codable, Equatable {
    var enabled = false
    var pausedAfterRestore = false
    var accountFingerprint: String?
    var lastSuccessfulAt: Date?
    var lastDigest: String?
    var lastAttemptAt: Date?
    var nextRetryAt: Date?
    var lastError: String?
    var maintenanceWarning: String?
}
struct CloudBackupItem: Identifiable, Equatable {
    let id: String
    let createdAt: Date
    let savedAt: Date
}
enum CloudBackupError: LocalizedError {
    case notConfigured, noAccount, unavailable, changedAccount, passwordMissing, missingFile, invalidRecord
    var errorDescription: String? {
        switch self {
        case .notConfigured: "iCloudの開発設定が未完了です。開発用Team・CloudKitコンテナ・スキーマを設定してください。端末内データとファイルのバックアップはそのまま利用できます。"
        case .noAccount: "iCloudにサインインしてください。端末内の家計簿はそのまま使えます。"
        case .unavailable: "iCloudを利用できません。通信・アカウントの状態を確認し、必要なら暗号化ファイルへ書き出してください。"
        case .changedAccount: "iCloudアカウントが変わりました。自動保存を停止し、アカウントとパスワードを確認してください。"
        case .passwordMissing: "この端末にiCloud用パスワードがありません。保存用パスワードを設定してください。機種変更時の復元には以前のパスワードが必要です。"
        case .missingFile: "バックアップが見つかりません。一覧を更新してください。"
        case .invalidRecord: "iCloudのバックアップ情報を確認できません。現在のデータは変更していません。"
        }
    }
}

protocol CloudBackupTransport {
    func account() async throws -> String
    func list() async throws -> [CloudBackupItem]
    func upload(id: String, data: Data, createdAt: Date) async throws -> CloudBackupItem
    func download(id: String) async throws -> Data
    func delete(id: String) async throws
}

/// CloudKitを呼ぶのは開発設定の有効化後のみ。コンテナ未設定でSDKを初期化しない。
struct AppleCloudBackupTransport: CloudBackupTransport {
    private func container() throws -> CKContainer {
        let enabled = Bundle.main.object(forInfoDictionaryKey: "BudgetCloudEnabled") as? String
        guard enabled == "YES", let id = Bundle.main.object(forInfoDictionaryKey: "BudgetCloudContainer") as? String, id.hasPrefix("iCloud.") else { throw CloudBackupError.notConfigured }
        return CKContainer(identifier: id)
    }
    func account() async throws -> String {
        let container = try container()
        let status = try await container.accountStatus()
        guard status == .available else { throw status == .noAccount ? CloudBackupError.noAccount : CloudBackupError.unavailable }
        let id = try await container.userRecordID()
        return SHA256.hash(data: Data(id.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func item(_ record: CKRecord) throws -> CloudBackupItem {
        guard record.recordID.recordName.hasPrefix("backup-"), let created = record["backupDate"] as? Date, let saved = record.creationDate else { throw CloudBackupError.invalidRecord }
        return CloudBackupItem(id: record.recordID.recordName, createdAt: created, savedAt: saved)
    }
    func list() async throws -> [CloudBackupItem] {
        let db = try container().privateCloudDatabase
        let query = CKQuery(recordType: "BudgetBackup", predicate: NSPredicate(value: true))
        var result = try await db.records(matching: query, desiredKeys: ["backupDate"], resultsLimit: 100)
        var items: [CloudBackupItem] = []
        while true {
            for (_, record) in result.matchResults { items.append(try item(record.get())) }
            guard let cursor = result.queryCursor else { break }
            result = try await db.records(continuingMatchFrom: cursor, desiredKeys: ["backupDate"], resultsLimit: 100)
        }
        return items
    }
    func upload(id: String, data: Data, createdAt: Date) async throws -> CloudBackupItem {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("budgetbackup")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: url) }
        let record = CKRecord(recordType: "BudgetBackup", recordID: CKRecord.ID(recordName: id))
        record["backupDate"] = createdAt as CKRecordValue
        record["payload"] = CKAsset(fileURL: url)
        let saved = try await container().privateCloudDatabase.save(record)
        return try item(saved)
    }
    func download(id: String) async throws -> Data {
        guard id.hasPrefix("backup-") else { throw CloudBackupError.invalidRecord }
        let record = try await container().privateCloudDatabase.record(for: CKRecord.ID(recordName: id))
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else { throw CloudBackupError.missingFile }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: BackupCodec.maxBytes + 1) ?? Data()
        guard data.count <= BackupCodec.maxBytes else { throw BackupError.tooLarge }
        return data
    }
    func delete(id: String) async throws {
        guard id.hasPrefix("backup-") else { throw CloudBackupError.invalidRecord }
        _ = try await container().privateCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: id))
    }
}

protocol CloudPasswordStore {
    func read(account: String) throws -> String
    func save(_ password: String, account: String) throws
}
struct DeviceCloudPasswordStore: CloudPasswordStore {
    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.mikwk.budgetbook.cloud-password", kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func read(account: String) throws -> String {
        var query = query(account: account); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw CloudBackupError.passwordMissing }
        return value
    }
    func save(_ password: String, account: String) throws {
        guard password.count >= 8, password.utf8.count <= 4096, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackupError.passwordTooShort }
        let query = query(account: account)
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw BackupError.keyUnavailable }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BackupError.keyUnavailable }
    }
}

enum CloudBackupPolicy {
    static func digest(_ snapshot: BudgetSnapshot) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var object = try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as! [String: Any]
        object.removeValue(forKey: "cloudBackupSettings")
        // Setのエンコード順による誤検知を防ぐ。
        for (arrayKey, setKey) in [("books", "hiddenTagIDs"), ("entries", "tagIDs")] {
            if var rows = object[arrayKey] as? [[String: Any]] {
                for i in rows.indices { if let ids = rows[i][setKey] as? [String] { rows[i][setKey] = ids.sorted() } }
                object[arrayKey] = rows
            }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func shouldSave(settings: CloudBackupSettings, digest: String, account: String, now: Date, calendar: Calendar = .current) -> Bool {
        guard settings.enabled, !settings.pausedAfterRestore, settings.accountFingerprint == account,
              settings.lastDigest != digest, settings.nextRetryAt.map({ now >= $0 }) ?? true else { return false }
        if let last = settings.lastSuccessfulAt { return now >= last && !calendar.isDate(last, inSameDayAs: now) }
        return true
    }
    static func excess(_ items: [CloudBackupItem], preserving id: String? = nil) -> [CloudBackupItem] {
        let sorted = items.sorted { $0.savedAt == $1.savedAt ? $0.id > $1.id : $0.savedAt > $1.savedAt }
        if let id, let saved = sorted.first(where: { $0.id == id }) {
            return Array(([saved] + sorted.filter { $0.id != id }).dropFirst(3))
        }
        return Array(sorted.dropFirst(3))
    }
}

struct CloudSaveResult {
    let item: CloudBackupItem
    let maintenanceWarning: String?
}
struct CloudBackupService {
    let transport: any CloudBackupTransport
    func save(_ payload: BackupPayload, password: String, account: String) async throws -> CloudSaveResult {
        guard try await transport.account() == account else { throw CloudBackupError.changedAccount }
        let data = try await Task.detached { try BackupCodec.encrypt(payload, password: password) }.value
        guard try await transport.account() == account else { throw CloudBackupError.changedAccount }
        let item = try await transport.upload(id: "backup-" + UUID().uuidString, data: data, createdAt: payload.createdAt)
        var warning: String?
        // サーバー保存に成功した後だけ、最新3件以外を整理する。途中失敗時は多めに残す。
        do {
            let items = try await transport.list()
            guard items.contains(where: { $0.id == item.id }) else { throw CloudBackupError.invalidRecord }
            for old in CloudBackupPolicy.excess(items, preserving: item.id) {
                guard try await transport.account() == account else { throw CloudBackupError.changedAccount }
                try await transport.delete(id: old.id)
            }
        } catch { warning = "保存は成功しましたが、過去の世代の整理が完了していません。一覧を更新して確認してください。" }
        guard try await transport.account() == account else { throw CloudBackupError.changedAccount }
        return CloudSaveResult(item: item, maintenanceWarning: warning)
    }
    func prepare(id: String, password: String, account: String) async throws -> BackupPayload {
        guard try await transport.account() == account else { throw CloudBackupError.changedAccount }
        let data = try await transport.download(id: id)
        let result = try await Task.detached { try BackupCodec.decrypt(data, password: password) }.value
        guard try await transport.account() == account else { throw CloudBackupError.changedAccount }
        return result
    }
}

enum CloudBackupMessages {
    static func describe(_ error: Error) -> String {
        guard let cloud = error as? CKError else { return error.localizedDescription }
        switch cloud.code {
        case .notAuthenticated: return CloudBackupError.noAccount.localizedDescription
        case .quotaExceeded: return "iCloudの容量が不足しています。容量を確保するか、暗号化ファイルへ書き出してください。端末内データは維持しています。"
        case .badContainer, .missingEntitlement, .permissionFailure: return CloudBackupError.notConfigured.localizedDescription
        case .invalidArguments, .unknownItem: return "iCloudの保存形式が未設定か、項目が見つかりません。開発設定とバックアップ一覧を確認してください。"
        default: return CloudBackupError.unavailable.localizedDescription
        }
    }
}
