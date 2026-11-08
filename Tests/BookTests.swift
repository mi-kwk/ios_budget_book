import Foundation

@MainActor
func runBookChecks() throws {
    var state = BudgetSnapshot.initial()
    let first = state.books[0].id
    let second = try state.createBook(name: "Archive", shared: true)
    let third = try state.createBook(name: "旅行", shared: false)
    let wallet = state.accounts.first { $0.bookID == second }!.id
    let tag = try state.saveTag(bookID: second, name: "保持タグ")
    let account = try state.saveAccount(bookID: second, name: "銀行")
    let category = state.categories.first { $0.bookID == second && $0.kind == .expense && $0.parentID != nil && !$0.isUncategorized }!
    state.books[state.books.firstIndex { $0.id == second }!].hiddenTagIDs = [tag]
    let expense = BudgetEntry(bookID: second, kind: .expense, amount: 1000, date: Date(), categoryID: category.id, sourceID: wallet, tagIDs: [tag])
    try state.saveTransaction(expense)
    let refund = BudgetEntry(bookID: second, kind: .refund, amount: 300, date: Date(), destinationID: wallet, tagIDs: [tag], refundOfID: expense.id)
    try state.saveTransaction(refund)
    let savedEntries = state.entries, savedCategories = state.categories, savedAccounts = state.accounts, savedTags = state.tags
    try state.renameBook(id: third, name: "  旅行用  ")
    expect(state.books.first { $0.id == third }!.name == "旅行用", "家計簿名の前後空白を除去")
    expect(state.entries == savedEntries && state.categories == savedCategories && state.accounts == savedAccounts && state.tags == savedTags, "家計簿改名で全関連と金額を維持")
    rejects("家計簿名の空白のみは禁止") { try state.renameBook(id: third, name: " \n") }
    rejects("英字大小文字の重複改名は禁止") { try state.renameBook(id: third, name: "archive") }
    rejects("存在しない家計簿の改名を拒否") { try state.renameBook(id: UUID(), name: "不明") }
    try state.reorderBooks(ids: [third, first, second])
    expect(state.orderedBooks(includeArchived: false).map(\.id) == [third, first, second], "家計簿を手動の順序で表示")
    rejects("家計簿順序の重複IDを拒否") { try state.reorderBooks(ids: [third, first, first]) }
    rejects("家計簿順序の不足IDを拒否") { try state.reorderBooks(ids: [first]) }
    rejects("家計簿順序の不明IDを拒否") { try state.reorderBooks(ids: [third, first, UUID()]) }
    try state.selectActiveBook(second)
    try state.setBookArchived(id: second, archived: true)
    let archived = state
    expect(state.books.first { $0.id == second }!.archived && state.books.count == 3, "アーカイブは物理削除しない")
    expect(state.selectedBookID == third, "選択中をアーカイブしたら表示順先頭の利用可能な家計簿へ切替")
    expect(state.orderedBooks(includeArchived: false).map(\.id) == [third, first], "通常切替候補からアーカイブ済みを除外")
    expect(state.entries == savedEntries && state.categories == savedCategories && state.accounts == savedAccounts && state.tags == savedTags, "アーカイブで取引・返金・マスタを保持")
    expect(BudgetSummary.totals(state.orderedEntries(bookID: second)).expense == 700, "アーカイブ済みも過去の返金差引収支を閲覧可能")
    expect(state.books.first { $0.id == second }!.hiddenTagIDs == [tag], "アーカイブで家計簿の表示設定を保持")
    rejects("アーカイブ済みを通常選択できない") { try state.selectActiveBook(second) }
    rejects("アーカイブ済み家計簿は改名できない") { try state.renameBook(id: second, name: "変更") }
    rejects("アーカイブ済みと同名の新しい家計簿は禁止") { try state.createBook(name: " archive ", shared: false) }
    rejects("アーカイブ済みと同名への改名は禁止") { try state.renameBook(id: third, name: "ARCHIVE") }
    rejects("アーカイブ済みを並べ替え対象へ混在させない") { try state.reorderBooks(ids: [second, first]) }
    var newEntry = expense; newEntry.id = UUID()
    rejects("アーカイブ済み家計簿への取引登録を拒否") { try state.saveTransaction(newEntry) }
    var edited = state.entries.first { $0.id == expense.id }!; edited.memo = "変更"
    rejects("アーカイブ済みの取引編集を拒否") { try state.saveTransaction(edited) }
    rejects("アーカイブ済みの支出・関連返金削除を拒否") { try state.deleteTransaction(expense.id) }
    rejects("アーカイブ済みの返金単独削除を拒否") { try state.deleteTransaction(refund.id) }
    rejects("アーカイブ済みのカテゴリ追加を拒否") { try state.saveCategory(bookID: second, kind: .expense, name: "追加", parentID: nil) }
    rejects("アーカイブ済みのカテゴリ変更を拒否") { try state.saveCategory(id: category.id, bookID: second, kind: .expense, name: "変更", parentID: category.parentID) }
    rejects("アーカイブ済みのカテゴリ状態変更を拒否") { try state.setCategoryArchived(id: category.id, bookID: second, archived: true) }
    rejects("アーカイブ済みのカテゴリ順変更を拒否") { try state.reorderCategories(bookID: second, kind: .expense, parentID: nil, ids: state.orderedCategories(bookID: second, kind: .expense, parentID: nil).map(\.id)) }
    rejects("アーカイブ済みの初期セット追加を拒否") { try state.addBasicCategories(bookID: second) }
    rejects("アーカイブ済みのタグ追加を拒否") { try state.saveTag(bookID: second, name: "追加") }
    rejects("アーカイブ済みのタグ状態変更を拒否") { try state.setTagArchived(id: tag, bookID: second, archived: true) }
    rejects("アーカイブ済みの入出金元追加を拒否") { try state.saveAccount(bookID: second, name: "追加") }
    rejects("アーカイブ済みの入出金元状態変更を拒否") { try state.setAccountArchived(id: account, bookID: second, archived: true) }
    rejects("アーカイブ済みの入出金元順変更を拒否") { try state.reorderAccounts(bookID: second, ids: [wallet, account]) }
    expect(state == archived, "閲覧専用への全変更を拒否した後も全データは同一")
    var bypass = state
    bypass.books[bypass.books.firstIndex { $0.id == second }!].showsTagSummary.toggle()
    rejects("汎用更新でもアーカイブ済みの表示設定変更を拒否") { try bypass.validateArchivedBookChanges(from: state) }
    bypass = state; bypass.entries.removeAll { $0.bookID == second }
    rejects("汎用更新でのアーカイブ済みデータ削除を拒否") { try bypass.validateArchivedBookChanges(from: state) }
    bypass = state; bypass.books.removeAll { $0.id == second }
    rejects("汎用更新でのアーカイブ済み家計簿削除を拒否") { try bypass.validateArchivedBookChanges(from: state) }
    var allowed = state
    try allowed.renameBook(id: first, name: "変更した個人用")
    try allowed.validateArchivedBookChanges(from: state)
    expect(true, "アーカイブがあっても別の利用可能な家計簿は編集可能")
    try state.reorderBooks(ids: [first, third])
    try state.setBookArchived(id: first, archived: true)
    let onlyOne = state
    rejects("利用可能な最後の1冊をアーカイブできない") { try state.setBookArchived(id: third, archived: true) }
    expect(state == onlyOne && state.selectedBookID == third, "最後の1冊保護の失敗で選択とデータを維持")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let repository = JSONBudgetRepository(url: folder.appendingPathComponent("books.json"))
    try repository.save(state)
    expectBackup(try repository.load() == state, "家計簿の順序・アーカイブ・選択・関連を通常保存から復元")
    let encrypted = try BackupCodec.encrypt(BackupPayload(snapshot: state), password: "books-password")
    expectBackup(try BackupCodec.decrypt(encrypted, password: "books-password").snapshot == state, "家計簿の全設定を暗号化ファイルから復元")
    let beforeRestore = state
    try state.setBookArchived(id: second, archived: false)
    try state.validateArchivedBookChanges(from: beforeRestore)
    expect(state.books.first { $0.id == second }?.archived == false && state.entries == savedEntries && state.categories == savedCategories, "家計簿復元でID・関連・金額・カテゴリを維持し汎用保護を通過")
    var restoredExpense = state.entries.first { $0.id == expense.id }!; restoredExpense.memo = "復元後"
    try state.saveTransaction(restoredExpense)
    expect(state.entries.first { $0.id == expense.id }!.memo == "復元後", "復元後は取引編集が可能")
    let newBook = try state.createBook(name: "新しい家計簿", shared: false)
    expect(state.orderedBooks(includeArchived: false).last?.id == newBook, "家計簿追加は現在の表示順の末尾")
    var stale = state; stale.selectedBookID = first
    try repository.save(stale)
    let recovered = try repository.load()!
    expect(recovered.selectedBookID == recovered.orderedBooks(includeArchived: false).first?.id, "起動時に選択先がアーカイブ済みなら利用可能な先頭へ切替")
    stale = state; stale.selectedBookID = UUID()
    try repository.save(stale)
    expectBackup(try repository.load()?.selectedBookID == state.orderedBooks(includeArchived: false).first?.id, "起動時に選択先が消えていても利用可能な家計簿へ切替")
    stale = state; stale.selectedBookID = first
    let staleEncrypted = try BackupCodec.encrypt(BackupPayload(snapshot: stale), password: "books-password")
    expectBackup(try BackupCodec.decrypt(staleEncrypted, password: "books-password").snapshot.selectedBookID == state.orderedBooks(includeArchived: false).first?.id, "バックアップ復元時もアーカイブ済み選択先を補正")
    var invalid = state
    for index in invalid.books.indices { invalid.books[index].isArchived = true }
    rejects("利用可能な家計簿がないバックアップを拒否") { try invalid.validateBackup() }
    try repository.save(invalid)
    let bytes = try Data(contentsOf: repository.url)
    rejects("利用可能な家計簿がない保存データは編集停止") { _ = try repository.load() }
    expectBackup(try Data(contentsOf: repository.url) == bytes, "選択先復旧不能でも元ファイルを変更しない")
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BudgetSnapshot.initial())) as! [String: Any]
    var oldBooks = object["books"] as! [[String: Any]]
    for index in oldBooks.indices { oldBooks[index].removeValue(forKey: "order"); oldBooks[index].removeValue(forKey: "isArchived") }
    object["books"] = oldBooks
    let old = try JSONDecoder().decode(BudgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    expect(old.books.allSatisfy { !$0.archived && $0.order == nil } && old.orderedBooks().map(\.id) == old.books.map(\.id), "旧JSONの新属性なし家計簿は利用可能・配列順で読み込む")
}
