import Foundation

enum EntryKind: String, Codable, CaseIterable, Identifiable {
    case expense, income, transfer, refund
    var id: String { rawValue }
    var title: String {
        switch self { case .expense: "支出"; case .income: "収入"; case .transfer: "振替"; case .refund: "返金" }
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
    // Optionalで旧JSON（並び順なし）をそのまま読める。
    var order: Int? = nil
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
    // Optional fields keep files written before refund support readable.
    var merchant: String? = nil
    var createdAt: Date? = nil
    var refundOfID: UUID? = nil
}

struct BudgetSnapshot: Codable, Equatable {
    var schemaVersion = 2
    var cloudBackupSettings: CloudBackupSettings? = nil
    var books: [HouseholdBook] = []
    var accounts: [MoneyAccount] = []
    var categories: [BudgetCategory] = []
    var tags: [BudgetTag] = []
    var entries: [BudgetEntry] = []
    var selectedBookID: UUID? = nil

    static func initial() -> Self {
        var state = Self()
        _ = try? state.createBook(name: "個人用", shared: false)
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
        guard entry.amount > 0, entry.amount <= 999_999_999 else { throw BudgetError.invalidAmount }
        guard entry.date.timeIntervalSince1970.isFinite else { throw BudgetError.invalidDate }
        guard (entry.merchant ?? "").count <= 100, entry.memo.count <= 1000 else { throw BudgetError.textTooLong }
        if let previous {
            guard previous.id == entry.id, previous.kind == entry.kind, previous.bookID == entry.bookID,
                  previous.refundOfID == entry.refundOfID else { throw BudgetError.immutableKind }
            entry.createdAt = previous.createdAt
        }
        entry.date = Calendar.current.startOfDay(for: entry.date)
        let refunds = entries.filter { $0.kind == .refund && $0.refundOfID == entry.id }
        if !refunds.isEmpty {
            guard entry.kind == .expense else { throw BudgetError.refundConflict }
            var remaining = entry.amount
            for refund in refunds {
                guard Calendar.current.startOfDay(for: refund.date) >= entry.date,
                      refund.amount > 0, refund.amount <= remaining else { throw BudgetError.refundConflict }
                remaining -= refund.amount
            }
        }
        if entry.kind != .refund && entry.refundOfID != nil { throw BudgetError.invalidRefund }

        func validAccount(_ id: UUID?, oldID: UUID?) -> Bool {
            guard let id else { return false }
            return accounts.contains { $0.id == id && $0.bookID == entry.bookID && (!$0.isArchived || oldID == id) }
        }
        if entry.kind == .refund {
            guard let original = entries.first(where: { $0.id == entry.refundOfID && $0.kind == .expense && $0.bookID == entry.bookID }),
                  original.id != entry.id else { throw BudgetError.invalidRefund }
            guard entry.date >= Calendar.current.startOfDay(for: original.date) else { throw BudgetError.refundDate }
            // Subtract from the remaining balance rather than summing untrusted amounts.
            var remaining = original.amount
            for other in entries where other.kind == .refund && other.refundOfID == original.id && other.id != entry.id {
                guard other.amount > 0, other.amount <= remaining else { throw BudgetError.refundConflict }
                remaining -= other.amount
            }
            guard entry.amount <= remaining else { throw BudgetError.refundConflict }
            guard validAccount(entry.destinationID, oldID: previous?.destinationID) else { throw BudgetError.invalidAccount }
            entry.sourceID = nil
            entry.categoryID = original.categoryID
            entry.includedInTotals = original.includedInTotals
        } else if entry.kind == .transfer {
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
                entry.categoryID = categories.first { $0.bookID == entry.bookID && $0.kind == entry.kind && $0.isUncategorized && $0.parentID != nil }?.id
            }
            guard let category = categories.first(where: { $0.id == entry.categoryID && $0.bookID == entry.bookID && $0.kind == entry.kind }),
                  (isCategoryAvailable(category) || previous?.categoryID == category.id), category.parentID != nil else { throw BudgetError.invalidCategory }
        }
        guard entry.tagIDs.allSatisfy({ id in
            tags.contains { $0.id == id && $0.bookID == entry.bookID && (!$0.isArchived || previous?.tagIDs.contains(id) == true ||
                (entry.kind == .refund && previous == nil && entries.first(where: { $0.id == entry.refundOfID })?.tagIDs.contains(id) == true)) }
        }) else { throw BudgetError.invalidTag }
        return entry
    }
}

enum BudgetError: LocalizedError {
    case invalidDate, textTooLong, immutableKind, invalidRefund, refundDate, refundConflict
    case invalidBook, invalidAmount, invalidAccount, missingTransferAccount, sameAccount, invalidCategory, invalidTag, emptyName, duplicateName, protectedItem
    var errorDescription: String? {
        switch self {
        case .invalidBook: "家計簿が見つかりません。"
        case .invalidAmount: "金額は1〜999,999,999円の整数で入力してください。"
        case .invalidDate: "有効な日付を選択してください。"
        case .textTooLong: "お店・相手先は100文字、メモは1,000文字以内で入力してください。"
        case .immutableKind: "保存済みの種類・所属家計簿・元支出は変更できません。削除して再登録してください。"
        case .invalidRefund: "同じ家計簿の元の支出を確認してください。"
        case .refundDate: "返金日は元の支出日以降にしてください。"
        case .refundConflict: "返金合計が支出額を超えるか、返金日より後の支出日になっています。金額・日付を確認してください。"
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
            case .refund: if includeExcluded || entry.includedInTotals { result.expense -= entry.amount }
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


extension BudgetSnapshot {
    /// 同じ階層の中で並べる。旧データのorderがすべて0でも配列順を維持する。
    func orderedCategories(bookID: UUID, kind: EntryKind, parentID: UUID?) -> [BudgetCategory] {
        categories.enumerated().filter {
            $0.element.bookID == bookID && $0.element.kind == kind && $0.element.parentID == parentID
        }.sorted {
            $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order < $1.element.order
        }.map(\.element)
    }

    @discardableResult
    mutating func saveCategory(id: UUID? = nil, bookID: UUID, kind: EntryKind, name: String, parentID: UUID?) throws -> UUID {
        guard books.contains(where: { $0.id == bookID }) else { throw BudgetError.invalidBook }
        guard kind != .transfer && kind != .refund else { throw BudgetError.invalidCategory }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BudgetError.emptyName }
        let existing = id.flatMap { id in categories.first { $0.id == id } }
        if id != nil {
            guard let existing, existing.bookID == bookID, existing.kind == kind else { throw BudgetError.invalidCategory }
            guard !existing.isUncategorized else { throw BudgetError.protectedItem }
            // 編集では大小の階層は維持する。小カテゴリの所属変更のみ対応。
            guard (existing.parentID == nil) == (parentID == nil) else { throw BudgetError.invalidCategory }
        }
        if let parentID {
            guard let parent = categories.first(where: { $0.id == parentID }),
                  parent.id != id, parent.bookID == bookID, parent.kind == kind,
                  parent.parentID == nil, !parent.isUncategorized,
                  !parent.isArchived || existing?.parentID == parentID else { throw BudgetError.invalidCategory }
        }
        guard !categories.contains(where: {
            $0.id != id && $0.bookID == bookID && $0.kind == kind && $0.parentID == parentID && Self.categoryNameKey($0.name) == Self.categoryNameKey(name)
        }) else { throw BudgetError.duplicateName }
        if let index = categories.firstIndex(where: { $0.id == id }) {
            if categories[index].parentID != parentID {
                categories[index].order = (orderedCategories(bookID: bookID, kind: kind, parentID: parentID).last?.order ?? -1) + 1
            }
            categories[index].name = name
            categories[index].parentID = parentID
            return categories[index].id
        }
        let newCategory = BudgetCategory(bookID: bookID, name: name, kind: kind, parentID: parentID,
                                         order: (orderedCategories(bookID: bookID, kind: kind, parentID: parentID).last?.order ?? -1) + 1)
        categories.append(newCategory)
        return newCategory.id
    }

    mutating func setCategoryArchived(id: UUID, bookID: UUID, archived: Bool) throws {
        guard let index = categories.firstIndex(where: { $0.id == id && $0.bookID == bookID }) else { throw BudgetError.invalidCategory }
        guard !categories[index].isUncategorized else { throw BudgetError.protectedItem }
        // 子自身のアーカイブ状態には触れず、親の状態から利用可否を判定する。
        categories[index].isArchived = archived
    }

    mutating func reorderCategories(bookID: UUID, kind: EntryKind, parentID: UUID?, ids: [UUID]) throws {
        let siblings = orderedCategories(bookID: bookID, kind: kind, parentID: parentID)
        guard ids.count == siblings.count, Set(ids).count == ids.count, Set(ids) == Set(siblings.map(\.id)) else { throw BudgetError.invalidCategory }
        for (position, id) in ids.enumerated() {
            if let index = categories.firstIndex(where: { $0.id == id }) { categories[index].order = position }
        }
    }

    /// 常に現在の分類をたどるため、名称・所属変更後は過去取引にも即時反映する。
    func categoryAmounts(bookID: UUID, kind: EntryKind, entries: [BudgetEntry], parentID: UUID? = nil) -> [UUID: Int64] {
        var result: [UUID: Int64] = [:]
        for raw in entries where raw.bookID == bookID && kind != .transfer && kind != .refund {
            let entry = effectiveEntry(raw)
            guard (entry.kind == kind || (kind == .expense && entry.kind == .refund)), entry.includedInTotals else { continue }
            guard let category = categories.first(where: { $0.id == entry.categoryID && $0.bookID == bookID && $0.kind == kind }) else { continue }
            if let parentID {
                guard category.id == parentID || category.parentID == parentID else { continue }
                result[category.id, default: 0] += entry.kind == .refund ? -entry.amount : entry.amount
            } else { result[category.parentID ?? category.id, default: 0] += entry.kind == .refund ? -entry.amount : entry.amount }
        }
        return result
    }
}


struct BasicCategoryGroup: Identifiable {
    let name: String
    let children: [String]
    var id: String { name }
    static func groups(for kind: EntryKind) -> [Self] {
        switch kind {
        case .expense:
            return [
                Self(name: "食費", children: ["食料品", "外食", "カフェ", "その他"]),
                Self(name: "日用品", children: ["生活消耗品", "掃除・洗濯用品", "生活雑貨", "タバコ", "その他"]),
                Self(name: "住居費", children: ["家賃", "住宅ローン", "修繕・維持費", "その他"]),
                Self(name: "水道・光熱費", children: ["電気", "ガス", "水道", "その他"]),
                Self(name: "通信費", children: ["携帯電話", "インターネット", "郵便・配送", "その他"]),
                Self(name: "交通費", children: ["電車", "バス", "タクシー", "その他"]),
                Self(name: "自動車費", children: ["ガソリン", "駐車場・高速代", "車検・整備", "自動車税", "その他"]),
                Self(name: "衣服・美容", children: ["衣類", "靴・小物", "美容院", "化粧品", "その他"]),
                Self(name: "健康・医療", children: ["診療・治療", "薬", "健康用品", "その他"]),
                Self(name: "趣味・娯楽", children: ["ゲーム", "書籍", "映画・音楽", "旅行", "その他"]),
                Self(name: "交際費", children: ["会食", "贈り物", "冠婚葬祭", "その他"]),
                Self(name: "教育・子育て", children: ["学費", "習い事", "教材", "育児用品", "その他"]),
                Self(name: "保険", children: ["生命保険", "医療保険", "自動車保険", "その他"]),
                Self(name: "税金・社会保険", children: ["所得税・住民税", "年金", "健康保険料", "その他"]),
                Self(name: "その他", children: ["手数料", "寄付", "その他"])
            ]
        case .income:
            return [
                Self(name: "給与", children: ["給与", "賞与", "各種手当", "その他"]),
                Self(name: "事業・副業", children: ["事業収入", "副業報酬", "その他"]),
                Self(name: "年金・給付金", children: ["年金", "公的手当", "給付金", "その他"]),
                Self(name: "運用収入", children: ["預貯金利息", "配当金", "その他"]),
                Self(name: "臨時収入", children: ["お祝い・贈与", "お小遣い", "不用品売却", "その他"]),
                Self(name: "その他", children: ["その他"])
            ]
        case .transfer, .refund: return []
        }
    }
}

extension BudgetSnapshot {
    /// 再実行しても同じ場所に重複を作らず、既存の名称・順番・アーカイブ状態を維持する。
    mutating func addBasicCategories(bookID: UUID) throws {
        guard books.contains(where: { $0.id == bookID }) else { throw BudgetError.invalidBook }
        for kind in [EntryKind.expense, .income] {
            for group in BasicCategoryGroup.groups(for: kind) {
                let parentID: UUID
                if let existing = categories.first(where: { $0.bookID == bookID && $0.kind == kind && $0.parentID == nil && Self.categoryNameKey($0.name) == Self.categoryNameKey(group.name) }) {
                    guard !existing.isArchived, !existing.isUncategorized else { continue }
                    parentID = existing.id
                } else { parentID = try saveCategory(bookID: bookID, kind: kind, name: group.name, parentID: nil) }
                for child in group.children {
                    if !categories.contains(where: { $0.bookID == bookID && $0.kind == kind && $0.parentID == parentID && Self.categoryNameKey($0.name) == Self.categoryNameKey(child) }) {
                        try saveCategory(bookID: bookID, kind: kind, name: child, parentID: parentID)
                    }
                }
            }
            ensureUncategorized(bookID: bookID, kind: kind)
        }
    }
}


extension BudgetSnapshot {
    func orderedAccounts(bookID: UUID) -> [MoneyAccount] {
        accounts.enumerated().filter { $0.element.bookID == bookID }.sorted {
            let left = $0.element.order ?? 0, right = $1.element.order ?? 0
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    @discardableResult
    mutating func saveTag(id: UUID? = nil, bookID: UUID, name: String) throws -> UUID {
        guard books.contains(where: { $0.id == bookID }) else { throw BudgetError.invalidBook }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BudgetError.emptyName }
        if let id { guard tags.contains(where: { $0.id == id && $0.bookID == bookID }) else { throw BudgetError.invalidTag } }
        guard !tags.contains(where: { $0.bookID == bookID && $0.name == name && $0.id != id }) else { throw BudgetError.duplicateName }
        if let index = tags.firstIndex(where: { $0.id == id }) { tags[index].name = name; return tags[index].id }
        let tag = BudgetTag(bookID: bookID, name: name)
        tags.append(tag)
        return tag.id
    }
    @discardableResult
    mutating func saveAccount(id: UUID? = nil, bookID: UUID, name: String) throws -> UUID {
        guard books.contains(where: { $0.id == bookID }) else { throw BudgetError.invalidBook }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BudgetError.emptyName }
        if let id {
            guard let index = accounts.firstIndex(where: { $0.id == id && $0.bookID == bookID }) else { throw BudgetError.invalidAccount }
            guard !accounts[index].isWallet else { throw BudgetError.protectedItem }
            accounts[index].name = name
            return id
        }
        // 一般項目の同名制約は未確定のため、従来どおり同名は許可。
        let account = MoneyAccount(bookID: bookID, name: name, order: (orderedAccounts(bookID: bookID).last?.order ?? 0) + 1)
        accounts.append(account)
        return account.id
    }
    mutating func setTagArchived(id: UUID, bookID: UUID, archived: Bool) throws {
        guard let index = tags.firstIndex(where: { $0.id == id && $0.bookID == bookID }) else { throw BudgetError.invalidTag }
        tags[index].isArchived = archived
    }
    mutating func setAccountArchived(id: UUID, bookID: UUID, archived: Bool) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id && $0.bookID == bookID }) else { throw BudgetError.invalidAccount }
        guard !accounts[index].isWallet else { throw BudgetError.protectedItem }
        accounts[index].isArchived = archived
    }
    mutating func reorderAccounts(bookID: UUID, ids: [UUID]) throws {
        let items = orderedAccounts(bookID: bookID)
        guard Set(ids).count == ids.count, ids.count == items.count, Set(ids) == Set(items.map(\.id)) else { throw BudgetError.invalidAccount }
        for (position, id) in ids.enumerated() {
            if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index].order = position }
        }
    }
}

extension BudgetSnapshot {
    /// 外部ファイルの復元前に、参照切れ・家計簿越境・標準項目の欠落を検証する。
    func validateBackup() throws {
        guard [1, 2].contains(schemaVersion) else { throw BackupError.unsupportedVersion }
        func valid(_ condition: Bool) throws { if !condition { throw BackupError.invalidData } }
        func unique(_ ids: [UUID]) -> Bool { Set(ids).count == ids.count }
        func named(_ name: String) -> Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 10_000 }
        try valid(!books.isEmpty && unique(books.map(\.id)) && unique(accounts.map(\.id)) && unique(categories.map(\.id)) && unique(tags.map(\.id)) && unique(entries.map(\.id)))
        let bookIDs = Set(books.map(\.id))
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let tagMap = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        let accountGroups = Dictionary(grouping: accounts, by: \.bookID)
        let categoryGroups = Dictionary(grouping: categories, by: \.bookID)
        let tagGroups = Dictionary(grouping: tags, by: \.bookID)
        try valid(selectedBookID == nil || bookIDs.contains(selectedBookID!))
        for book in books {
            try valid(named(book.name))
            try valid((accountGroups[book.id] ?? []).filter { $0.isWallet }.count == 1)
            for kind in [EntryKind.expense, .income] {
                let defaults = (categoryGroups[book.id] ?? []).filter { $0.kind == kind && $0.isUncategorized }
                if schemaVersion == 1 {
                    try valid(defaults.count == 1 && defaults[0].name == "未分類" && defaults[0].parentID == nil && !defaults[0].isArchived)
                } else {
                    try valid(defaults.count == 2 && defaults.allSatisfy { $0.name == "未分類" && !$0.isArchived })
                    let roots = defaults.filter { $0.parentID == nil }
                    try valid(roots.count == 1 && defaults.filter { $0.parentID == roots.first?.id }.count == 1)
                }
            }
            try valid(book.hiddenTagIDs.isSubset(of: Set((tagGroups[book.id] ?? []).map(\.id))))
        }
        for account in accounts {
            try valid(bookIDs.contains(account.bookID) && named(account.name))
            if account.isWallet { try valid(account.name == "お財布" && !account.isArchived) }
        }
        var categoryNames: Set<String> = []
        for category in categories {
            try valid(bookIDs.contains(category.bookID) && category.kind != .transfer && category.kind != .refund && named(category.name))
            let key = "\(category.bookID)|\(category.kind.rawValue)|\(category.parentID?.uuidString ?? "root")|\(category.name)"
            // Legacy files could contain case-only duplicates. Do not rename or merge them on migration.
            try valid(categoryNames.insert(key).inserted)
            if let parentID = category.parentID {
                guard let parent = categoryMap[parentID] else { throw BackupError.invalidData }
                try valid(parent.bookID == category.bookID && parent.kind == category.kind && parent.parentID == nil &&
                          (!parent.isUncategorized || (schemaVersion == 2 && category.isUncategorized)))
            }
        }
        var tagNames: Set<String> = []
        for tag in tags {
            try valid(bookIDs.contains(tag.bookID) && named(tag.name))
            try valid(tagNames.insert("\(tag.bookID)|\(tag.name)").inserted)
        }
        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var refundedAmounts: [UUID: Int64] = [:]
        for entry in entries {
            try valid(entry.createdAt?.timeIntervalSince1970.isFinite ?? true)
            try valid(bookIDs.contains(entry.bookID) && entry.amount > 0 && entry.amount <= 999_999_999_999 && entry.date.timeIntervalSince1970.isFinite)
            for id in [entry.sourceID, entry.destinationID].compactMap({ $0 }) { try valid(accountMap[id]?.bookID == entry.bookID) }
            try valid(entry.tagIDs.allSatisfy { tagMap[$0]?.bookID == entry.bookID })
            if entry.kind == .refund {
                guard let originalID = entry.refundOfID, let original = entryMap[originalID] else { throw BackupError.invalidData }
                try valid(original.kind == .expense && original.bookID == entry.bookID && entry.sourceID == nil && entry.destinationID != nil)
                try valid(Calendar.current.startOfDay(for: entry.date) >= Calendar.current.startOfDay(for: original.date))
                try valid(entry.categoryID == original.categoryID && entry.includedInTotals == original.includedInTotals)
                let already = refundedAmounts[originalID, default: 0]
                try valid(entry.amount <= original.amount - already)
                refundedAmounts[originalID] = already + entry.amount
            } else if entry.kind == .transfer {
                try valid(entry.refundOfID == nil)
                try valid(entry.categoryID == nil && !entry.includedInTotals && (entry.sourceID != nil || entry.destinationID != nil) && (entry.sourceID == nil || entry.sourceID != entry.destinationID))
            } else {
                try valid(entry.refundOfID == nil)
                try valid(entry.kind == .expense ? entry.sourceID != nil && entry.destinationID == nil : entry.destinationID != nil && entry.sourceID == nil)
                guard let id = entry.categoryID, let category = categoryMap[id] else { throw BackupError.invalidData }
                try valid(category.bookID == entry.bookID && category.kind == entry.kind && (schemaVersion == 1 || category.parentID != nil))
            }
        }
    }
}


extension BudgetSnapshot {
    func effectiveEntry(_ entry: BudgetEntry) -> BudgetEntry {
        guard entry.kind == .refund,
              let original = entries.first(where: { $0.id == entry.refundOfID && $0.bookID == entry.bookID && $0.kind == .expense }) else { return entry }
        var value = entry
        value.categoryID = original.categoryID
        value.includedInTotals = original.includedInTotals
        return value
    }
    /// Stable ties preserve the order in legacy files without createdAt.
    func orderedEntries(bookID: UUID) -> [BudgetEntry] {
        entries.enumerated().filter { $0.element.bookID == bookID }.sorted {
            let left = Calendar.current.startOfDay(for: $0.element.date)
            let right = Calendar.current.startOfDay(for: $1.element.date)
            if left != right { return left > right }
            let a = $0.element.createdAt ?? .distantPast, b = $1.element.createdAt ?? .distantPast
            return a == b ? $0.offset < $1.offset : a > b
        }.map { effectiveEntry($0.element) }
    }
    func refunds(for id: UUID) -> [BudgetEntry] {
        guard let original = entries.first(where: { $0.id == id && $0.kind == .expense }) else { return [] }
        return orderedEntries(bookID: original.bookID).filter { $0.kind == .refund && $0.refundOfID == id }
    }
    func refundedAmount(for id: UUID) -> Int64 { refunds(for: id).reduce(0) { $0 + $1.amount } }
    mutating func saveTransaction(_ input: BudgetEntry, now: Date = Date()) throws {
        let previous = entries.first { $0.id == input.id }
        var entry = try validated(input, previous: previous)
        if previous == nil { entry.createdAt = now }
        var next = self
        if let index = next.entries.firstIndex(where: { $0.id == entry.id }) { next.entries[index] = entry }
        else { next.entries.append(entry) }
        // Store dependent fields together with the original in one repository write.
        if entry.kind == .expense {
            for index in next.entries.indices where next.entries[index].kind == .refund && next.entries[index].refundOfID == entry.id {
                next.entries[index].categoryID = entry.categoryID
                next.entries[index].includedInTotals = entry.includedInTotals
            }
        }
        self = next
    }
    mutating func deleteTransaction(_ id: UUID) {
        entries.removeAll { $0.id == id || ($0.kind == .refund && $0.refundOfID == id) }
    }
}


extension BudgetSnapshot {
    static func categoryNameKey(_ name: String) -> String {
        // Fold Latin A-Z in ASCII/full-width forms; preserve width, internal spaces and other Unicode distinctions.
        String(String.UnicodeScalarView(name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map {
            ((65...90).contains($0.value) || (0xFF21...0xFF3A).contains($0.value)) ? UnicodeScalar($0.value + 32)! : $0
        }))
    }
    @discardableResult
    mutating func createBook(name: String, shared: Bool) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BudgetError.emptyName }
        guard !books.contains(where: { Self.categoryNameKey($0.name) == Self.categoryNameKey(name) }) else { throw BudgetError.duplicateName }
        var next = self
        let book = HouseholdBook(name: name, isShared: shared)
        next.books.append(book)
        next.accounts.append(MoneyAccount(bookID: book.id, name: "お財布", isWallet: true))
        try next.addBasicCategories(bookID: book.id)
        next.selectedBookID = book.id
        self = next
        return book.id
    }
    private mutating func ensureUncategorized(bookID: UUID, kind: EntryKind) {
        let parent: BudgetCategory
        if let existing = categories.first(where: { $0.bookID == bookID && $0.kind == kind && $0.isUncategorized && $0.parentID == nil }) { parent = existing }
        else {
            parent = BudgetCategory(bookID: bookID, name: "未分類", kind: kind, isUncategorized: true,
                                    order: (orderedCategories(bookID: bookID, kind: kind, parentID: nil).last?.order ?? -1) + 1)
            categories.append(parent)
        }
        if !categories.contains(where: { $0.parentID == parent.id && $0.isUncategorized }) {
            categories.append(BudgetCategory(bookID: bookID, name: "未分類", kind: kind, parentID: parent.id, isUncategorized: true))
        }
    }
    /// Upgrade a validated v1 snapshot without changing existing IDs, names, order or amounts.
    func migratedCategoryHierarchy() throws -> BudgetSnapshot {
        guard schemaVersion == 1 else {
            guard schemaVersion == 2 else { throw BackupError.unsupportedVersion }
            return self
        }
        try validateBackup()
        var next = self
        for book in books {
            for kind in [EntryKind.expense, .income] { next.ensureUncategorized(bookID: book.id, kind: kind) }
        }
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let usedRoots = Set(entries.compactMap { entry -> UUID? in
            guard let id = entry.categoryID, categoryMap[id]?.parentID == nil else { return nil }
            return id
        })
        var replacements: [UUID: UUID] = [:]
        for parent in categories where usedRoots.contains(parent.id) {
            if parent.isUncategorized {
                replacements[parent.id] = next.categories.first { $0.parentID == parent.id && $0.isUncategorized }!.id
            } else {
                let base = "直接登録（移行分）"
                var name = base, suffix = 2
                while next.categories.contains(where: { $0.parentID == parent.id && Self.categoryNameKey($0.name) == Self.categoryNameKey(name) }) {
                    name = "\(base) \(suffix)"; suffix += 1
                }
                let child = BudgetCategory(bookID: parent.bookID, name: name, kind: parent.kind, parentID: parent.id,
                                           order: (next.orderedCategories(bookID: parent.bookID, kind: parent.kind, parentID: parent.id).last?.order ?? -1) + 1)
                next.categories.append(child); replacements[parent.id] = child.id
            }
        }
        for index in next.entries.indices {
            if let id = next.entries[index].categoryID, let childID = replacements[id] { next.entries[index].categoryID = childID }
        }
        next.schemaVersion = 2
        try next.validateBackup()
        return next
    }
}
