import Foundation

protocol BudgetRepository {
    func load() throws -> BudgetSnapshot?
    func save(_ snapshot: BudgetSnapshot) throws
}

/// 暫定の端末内保存。バックアップ用フォーマットとは別で、Repositoryを差し替え可能。
struct JSONBudgetRepository: BudgetRepository {
    let url: URL
    static func applicationDefault() -> Self {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BudgetBook", isDirectory: true)
        return Self(url: folder.appendingPathComponent("budget-v1.json"))
    }
    func load() throws -> BudgetSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(BudgetSnapshot.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1 else {
            throw NSError(domain: "BudgetBook", code: 1, userInfo: [NSLocalizedDescriptionKey: "未対応の保存データです。元のファイルは変更しません。"])
        }
        return state
    }
    func save(_ snapshot: BudgetSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
