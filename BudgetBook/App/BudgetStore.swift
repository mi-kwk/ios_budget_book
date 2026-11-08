import Foundation
import SwiftUI

@MainActor
final class BudgetStore: ObservableObject {
    @Published private(set) var state: BudgetSnapshot
    @Published var errorMessage: String?
    private let repository: any BudgetRepository
    private(set) var canWrite = true
    @Published private(set) var rollbackRecord: RollbackRecord?
    @Published private(set) var cloudBusy = false
    @Published private(set) var cloudBackups: [CloudBackupItem] = []
    @Published private(set) var cloudMessage: String?
    private let cloudTransport: any CloudBackupTransport = AppleCloudBackupTransport()
    private let cloudPasswords: any CloudPasswordStore = DeviceCloudPasswordStore()
    private var cloudTimer: Task<Void, Never>?
    private var cloudDebounce: Task<Void, Never>?
    private var appIsActive = false
    private var nextAutomaticAttempt: Date?


    init(repository: any BudgetRepository = JSONBudgetRepository.applicationDefault()) {
        self.repository = repository
        do {
            if let saved = try repository.load() { state = saved }
            else { let initial = BudgetSnapshot.initial(); try repository.save(initial); state = initial }
        } catch {
            state = BudgetSnapshot()
            canWrite = false
            errorMessage = "保存データを読み込めませんでした。上書きを防ぐため編集を停止しています。\n\(error.localizedDescription)"
        }
        if canWrite { refreshRollback() }
    }
    @Published private(set) var viewingArchivedBookID: UUID?
    var bookID: UUID? { viewingArchivedBookID ?? state.selectedBookID }
    var canEditCurrentBook: Bool { bookID.map(canEditBook) ?? false }
    func canEditBook(_ id: UUID) -> Bool { canWrite && state.books.contains { $0.id == id && !$0.archived } }
    var currentBook: HouseholdBook? { state.books.first { $0.id == bookID } }
    var accounts: [MoneyAccount] { bookID.map { state.orderedAccounts(bookID: $0) } ?? [] }
    var categories: [BudgetCategory] { state.categories.filter { $0.bookID == bookID }.sorted { $0.order < $1.order } }
    var tags: [BudgetTag] { bookID.map { state.orderedTags(bookID: $0) } ?? [] }
    var entries: [BudgetEntry] { bookID.map { state.orderedEntries(bookID: $0) } ?? [] }
    func entries(in month: Date) -> [BudgetEntry] {
        let calendar = Calendar.current
        return entries.filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }
    }
    func categoryName(_ id: UUID?) -> String { state.categories.first { $0.id == id }?.name ?? "未分類" }
    func accountName(_ id: UUID?) -> String { state.accounts.first { $0.id == id }?.name ?? "未指定" }
    func categoryTitle(_ category: BudgetCategory) -> String {
        if let parent = state.categories.first(where: { $0.id == category.parentID }) { return "\(parent.name) / \(category.name)" }
        return category.name
    }
    @discardableResult
    func update(_ change: (inout BudgetSnapshot) throws -> Void) -> Bool {
        guard canWrite else { return false }
        do {
            var next = state
            try change(&next)
            try next.validateArchivedBookChanges(from: state)
            try repository.save(next)
            state = next
            scheduleCloudBackup()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func selectBook(_ id: UUID) {
        if update({ try $0.selectActiveBook(id) }) { viewingArchivedBookID = nil }
    }
    func viewArchivedBook(_ id: UUID) {
        guard state.books.contains(where: { $0.id == id && $0.archived }) else { return }
        viewingArchivedBookID = id
    }
    func endArchivedViewing() { viewingArchivedBookID = nil }
    func renameBook(id: UUID, name: String) -> Bool { update { try $0.renameBook(id: id, name: name) } }
    func setBookArchived(id: UUID, archived: Bool) -> Bool {
        let saved = update { try $0.setBookArchived(id: id, archived: archived) }
        if saved, viewingArchivedBookID == id { viewingArchivedBookID = nil }
        return saved
    }
    func moveBooks(from: IndexSet, to: Int) {
        update { snapshot in
            var ids = snapshot.orderedBooks(includeArchived: false).map(\.id)
            ids.move(fromOffsets: from, toOffset: to)
            try snapshot.reorderBooks(ids: ids)
        }
    }
    func saveEntry(_ entry: BudgetEntry) -> Bool {
        update { snapshot in
            try snapshot.saveTransaction(entry)
        }
    }
    func deleteEntry(_ id: UUID) { update { try $0.deleteTransaction(id) } }
    func addBook(name: String, shared: Bool) {
        if update({ try $0.createBook(name: name, shared: shared) }) { viewingArchivedBookID = nil }
    }
    func toggleArchive(_ id: UUID, type: MasterType) {
        update { snapshot in
            switch type {
            case .category:
                guard let category = snapshot.categories.first(where: { $0.id == id && $0.bookID == self.bookID }) else { throw BudgetError.invalidCategory }
                try snapshot.setCategoryArchived(id: id, bookID: category.bookID, archived: !category.isArchived)
            case .tag:
                guard let tag = snapshot.tags.first(where: { $0.id == id && $0.bookID == self.bookID }) else { throw BudgetError.invalidTag }
                try snapshot.setTagArchived(id: id, bookID: tag.bookID, archived: !tag.isArchived)
            case .account:
                guard let account = snapshot.accounts.first(where: { $0.id == id && $0.bookID == self.bookID }) else { throw BudgetError.invalidAccount }
                try snapshot.setAccountArchived(id: id, bookID: account.bookID, archived: !account.isArchived)
            }
        }
    }
    @discardableResult
    func saveCategory(id: UUID? = nil, bookID: UUID, kind: EntryKind, name: String, parentID: UUID?) -> UUID? {
        var savedID: UUID?
        let success = update { snapshot in
            savedID = try snapshot.saveCategory(id: id, bookID: bookID, kind: kind, name: name, parentID: parentID)
        }
        return success ? savedID : nil
    }
    func moveCategories(bookID: UUID, kind: EntryKind, parentID: UUID?, from: IndexSet, to: Int) {
        update { snapshot in
            var ids = snapshot.orderedCategories(bookID: bookID, kind: kind, parentID: parentID).map(\.id)
            ids.move(fromOffsets: from, toOffset: to)
            try snapshot.reorderCategories(bookID: bookID, kind: kind, parentID: parentID, ids: ids)
        }
    }

    @discardableResult
    func saveMaster(id: UUID? = nil, bookID: UUID, name: String, type: MasterType) -> UUID? {
        var savedID: UUID?
        let saved = update { snapshot in
            switch type {
            case .tag: savedID = try snapshot.saveTag(id: id, bookID: bookID, name: name)
            case .account: savedID = try snapshot.saveAccount(id: id, bookID: bookID, name: name)
            case .category: throw BudgetError.invalidCategory
            }
        }
        return saved ? savedID : nil
    }
    func moveTags(bookID: UUID, from: IndexSet, to: Int) {
        update { snapshot in
            var ids = snapshot.orderedTags(bookID: bookID).map(\.id)
            ids.move(fromOffsets: from, toOffset: to)
            try snapshot.reorderTags(bookID: bookID, ids: ids)
        }
    }
    func moveAccounts(bookID: UUID, from: IndexSet, to: Int) {
        update { snapshot in
            var ids = snapshot.orderedAccounts(bookID: bookID).map(\.id)
            ids.move(fromOffsets: from, toOffset: to)
            try snapshot.reorderAccounts(bookID: bookID, ids: ids)
        }
    }

    func restoreBackup(_ payload: BackupPayload) throws {
        guard canWrite, let storage = repository as? any RestoreRepository else { throw BackupError.invalidData }
        guard !cloudBusy else { throw CloudBackupError.unavailable }
        var restored = try payload.snapshot.preparedForUse()
        if restored.cloudBackupSettings != nil { restored.cloudBackupSettings?.pausedAfterRestore = true }
        cloudDebounce?.cancel()
        let record = try RestoreCoordinator(repository: storage, keys: DeviceRollbackKeyStore()).restore(restored)
        state = restored
        viewingArchivedBookID = nil
        rollbackRecord = record
    }
    func undoRestore() throws {
        guard canWrite, let storage = repository as? any RestoreRepository else { throw BackupError.invalidData }
        guard !cloudBusy else { throw CloudBackupError.unavailable }
        cloudDebounce?.cancel()
        state = try RestoreCoordinator(repository: storage, keys: DeviceRollbackKeyStore()).undo { snapshot in
            if snapshot.cloudBackupSettings != nil { snapshot.cloudBackupSettings?.pausedAfterRestore = true }
        }
        rollbackRecord = nil
        viewingArchivedBookID = nil
    }
    func clearRollback() throws {
        guard let storage = repository as? any RestoreRepository else { throw BackupError.noRollback }
        try storage.clearRollback()
        rollbackRecord = nil
    }
    func refreshRollback() {
        guard let storage = repository as? any RestoreRepository else { return }
        do { try storage.purgeExpiredRollback(now: Date()); rollbackRecord = try storage.rollback() }
        catch { errorMessage = error.localizedDescription }
    }

    var cloudSettings: CloudBackupSettings { state.cloudBackupSettings ?? CloudBackupSettings() }
    private func persistCloudSettings(_ settings: CloudBackupSettings) throws {
        guard canWrite else { throw BackupError.invalidData }
        var next = state; next.cloudBackupSettings = settings
        try repository.save(next); state = next
    }
    func setCloudAutomation(_ enabled: Bool) {
        guard !cloudBusy else { return }
        if !enabled {
            var settings = cloudSettings; settings.enabled = false
            do { try persistCloudSettings(settings); cloudDebounce?.cancel() }
            catch { cloudMessage = error.localizedDescription }
            return
        }
        Task {
            guard !cloudBusy else { return }; cloudBusy = true
            defer { cloudBusy = false; scheduleCloudBackup() }
            do {
                let account = try await cloudTransport.account()
                guard cloudSettings.accountFingerprint == account else { throw CloudBackupError.changedAccount }
                _ = try cloudPasswords.read(account: account)
                var settings = cloudSettings; settings.enabled = true; settings.pausedAfterRestore = false
                settings.nextRetryAt = nil; nextAutomaticAttempt = nil
                try persistCloudSettings(settings)
            } catch { cloudMessage = Self.cloudError(error) }
        }
    }
    func configureCloudPassword(_ password: String) async {
        guard !cloudBusy else { return }; cloudBusy = true
        defer { cloudBusy = false; scheduleCloudBackup() }
        do {
            let account = try await cloudTransport.account()
            try cloudPasswords.save(password, account: account)
            var settings = cloudSettings
            if settings.accountFingerprint != account { settings.lastDigest = nil; settings.lastSuccessfulAt = nil }
            settings.accountFingerprint = account; settings.enabled = true; settings.pausedAfterRestore = false
            settings.nextRetryAt = nil; settings.lastError = nil; nextAutomaticAttempt = nil
            try persistCloudSettings(settings)
            cloudMessage = "この端末にiCloud用パスワードを保存しました。機種変更先での復元には同じパスワードが必要です。"
        } catch { cloudMessage = Self.cloudError(error) }
    }
    func refreshCloudBackups() async {
        guard !cloudBusy else { return }; cloudBusy = true
        defer { cloudBusy = false }
        do {
            let account = try await cloudTransport.account()
            let items = try await cloudTransport.list()
            guard try await cloudTransport.account() == account else { throw CloudBackupError.changedAccount }
            cloudBackups = items.sorted { $0.savedAt > $1.savedAt }
            cloudMessage = items.isEmpty ? "iCloudにバックアップはありません。" : "iCloudのバックアップ一覧を更新しました。"
        } catch { cloudBackups = []; cloudMessage = Self.cloudError(error) }
    }
    func saveToCloud(manual: Bool = true) async {
        guard !cloudBusy, canWrite else { return }
        if !manual {
            guard appIsActive, nextAutomaticAttempt.map({ Date() >= $0 }) ?? true,
                  let account = cloudSettings.accountFingerprint,
                  let digest = try? CloudBackupPolicy.digest(state),
                  CloudBackupPolicy.shouldSave(settings: cloudSettings, digest: digest, account: account, now: Date()) else { return }
        }
        cloudBusy = true
        defer { cloudBusy = false }
        var submitted: CloudSaveResult?
        do {
            let account = try await cloudTransport.account()
            let snapshot = state
            let digest = try CloudBackupPolicy.digest(snapshot)
            let now = Date()
            if !manual && !CloudBackupPolicy.shouldSave(settings: cloudSettings, digest: digest, account: account, now: now) { return }
            guard cloudSettings.accountFingerprint == account else { throw CloudBackupError.changedAccount }
            let password = try cloudPasswords.read(account: account)
            var settings = cloudSettings; settings.lastAttemptAt = now
            try persistCloudSettings(settings)
            let result = try await CloudBackupService(transport: cloudTransport).save(BackupPayload(snapshot: snapshot), password: password, account: account)
            submitted = result
            settings = cloudSettings
            settings.accountFingerprint = account; settings.lastSuccessfulAt = Date(); settings.lastDigest = digest
            settings.nextRetryAt = nil; settings.lastError = nil; settings.maintenanceWarning = result.maintenanceWarning
            try persistCloudSettings(settings)
            nextAutomaticAttempt = nil
            cloudBackups = ((try? await cloudTransport.list()) ?? [result.item]).sorted { $0.savedAt > $1.savedAt }
            cloudMessage = result.maintenanceWarning ?? "iCloudへのバックアップが完了しました。"
        } catch {
            nextAutomaticAttempt = Date().addingTimeInterval(15 * 60)
            var settings = cloudSettings
            settings.nextRetryAt = nextAutomaticAttempt
            settings.lastError = submitted == nil ? Self.cloudError(error) : "iCloud保存は成功しましたが、端末側の状態記録に失敗しました。"
            if case CloudBackupError.changedAccount = error { settings.enabled = false }
            try? persistCloudSettings(settings)
            cloudMessage = settings.lastError
        }
    }
    func prepareCloudRestore(_ item: CloudBackupItem, password: String) async throws -> BackupPayload {
        guard !cloudBusy else { throw CloudBackupError.unavailable }; cloudBusy = true
        defer { cloudBusy = false }
        let account = try await cloudTransport.account()
        return try await CloudBackupService(transport: cloudTransport).prepare(id: item.id, password: password, account: account)
    }
    func cloudAccountChanged() {
        cloudDebounce?.cancel(); cloudBackups = []
        var settings = cloudSettings; settings.enabled = false
        settings.accountFingerprint = nil; settings.lastSuccessfulAt = nil; settings.lastDigest = nil
        settings.lastError = CloudBackupError.changedAccount.localizedDescription
        try? persistCloudSettings(settings)
        cloudMessage = settings.lastError
    }
    func setAppActive(_ active: Bool) {
        appIsActive = active
        cloudTimer?.cancel(); cloudTimer = nil
        if active {
            refreshRollback(); scheduleCloudBackup()
            cloudTimer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    self?.scheduleCloudBackup()
                }
            }
        } else { cloudDebounce?.cancel() }
    }
    private func scheduleCloudBackup() {
        guard appIsActive, !cloudBusy, canWrite, cloudSettings.enabled, !cloudSettings.pausedAfterRestore,
              nextAutomaticAttempt.map({ Date() >= $0 }) ?? true else { return }
        cloudDebounce?.cancel()
        cloudDebounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.cloudDebounce = nil
            await self.saveToCloud(manual: false)
        }
    }
    private static func cloudError(_ error: Error) -> String { CloudBackupMessages.describe(error) }

}

enum MasterType: String, Identifiable { case category = "カテゴリ", tag = "タグ", account = "入出金元"; var id: String { rawValue } }
