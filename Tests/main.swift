import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
func rejects(_ message: String, _ work: () throws -> Void) {
    do { try work(); fatalError(message) } catch { checks += 1 }
}
var state = BudgetSnapshot.initial()
let book = state.books[0].id
let otherBook = state.books[1].id
let wallet = state.accounts.first { $0.bookID == book }!.id
let otherWallet = state.accounts.first { $0.bookID == otherBook }!.id
let tagA = BudgetTag(bookID: book, name: "旅行")
let tagB = BudgetTag(bookID: book, name: "家族")
state.tags = [tagA, tagB]
let expense = try state.validated(BudgetEntry(bookID: book, kind: .expense, amount: 1000, date: Date(), sourceID: wallet, tagIDs: [tagA.id, tagB.id]))
expect(expense.categoryID != nil, "未分類で補完する")
let excluded = try state.validated(BudgetEntry(bookID: book, kind: .expense, amount: 500, date: Date(), sourceID: wallet, tagIDs: [tagA.id], includedInTotals: false))
let income = try state.validated(BudgetEntry(bookID: book, kind: .income, amount: 3000, date: Date(), destinationID: wallet))
let transfer = try state.validated(BudgetEntry(bookID: book, kind: .transfer, amount: 800, date: Date(), sourceID: wallet, tagIDs: [tagA.id]))
expect(!transfer.includedInTotals && transfer.categoryID == nil, "振替にカテゴリや通常集計を付けない")
let entries = [expense, excluded, income, transfer]
let normal = BudgetSummary.totals(entries)
expect(normal.income == 3000 && normal.expense == 1000 && normal.difference == 2000 && normal.transfer == 0, "通常集計はOFF・振替を除外する")
let tagEntries = BudgetSummary.matchingTags(entries, tags: [tagA.id, tagB.id], matchAll: false)
expect(tagEntries.count == 3, "OR検索で同じ取引を二重計上しない")
let tagged = BudgetSummary.totals(tagEntries, includeExcluded: true)
expect(tagged.expense == 1500 && tagged.transfer == 800, "タグ集計はOFFも含み、振替を分離する")
expect(BudgetSummary.matchingTags(entries, tags: [tagA.id, tagB.id], matchAll: true).count == 1, "AND検索")
rejects("家計簿をまたぐ入出金元を禁止") { _ = try state.validated(BudgetEntry(bookID: book, kind: .expense, amount: 10, date: Date(), sourceID: otherWallet)) }
rejects("ゼロ円を禁止") { _ = try state.validated(BudgetEntry(bookID: book, kind: .expense, amount: 0, date: Date(), sourceID: wallet)) }
rejects("振替の両側未指定を禁止") { _ = try state.validated(BudgetEntry(bookID: book, kind: .transfer, amount: 10, date: Date())) }
rejects("振替の同一先を禁止") { _ = try state.validated(BudgetEntry(bookID: book, kind: .transfer, amount: 10, date: Date(), sourceID: wallet, destinationID: wallet)) }
let parent = BudgetCategory(bookID: book, name: "食費", kind: .expense, isArchived: true)
let child = BudgetCategory(bookID: book, name: "昼食", kind: .expense, parentID: parent.id)
state.categories += [parent, child]
expect(!state.isCategoryAvailable(child), "親のアーカイブ中は子を新規選択できない")
state.categories[state.categories.firstIndex { $0.id == parent.id }!].isArchived = false
expect(state.isCategoryAvailable(child), "親復元で子が利用可能になる")
state.categories[state.categories.firstIndex { $0.id == child.id }!].isArchived = true
expect(!state.isCategoryAvailable(state.categories.first { $0.id == child.id }!), "子自身のアーカイブを維持")
state.entries = entries
let data = try JSONEncoder().encode(state)
let decoded = try JSONDecoder().decode(BudgetSnapshot.self, from: data)
expect(decoded == state, "全モデル・関連・表示設定の往復")
print("Passed \(checks) domain checks")
