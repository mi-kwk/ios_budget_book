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



// カテゴリ管理の回帰テスト。過去の取引の参照を保ったまま分類を変更する。
var catalog = BudgetSnapshot.initial()
let catalogBook = catalog.books[0].id
let anotherBook = catalog.books[1].id
let sourceRoot = try catalog.saveCategory(bookID: catalogBook, kind: .expense, name: "検証A", parentID: nil)
let destinationRoot = try catalog.saveCategory(bookID: catalogBook, kind: .expense, name: "検証B", parentID: nil)
let itemID = try catalog.saveCategory(bookID: catalogBook, kind: .expense, name: "商品", parentID: sourceRoot)
let historical = BudgetEntry(bookID: catalogBook, kind: .expense, amount: 2500, date: Date(), categoryID: itemID, sourceID: catalog.accounts.first { $0.bookID == catalogBook }!.id)
catalog.entries = [historical]
try catalog.saveCategory(id: itemID, bookID: catalogBook, kind: .expense, name: "  新名称  ", parentID: destinationRoot)
expect(catalog.entries == [historical], "カテゴリ編集は過去取引のID・金額・カテゴリ参照を変えない")
expect(catalog.categories.first { $0.id == itemID }?.name == "新名称", "名称の前後空白を除去")
let newAmounts = catalog.categoryAmounts(bookID: catalogBook, kind: .expense, entries: catalog.entries)
expect(newAmounts[sourceRoot] == nil && newAmounts[destinationRoot] == 2500, "過去支出が新しい大カテゴリに集計される")
expect(catalog.categoryAmounts(bookID: catalogBook, kind: .expense, entries: catalog.entries, parentID: destinationRoot)[itemID] == 2500, "小カテゴリの内訳を維持")
let conflictID = try catalog.saveCategory(bookID: catalogBook, kind: .expense, name: "重複", parentID: destinationRoot)
try catalog.setCategoryArchived(id: conflictID, bookID: catalogBook, archived: true)
let beforeCollision = catalog
rejects("移動先でアーカイブ済みを含む重複を拒否") { try catalog.saveCategory(id: itemID, bookID: catalogBook, kind: .expense, name: "重複", parentID: destinationRoot) }
expect(catalog == beforeCollision, "重複エラーでデータを変更しない")
_ = try catalog.saveCategory(bookID: catalogBook, kind: .expense, name: "重複", parentID: sourceRoot)
expect(true, "別親で同名の小カテゴリを許可")
rejects("空の名称を拒否") { try catalog.saveCategory(id: itemID, bookID: catalogBook, kind: .expense, name: "  ", parentID: destinationRoot) }
let foreignParent = catalog.categories.first { $0.bookID == anotherBook && !$0.isUncategorized && $0.parentID == nil && $0.kind == .expense }!.id
rejects("他家計簿への所属変更を拒否") { try catalog.saveCategory(id: itemID, bookID: catalogBook, kind: .expense, name: "新名称", parentID: foreignParent) }
let incomeParent = catalog.categories.first { $0.bookID == catalogBook && $0.kind == .income && !$0.isUncategorized && $0.parentID == nil }!.id
rejects("収入用の親への移動を拒否") { try catalog.saveCategory(id: itemID, bookID: catalogBook, kind: .expense, name: "新名称", parentID: incomeParent) }
rejects("小カテゴリを親にする三階層化を拒否") { try catalog.saveCategory(bookID: catalogBook, kind: .expense, name: "三階層", parentID: itemID) }
rejects("大カテゴリの自己参照を拒否") { try catalog.saveCategory(id: sourceRoot, bookID: catalogBook, kind: .expense, name: "検証A", parentID: sourceRoot) }
let standard = catalog.categories.first { $0.bookID == catalogBook && $0.kind == .expense && $0.isUncategorized }!
rejects("未分類の変更を保護") { try catalog.saveCategory(id: standard.id, bookID: catalogBook, kind: .expense, name: "変更", parentID: nil) }
rejects("未分類のアーカイブを保護") { try catalog.setCategoryArchived(id: standard.id, bookID: catalogBook, archived: true) }
let individuallyArchived = try catalog.saveCategory(bookID: catalogBook, kind: .expense, name: "個別", parentID: destinationRoot)
try catalog.setCategoryArchived(id: individuallyArchived, bookID: catalogBook, archived: true)
try catalog.setCategoryArchived(id: destinationRoot, bookID: catalogBook, archived: true)
expect(!catalog.isCategoryAvailable(catalog.categories.first { $0.id == itemID }!), "親アーカイブで通常の子を選択不可")
expect(catalog.categoryAmounts(bookID: catalogBook, kind: .expense, entries: catalog.entries)[destinationRoot] == 2500, "アーカイブ後も過去集計を維持")
try catalog.setCategoryArchived(id: destinationRoot, bookID: catalogBook, archived: false)
expect(catalog.isCategoryAvailable(catalog.categories.first { $0.id == itemID }!), "親復元で通常の子を復活")
expect(!catalog.isCategoryAvailable(catalog.categories.first { $0.id == individuallyArchived }!), "親復元は個別アーカイブを解除しない")
let reversedIDs = Array(catalog.orderedCategories(bookID: catalogBook, kind: .expense, parentID: destinationRoot).map(\.id).reversed())
try catalog.reorderCategories(bookID: catalogBook, kind: .expense, parentID: destinationRoot, ids: reversedIDs)
expect(catalog.orderedCategories(bookID: catalogBook, kind: .expense, parentID: destinationRoot).map(\.id) == reversedIDs, "同じ親の小カテゴリの並べ替え")
rejects("並べ替えで別親のカテゴリを混在させない") { try catalog.reorderCategories(bookID: catalogBook, kind: .expense, parentID: destinationRoot, ids: [sourceRoot]) }
let original = catalog
try catalog.addBasicCategories(bookID: catalogBook)
expect(catalog == original, "基本セットの再追加は既存項目・順序を変更しない")
let archiveRoot = catalog.categories.first { $0.bookID == catalogBook && $0.name == "食費" && $0.parentID == nil }!
try catalog.setCategoryArchived(id: archiveRoot.id, bookID: catalogBook, archived: true)
try catalog.addBasicCategories(bookID: catalogBook)
expect(catalog.categories.first { $0.id == archiveRoot.id }!.isArchived, "基本セット追加でアーカイブ状態を勝手に復元しない")
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let repository = JSONBudgetRepository(url: folder.appendingPathComponent("state.json"))
try repository.save(catalog)
let reloaded = try repository.load()!
expect(reloaded == catalog, "名称・所属・並び順・アーカイブと過去取引を保存して再読込")
expect(reloaded.orderedCategories(bookID: catalogBook, kind: .expense, parentID: destinationRoot).map(\.id) == reversedIDs, "再起動後も小カテゴリの表示順を維持")
print("Passed \(checks) domain checks")
