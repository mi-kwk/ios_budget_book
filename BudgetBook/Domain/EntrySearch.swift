import Foundation

enum EntrySearchPeriod: String, CaseIterable, Identifiable {
    case month, custom, all
    var id: String { rawValue }
    var title: String { switch self { case .month: "月指定"; case .custom: "期間指定"; case .all: "全期間" } }
}
enum EntrySearchInclusion: String, CaseIterable, Identifiable {
    case all, included, excluded
    var id: String { rawValue }
    var title: String { switch self { case .all: "両方"; case .included: "対象内"; case .excluded: "対象外" } }
}

/// Search state is session-only and keeps a captured month, independent of display-month navigation.
struct EntrySearchQuery: Equatable {
    var period = EntrySearchPeriod.month
    var month: Date
    var startDate: Date
    var endDate: Date
    var kinds: Set<EntryKind> = []
    var categoryIDs: Set<UUID> = []
    var tagIDs: Set<UUID> = []
    var accountIDs: Set<UUID> = []
    var matchAllTags = true
    var inclusion = EntrySearchInclusion.all
    var keyword = ""
    init(month: Date, calendar: Calendar = .current) {
        let first = BudgetCalendar.startOfMonth(month, calendar: calendar)
        self.month = first; startDate = first
        let next = calendar.date(byAdding: .month, value: 1, to: first) ?? first
        endDate = calendar.date(byAdding: .day, value: -1, to: next) ?? first
    }
    mutating func clearBookSelections() { categoryIDs = []; tagIDs = []; accountIDs = [] }
    func hasValidPeriod(calendar: Calendar = .current) -> Bool {
        period != .custom || calendar.startOfDay(for: startDate) <= calendar.startOfDay(for: endDate)
    }
    static func normalizedKeyword(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    var keywordTokens: [String] { keyword.split(whereSeparator: { $0.isWhitespace }).map { Self.normalizedKeyword(String($0)) } }
}

extension BudgetSnapshot {
    func searchEntries(bookID: UUID, query: EntrySearchQuery, calendar: Calendar = .current) -> [BudgetEntry] {
        guard query.hasValidPeriod(calendar: calendar) else { return [] }
        let tokens = query.keywordTokens
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let first = calendar.startOfDay(for: query.startDate), last = calendar.startOfDay(for: query.endDate)
        var seen: Set<UUID> = []
        return orderedEntries(bookID: bookID).filter { entry in
            switch query.period {
            case .month: guard calendar.isDate(entry.date, equalTo: query.month, toGranularity: .month) else { return false }
            case .custom:
                let day = calendar.startOfDay(for: entry.date)
                guard day >= first && day <= last else { return false }
            case .all: break
            }
            guard query.kinds.isEmpty || query.kinds.contains(entry.kind) else { return false }
            switch query.inclusion {
            case .all: break
            case .included: guard entry.includedInTotals else { return false }
            case .excluded: guard !entry.includedInTotals else { return false }
            }
            if !query.categoryIDs.isEmpty {
                guard let id = entry.categoryID else { return false }
                let matches = query.categoryIDs.contains(id) || categoryMap[id]?.parentID.map { query.categoryIDs.contains($0) } == true
                guard matches else { return false }
            }
            if !query.tagIDs.isEmpty {
                let matches = query.matchAllTags ? query.tagIDs.isSubset(of: entry.tagIDs) : !query.tagIDs.isDisjoint(with: entry.tagIDs)
                guard matches else { return false }
            }
            if !query.accountIDs.isEmpty {
                let candidates: [UUID?]
                switch entry.kind {
                case .expense: candidates = [entry.sourceID]
                case .income, .refund: candidates = [entry.destinationID]
                case .transfer: candidates = [entry.sourceID, entry.destinationID]
                }
                guard candidates.compactMap({ $0 }).contains(where: { query.accountIDs.contains($0) }) else { return false }
            }
            if !tokens.isEmpty {
                let merchant = EntrySearchQuery.normalizedKeyword(entry.merchant ?? "")
                let memo = EntrySearchQuery.normalizedKeyword(entry.memo)
                guard tokens.allSatisfy({ merchant.contains($0) || memo.contains($0) }) else { return false }
            }
            return seen.insert(entry.id).inserted
        }
    }
}
