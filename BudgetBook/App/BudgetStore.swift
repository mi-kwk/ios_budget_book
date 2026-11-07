import Foundation
import SwiftUI

@MainActor
final class BudgetStore: ObservableObject {
    @Published private(set) var state: BudgetSnapshot
    @Published var errorMessage: String?
    private let repository: any BudgetRepository
    private(set) var canWrite = true

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
    }
    var bookID: UUID? { state.selectedBookID }
    var currentBook: HouseholdBook? { state.books.first { $0.id == bookID } }
    var accounts: [MoneyAccount] { state.accounts.filter { $0.bookID == bookID } }
    var categories: [BudgetCategory] { state.categories.filter { $0.bookID == bookID }.sorted { $0.order < $1.order } }
    var tags: [BudgetTag] { state.tags.filter { $0.bookID == bookID } }
    var entries: [BudgetEntry] { state.entries.filter { $0.bookID == bookID }.sorted { $0.date > $1.date } }
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
            try repository.save(next)
            state = next
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func selectBook(_ id: UUID) { update { $0.selectedBookID = id } }
    func saveEntry(_ entry: BudgetEntry) -> Bool {
        update { snapshot in
            let old = snapshot.entries.first { $0.id == entry.id }
            let validated = try snapshot.validated(entry, previous: old)
            if let index = snapshot.entries.firstIndex(where: { $0.id == entry.id }) { snapshot.entries[index] = validated }
            else { snapshot.entries.append(validated) }
        }
    }
    func deleteEntry(_ id: UUID) { update { $0.entries.removeAll { $0.id == id } } }
    func addBook(name: String, shared: Bool) {
        update { snapshot in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw BudgetError.emptyName }
            let book = HouseholdBook(name: name, isShared: shared)
            snapshot.books.append(book)
            snapshot.accounts.append(MoneyAccount(bookID: book.id, name: "お財布", isWallet: true))
            for kind in [EntryKind.expense, .income] {
                snapshot.categories.append(BudgetCategory(bookID: book.id, name: "未分類", kind: kind, isUncategorized: true))
            }
            try snapshot.addBasicCategories(bookID: book.id)
            snapshot.selectedBookID = book.id
        }
    }
    func addMaster(name: String, type: MasterType, kind: EntryKind = .expense, parentID: UUID? = nil) {
        guard let bookID else { return }
        update { snapshot in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw BudgetError.emptyName }
            switch type {
            case .category:
                try snapshot.saveCategory(bookID: bookID, kind: kind, name: name, parentID: parentID)
            case .tag:
                guard !snapshot.tags.contains(where: { $0.bookID == bookID && $0.name == name }) else { throw BudgetError.duplicateName }
                snapshot.tags.append(BudgetTag(bookID: bookID, name: name))
            case .account:
                snapshot.accounts.append(MoneyAccount(bookID: bookID, name: name))
            }
        }
    }
    func toggleArchive(_ id: UUID, type: MasterType) {
        update { snapshot in
            switch type {
            case .category:
                guard let category = snapshot.categories.first(where: { $0.id == id && $0.bookID == self.bookID }) else { throw BudgetError.invalidCategory }
                try snapshot.setCategoryArchived(id: id, bookID: category.bookID, archived: !category.isArchived)
            case .tag:
                guard let index = snapshot.tags.firstIndex(where: { $0.id == id }) else { return }
                snapshot.tags[index].isArchived.toggle()
            case .account:
                guard let index = snapshot.accounts.firstIndex(where: { $0.id == id }), !snapshot.accounts[index].isWallet else { throw BudgetError.protectedItem }
                snapshot.accounts[index].isArchived.toggle()
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

}

enum MasterType: String, Identifiable { case category = "カテゴリ", tag = "タグ", account = "入出金元"; var id: String { rawValue } }
