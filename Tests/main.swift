import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
func rejects(_ message: String, _ work: () throws -> Void) {
    do { try work(); fatalError(message) } catch { checks += 1 }
}
func testSnapshot() -> BudgetSnapshot {
    var snapshot = BudgetSnapshot.initial()
    let first = snapshot.selectedBookID
    try! snapshot.createBook(name: "共有用", shared: true)
    snapshot.selectedBookID = first
    return snapshot
}
var state = testSnapshot()
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
var catalog = testSnapshot()
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



// タグ・入出金元の関連保護と旧形式互換性。
var masters = testSnapshot()
let masterBook = masters.books[0].id
let foreignBook = masters.books[1].id
let masterWallet = masters.accounts.first { $0.bookID == masterBook && $0.isWallet }!.id
let bank = try masters.saveAccount(bookID: masterBook, name: "銀行")
let card = try masters.saveAccount(bookID: masterBook, name: "カード")
let travel = try masters.saveTag(bookID: masterBook, name: "旅行")
let archivedTravel = try masters.saveTag(bookID: masterBook, name: "過去タグ")
masters.books[0].hiddenTagIDs = [travel]
let taggedEntry = try masters.validated(BudgetEntry(bookID: masterBook, kind: .expense, amount: 900, date: Date(), sourceID: bank, tagIDs: [travel], includedInTotals: false))
masters.entries = [taggedEntry]
try masters.saveTag(id: travel, bookID: masterBook, name: "  旅費  ")
expect(masters.tags.first { $0.id == travel }?.name == "旅費", "タグ名称の前後空白を除去")
expect(masters.entries == [taggedEntry] && masters.books[0].hiddenTagIDs == [travel], "タグ名称変更で取引関連・表示設定を維持")
expect(BudgetSummary.matchingTags(masters.entries, tags: [travel], matchAll: true).count == 1, "改名後もIDで検索する")
try masters.setTagArchived(id: archivedTravel, bookID: masterBook, archived: true)
let beforeTagFailure = masters
rejects("アーカイブ済みと同名タグの新規作成を禁止") { try masters.saveTag(bookID: masterBook, name: "過去タグ") }
rejects("アーカイブ済みと同名への名称変更を禁止") { try masters.saveTag(id: travel, bookID: masterBook, name: "過去タグ") }
expect(masters == beforeTagFailure, "タグ重複エラーで元データを維持")
try masters.setTagArchived(id: travel, bookID: masterBook, archived: true)
expect(masters.entries[0].tagIDs.contains(travel), "タグアーカイブで関連を残す")
rejects("アーカイブ済みタグを新規取引へ付与しない") { _ = try masters.validated(BudgetEntry(bookID: masterBook, kind: .expense, amount: 20, date: Date(), sourceID: bank, tagIDs: [travel])) }
_ = try masters.validated(taggedEntry, previous: taggedEntry)
expect(true, "編集時に元のアーカイブ済みタグを保持できる")
try masters.setTagArchived(id: travel, bookID: masterBook, archived: false)
expect(masters.tags.first { $0.id == travel }?.isArchived == false && masters.tags.count == 2, "復元時は元IDを再利用して二重作成しない")
_ = try masters.saveTag(bookID: foreignBook, name: "旅費")
expect(true, "別家計簿で同名タグを許可")
rejects("タグ名称変更で家計簿越境を拒否") { try masters.saveTag(id: travel, bookID: foreignBook, name: "変更") }
rejects("タグの空名を拒否") { try masters.saveTag(bookID: masterBook, name: "  ") }
try masters.saveAccount(id: bank, bookID: masterBook, name: "生活口座")
expect(masters.accounts.first { $0.id == bank }?.name == "生活口座" && masters.entries == [taggedEntry], "入出金元改名で過去取引ID・金額を保持")
let beforeWalletFailure = masters
rejects("標準お財布の名称変更を禁止") { try masters.saveAccount(id: masterWallet, bookID: masterBook, name: "変更") }
rejects("標準お財布のアーカイブを禁止") { try masters.setAccountArchived(id: masterWallet, bookID: masterBook, archived: true) }
expect(masters == beforeWalletFailure, "標準お財布の保護に失敗しても元データを維持")
rejects("入出金元の空名を拒否") { try masters.saveAccount(bookID: masterBook, name: "\n") }
rejects("入出金元改名で家計簿越境を拒否") { try masters.saveAccount(id: bank, bookID: foreignBook, name: "変更") }
try masters.setAccountArchived(id: bank, bookID: masterBook, archived: true)
expect(masters.entries[0].sourceID == bank, "入出金元アーカイブで過去の関連を維持")
rejects("アーカイブ済み入出金元を新規選択しない") { _ = try masters.validated(BudgetEntry(bookID: masterBook, kind: .expense, amount: 20, date: Date(), sourceID: bank)) }
_ = try masters.validated(taggedEntry, previous: taggedEntry)
expect(true, "過去取引編集は元のアーカイブ済み入出金元を保持可能")
try masters.setAccountArchived(id: bank, bookID: masterBook, archived: false)
let accountOrder = [card, masterWallet, bank]
try masters.reorderAccounts(bookID: masterBook, ids: accountOrder)
expect(masters.orderedAccounts(bookID: masterBook).map(\.id) == accountOrder, "入出金元の並べ替え")
rejects("入出金元の並べ替えに重複IDを混ぜない") { try masters.reorderAccounts(bookID: masterBook, ids: [bank, bank, card]) }
let foreignAccount = masters.accounts.first { $0.bookID == foreignBook }!.id
rejects("入出金元の並べ替えに別家計簿を混ぜない") { try masters.reorderAccounts(bookID: masterBook, ids: [bank, card, foreignAccount]) }
let afterReorder = try masters.saveAccount(bookID: masterBook, name: "電子マネー")
expect(masters.orderedAccounts(bookID: masterBook).last?.id == afterReorder, "並べ替え後に新規項目は末尾へ追加")
try repository.save(masters)
let savedMasters = try repository.load()!
expect(savedMasters == masters, "タグの名称・関連・アーカイブと入出金元順序をファイル往復で維持")
// 旧JSONはorderを持たない。旧配列順と新規追加位置が崩れないことを確認。
var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(masters)) as! [String: Any]
var legacyAccounts = legacyObject["accounts"] as! [[String: Any]]
for index in legacyAccounts.indices { legacyAccounts[index].removeValue(forKey: "order") }
legacyObject["accounts"] = legacyAccounts
let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
let legacyState = try JSONDecoder().decode(BudgetSnapshot.self, from: legacyData)
expect(legacyState.orderedAccounts(bookID: masterBook).map(\.id) == masters.accounts.filter { $0.bookID == masterBook }.map(\.id), "旧JSONの並び順なしデータを配列順で読み込める")
try runSearchChecks()
try runCalendarChecks()
try runTagChecks()
try runBookChecks()
try runCategoryChecks()
try runRefundChecks()
try runBackupChecks()
try await runCloudChecks()
print("Passed \(checks) domain checks")
