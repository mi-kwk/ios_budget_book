import Foundation

final class TestCloudTransport: CloudBackupTransport {
    var identity = "account-A"
    var bytes: [String: Data] = [:]
    var items: [CloudBackupItem] = []
    var failUpload = false
    var failDelete = false
    var failList = false
    var deleted: [String] = []
    var uploaded: [String] = []
    var serverDate = Date(timeIntervalSince1970: 1_793_491_200)
    func account() async throws -> String { identity }
    func list() async throws -> [CloudBackupItem] {
        if failList { throw CloudBackupError.unavailable }; return items
    }
    func upload(id: String, data: Data, createdAt: Date) async throws -> CloudBackupItem {
        if failUpload { throw CloudBackupError.unavailable }
        serverDate = serverDate.addingTimeInterval(1)
        let item = CloudBackupItem(id: id, createdAt: createdAt, savedAt: serverDate)
        bytes[id] = data; items.append(item); uploaded.append(id); return item
    }
    func download(id: String) async throws -> Data {
        guard let data = bytes[id] else { throw CloudBackupError.missingFile }; return data
    }
    func delete(id: String) async throws {
        if failDelete { throw CloudBackupError.unavailable }
        deleted.append(id); bytes.removeValue(forKey: id); items.removeAll { $0.id == id }
    }
}

@MainActor
func cloudRejects(_ message: String, _ work: () async throws -> Void) async {
    do { try await work(); fatalError(message) } catch { checks += 1 }
}
@MainActor
func runCloudChecks() async throws {
    let now = Date(timeIntervalSince1970: 1_793_491_200)
    let initial = BudgetSnapshot.initial()
    let digest = try CloudBackupPolicy.digest(initial)
    var settings = CloudBackupSettings()
    settings.enabled = true; settings.accountFingerprint = "account-A"
    expect(CloudBackupPolicy.shouldSave(settings: settings, digest: digest, account: "account-A", now: now), "初回の変更データは保存対象")
    settings.lastSuccessfulAt = now; settings.lastDigest = digest
    expect(!CloudBackupPolicy.shouldSave(settings: settings, digest: digest, account: "account-A", now: now.addingTimeInterval(86400)), "変更がなければ日が変わっても保存しない")
    expect(!CloudBackupPolicy.shouldSave(settings: settings, digest: "changed", account: "account-A", now: now.addingTimeInterval(60)), "変更後も同じ日には自動で重複保存しない")
    expect(CloudBackupPolicy.shouldSave(settings: settings, digest: "changed", account: "account-A", now: now.addingTimeInterval(86400)), "日が変わり変更があれば保存")
    expect(!CloudBackupPolicy.shouldSave(settings: settings, digest: "changed", account: "account-B", now: now.addingTimeInterval(86400)), "アカウント変更後は自動保存しない")
    settings.pausedAfterRestore = true
    expect(!CloudBackupPolicy.shouldSave(settings: settings, digest: "changed", account: "account-A", now: now.addingTimeInterval(86400)), "復元直後は自動でクラウドへ上書きしない")
    settings.pausedAfterRestore = false; settings.nextRetryAt = now.addingTimeInterval(900)
    settings.lastSuccessfulAt = nil
    expect(!CloudBackupPolicy.shouldSave(settings: settings, digest: "changed", account: "account-A", now: now), "失敗後は即時再試行しない")
    expect(CloudBackupPolicy.shouldSave(settings: settings, digest: "changed", account: "account-A", now: now.addingTimeInterval(900)), "待機後に再試行可能")
    settings.enabled = false
    expect(!CloudBackupPolicy.shouldSave(settings: settings, digest: "changed", account: "account-A", now: now.addingTimeInterval(900)), "自動保存OFFを尊重")
    var statusOnly = initial; statusOnly.cloudBackupSettings = settings
    expectBackup(try CloudBackupPolicy.digest(statusOnly) == digest, "成功日時・エラー更新だけでは家計簿の変更と判定しない")
    var changed = initial; changed.books[0].name = "変更済み"
    expectBackup(try CloudBackupPolicy.digest(changed) != digest, "家計簿名の変更を検出")
    let snapshotRoundTrip = try JSONDecoder().decode(BudgetSnapshot.self, from: JSONEncoder().encode(statusOnly))
    expect(snapshotRoundTrip == statusOnly, "iCloud設定もバックアップ内で保存・復元")
    let transport = TestCloudTransport()
    let service = CloudBackupService(transport: transport)
    let password = "cloud-test-password"
    for index in 0..<5 {
        let result = try await service.save(BackupPayload(snapshot: initial, createdAt: now.addingTimeInterval(Double(index))), password: password, account: "account-A")
        expect(result.maintenanceWarning == nil, "保存と世代整理が成功")
    }
    expect(transport.items.count == 3 && transport.deleted.count == 2, "最新3世代のみ保持")
    let item = transport.items.last!
    let restored = try await service.prepare(id: item.id, password: password, account: "account-A")
    expect(restored.snapshot == initial, "クラウドから取得した暗号文を復元確認用データにできる")
    expect(!String(decoding: transport.bytes[item.id]!, as: UTF8.self).contains("個人用"), "クラウドへは家計簿本文を平文で送らない")
    let beforeFailure = transport.items
    transport.failUpload = true
    await cloudRejects("アップロード失敗を成功扱いしない") { _ = try await service.save(BackupPayload(snapshot: initial), password: password, account: "account-A") }
    expect(transport.items == beforeFailure && transport.deleted.count == 2, "アップロード失敗時には既存の世代を削除しない")
    transport.failUpload = false; transport.failDelete = true
    let partial = try await service.save(BackupPayload(snapshot: initial), password: password, account: "account-A")
    expect(partial.maintenanceWarning != nil && transport.items.count == 4, "整理失敗時は保存成功と区別し、古い世代を多めに残す")
    transport.failDelete = false; transport.failList = true
    let unlisted = try await service.save(BackupPayload(snapshot: initial), password: password, account: "account-A")
    expect(unlisted.maintenanceWarning != nil && transport.items.count == 5, "一覧が取得できないときに推測で削除しない")
    transport.failList = false
    let wrongAccountCount = transport.uploaded.count
    await cloudRejects("別アカウントへバックアップを送らない") { _ = try await service.save(BackupPayload(snapshot: initial), password: password, account: "account-B") }
    expect(transport.uploaded.count == wrongAccountCount, "アカウント不一致を送信前に検出")
    await cloudRejects("復元時に誤ったパスワードを拒否") { _ = try await service.prepare(id: item.id, password: "wrong-password", account: "account-A") }
    expect(transport.items.count == 5, "復元確認失敗はクラウドの既存データも変更しない")
    await cloudRejects("存在しないバックアップの取得に失敗する") { _ = try await service.prepare(id: "missing", password: password, account: "account-A") }
    let sameDate = (0..<4).map { CloudBackupItem(id: "backup-\($0)", createdAt: now, savedAt: now) }
    expect(!CloudBackupPolicy.excess(sameDate, preserving: "backup-0").contains { $0.id == "backup-0" }, "保存時刻が同じでも直前に成功した世代は削除しない")
    expect(CloudBackupPolicy.excess(sameDate, preserving: "backup-0").count == 1, "同時刻でも3世代に整理する")
    await cloudRejects("未設定環境ではCloudKitの初期化前に案内を返す") { _ = try await AppleCloudBackupTransport().account() }
}
