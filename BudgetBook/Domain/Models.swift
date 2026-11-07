import Foundation

enum EntryKind: String, Codable, CaseIterable, Identifiable {
    case expense, income, transfer
    var id: String { rawValue }
    var title: String {
        switch self { case .expense: "支出"; case .income: "収入"; case .transfer: "振替" }
    }
}

struct HouseholdBook: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isShared = false
    // 仮の初期値。仕様確定後に変更可能。
    var showsTagSummary = true
    var hiddenTagIDs: Set<UUID> = []
}

struct MoneyAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var bookID: UUID
    var name: String
    var isWallet = false
    var isArchived = false
}

struct BudgetCategory: Identifiable, Codable, Equatable {
    var id = UUID()
    var bookID: UUID
    var name: String
    var kind: EntryKind
    var parentID: UUID? = nil
    var isUncategorized = false
    var isArchived = false
    var order = 0
}

struct BudgetTag: Identifiable, Codable, Equatable {
    var id = UUID()
    var bookID: UUID
    var name: String
    var isArchived = false
}

struct BudgetEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var bookID: UUID
    var kind: EntryKind
    // 初期枠組みは日本円・整数円。小数通貨への対応は別途検討。
    var amount: Int64
    var date: Date
    var categoryID: UUID? = nil
    var sourceID: UUID? = nil
    var destinationID: UUID? = nil
    var tagIDs: Set<UUID> = []
    var includedInTotals = true
    var memo = ""
}

struct BudgetSnapshot: Codable, Equatable {
    var schemaVersion = 1
    var books: [HouseholdBook] = []
    var accounts: [MoneyAccount] = []
    var categories: [BudgetCategory] = []
    var tags: [BudgetTag] = []
    var entries: [BudgetEntry] = []
    var selectedBookID: UUID? = nil

    static func initial() -> Self {
        var state = Self()
        // 初期2冊とカテゴリの具体一覧は試作用の仮設定。金額のサンプルは投入しない。
        for book in [HouseholdBook(name: "個人用"), HouseholdBook(name: "共有用", isShared: true)] {
            state.books.append(book)
            state.accounts.append(MoneyAccount(bookID: book.id, name: "お財布", isWallet: true))
            for kind in [EntryKind.expense, .income] {
                state.categories.append(BudgetCategory(bookID: book.id, name: "未分類", kind: kind, isUncategorized: true))
            }
        }
        state.selectedBookID = state.books.first?.id
        return state
    }

    func isCategoryAvailable(_ category: BudgetCategory) -> Bool {
        guard !category.isArchived else { return false }
        guard let parentID = category.parentID else { return true }
        return categories.contains { $0.id == parentID && !$0.isArchived && $0.bookID == category.bookID }
    }

    func validated(_ input: BudgetEntry, previous: BudgetEntry? = nil) throws -> BudgetEntry {
        var entry = input
        guard books.contains(where: { $0.id == entry.bookID }) else { throw BudgetError.invalidBook }
        guard entry.amount > 0, entry.amount <= 999_999_999_999 else { throw BudgetError.invalidAmount }
        func validAccount(_ id: UUID?, oldID: UUID?) -> Bool {
            guard let id else { return false }
            return accounts.contains { $0.id == id && $0.bookID == entry.bookID && (!$0.isArchived || oldID == id) }
        }
        if entry.kind == .transfer {
            guard entry.sourceID != nil || entry.destinationID != nil else { throw BudgetError.missingTransferAccount }
            guard entry.sourceID == nil || validAccount(entry.sourceID, oldID: previous?.sourceID) else { throw BudgetError.invalidAccount }
            guard entry.destinationID == nil || validAccount(entry.destinationID, oldID: previous?.destinationID) else { throw BudgetError.invalidAccount }
            guard entry.sourceID == nil || entry.sourceID != entry.destinationID else { throw BudgetError.sameAccount }
            entry.categoryID = nil
            entry.includedInTotals = false
        } else {
            if entry.kind == .expense {
                guard validAccount(entry.sourceID, oldID: previous?.sourceID) else { throw BudgetError.invalidAccount }
                entry.destinationID = nil
            } else {
                guard validAccount(entry.destinationID, oldID: previous?.destinationID) else { throw BudgetError.invalidAccount }
                entry.sourceID = nil
            }
            if entry.categoryID == nil {
                entry.categoryID = categories.first { $0.bookID == entry.bookID && $0.kind == entry.kind && $0.isUncategorized }?.id
            }
            guard let category = categories.first(where: { $0.id == entry.categoryID && $0.bookID == entry.bookID && $0.kind == entry.kind }),
                  isCategoryAvailable(category) || previous?.categoryID == category.id else { throw BudgetError.invalidCategory }
        }
        guard entry.tagIDs.allSatisfy({ id in
            tags.contains { $0.id == id && $0.bookID == entry.bookID && (!$0.isArchived || previous?.tagIDs.contains(id) == true) }
        }) else { throw BudgetError.invalidTag }
        return entry
    }
}

enum BudgetError: LocalizedError {
    case invalidBook, invalidAmount, invalidAccount, missingTransferAccount, sameAccount, invalidCategory, invalidTag, emptyName, duplicateName, protectedItem
    var errorDescription: String? {
        switch self {
        case .invalidBook: "家計簿が見つかりません。"
        case .invalidAmount: "金額は1〜999,999,999,999円の整数で入力してください。"
        case .invalidAccount: "有効な入出金元を選択してください。"
        case .missingTransferAccount: "振替元・振替先の少なくとも片方を指定してください。"
        case .sameAccount: "振替元と振替先は別の項目を選択してください。"
        case .invalidCategory: "この家計簿・収支種別で利用できるカテゴリを選択してください。"
        case .invalidTag: "この家計簿で利用できるタグを選択してください。"
        case .emptyName: "名前を入力してください。"
        case .duplicateName: "同じ名前が登録されています。アーカイブ済みの項目も確認してください。"
        case .protectedItem: "標準の項目は変更・アーカイブできません。"
        }
    }
}

struct MoneyTotals: Equatable {
    var income: Int64 = 0
    var expense: Int64 = 0
    var transfer: Int64 = 0
    var difference: Int64 { income - expense }
}

enum BudgetSummary {
    static func totals(_ entries: [BudgetEntry], includeExcluded: Bool = false) -> MoneyTotals {
        entries.reduce(into: MoneyTotals()) { result, entry in
            switch entry.kind {
            case .income: if includeExcluded || entry.includedInTotals { result.income += entry.amount }
            case .expense: if includeExcluded || entry.includedInTotals { result.expense += entry.amount }
            case .transfer: if includeExcluded { result.transfer += entry.amount }
            }
        }
    }
    static func matchingTags(_ entries: [BudgetEntry], tags: Set<UUID>, matchAll: Bool) -> [BudgetEntry] {
        // 未選択は全件という仮ルール。元配列の各取引を一度だけ評価する。
        guard !tags.isEmpty else { return entries }
        return entries.filter { matchAll ? tags.isSubset(of: $0.tagIDs) : !$0.tagIDs.isDisjoint(with: tags) }
    }
}
