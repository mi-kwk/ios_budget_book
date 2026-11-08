import Foundation

@MainActor
func runRefundChecks() throws {
    var state = testSnapshot()
    let book = state.books[0].id, wallet = state.accounts.first { $0.bookID == state.books[0].id }!.id
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    let january = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 17))!
    let february = calendar.date(from: DateComponents(year: 2026, month: 2, day: 15, hour: 11))!
    let tag = try state.saveTag(bookID: book, name: "返金検証")
    let otherTag = try state.saveTag(bookID: book, name: "独立タグ")
    let created = Date(timeIntervalSince1970: 100)
    var expense = BudgetEntry(bookID: book, kind: .expense, amount: 1000, date: january, sourceID: wallet, tagIDs: [tag], merchant: "お店")
    try state.saveTransaction(expense, now: created)
    expense = state.entries[0]
    expect(expense.createdAt == created && expense.date == calendar.startOfDay(for: january), "登録日時を保持し取引日は日付のみに正規化")
    var refund = BudgetEntry(bookID: book, kind: .refund, amount: 300, date: february, destinationID: wallet, tagIDs: [tag], refundOfID: expense.id)
    try state.saveTransaction(refund, now: created.addingTimeInterval(1))
    refund = state.entries.first { $0.id == refund.id }!
    expect(refund.categoryID == expense.categoryID && refund.includedInTotals == expense.includedInTotals && refund.sourceID == nil, "返金はカテゴリ・対象を元支出に連動")
    expect(state.refundedAmount(for: expense.id) == 300, "部分返金額を保持")
    var second = refund; second.id = UUID(); second.amount = 200
    try state.saveTransaction(second, now: created.addingTimeInterval(2))
    expect(state.refundedAmount(for: expense.id) == 500 && state.refunds(for: expense.id).count == 2, "複数回返金の合計と履歴")
    expect(BudgetSummary.totals(state.orderedEntries(bookID: book)).expense == 500, "通常支出は返金を控除し収入にしない")
    let februaryEntries = state.orderedEntries(bookID: book).filter { calendar.isDate($0.date, equalTo: february, toGranularity: .month) }
    expect(BudgetSummary.totals(februaryEntries).expense == -500 && BudgetSummary.totals(februaryEntries).income == 0, "月をまたぐ返金は返金月の支出から控除")
    let amounts = state.categoryAmounts(bookID: book, kind: .expense, entries: februaryEntries)
    let uncategorizedParent = state.categories.first { $0.id == expense.categoryID }!.parentID!
    expect(amounts[uncategorizedParent] == -500, "カテゴリ集計にも負の差引額を反映")
    var bad = refund; bad.id = UUID(); bad.amount = 501
    let before = state
    rejects("未返金額を超える新規返金は拒否") { try state.saveTransaction(bad) }
    expect(state == before, "返金検証失敗で全データを変更しない")
    bad = refund; bad.amount = 801
    rejects("編集中の返金以外も含めて合計上限を検証") { try state.saveTransaction(bad) }
    bad = refund; bad.amount = 800
    try state.saveTransaction(bad)
    expect(state.refundedAmount(for: expense.id) == 1000, "編集時に自分自身を二重加算せず上限額を許可")
    bad = refund; bad.id = UUID(); bad.date = january.addingTimeInterval(-86400)
    rejects("元支出より前の返金日を禁止") { try state.saveTransaction(bad) }
    bad = refund; bad.id = UUID(); bad.refundOfID = UUID()
    rejects("存在しない元支出を拒否") { try state.saveTransaction(bad) }
    bad = refund; bad.id = UUID(); bad.refundOfID = second.id
    rejects("返金を元支出にできない") { try state.saveTransaction(bad) }
    bad = refund; bad.id = UUID(); bad.bookID = state.books[1].id
    rejects("返金の家計簿越境を拒否") { try state.saveTransaction(bad) }
    bad = expense; bad.amount = 999
    rejects("返金合計より小さく元支出を減額できない") { try state.saveTransaction(bad) }
    bad = expense; bad.date = february.addingTimeInterval(86400)
    rejects("返金より後へ元支出の日付を変更できない") { try state.saveTransaction(bad) }
    bad = expense; bad.kind = .income; bad.destinationID = wallet
    rejects("保存済み取引の種別変更を禁止") { try state.saveTransaction(bad) }
    bad = expense; bad.bookID = state.books[1].id
    rejects("保存済み取引の所属変更を禁止") { try state.saveTransaction(bad) }
    bad = refund; bad.refundOfID = second.id
    rejects("返金の元支出の変更を禁止") { try state.saveTransaction(bad) }
    var changedRefund = state.entries.first { $0.id == refund.id }!
    changedRefund.tagIDs = [otherTag]
    try state.saveTransaction(changedRefund)
    let root = try state.saveCategory(bookID: book, kind: .expense, name: "変更先", parentID: nil)
    let child = try state.saveCategory(bookID: book, kind: .expense, name: "子", parentID: root)
    var edited = expense; edited.categoryID = child; edited.includedInTotals = false; edited.createdAt = Date()
    try state.saveTransaction(edited)
    expect(state.refunds(for: expense.id).allSatisfy { $0.categoryID == child && !$0.includedInTotals }, "支出の編集で全返金のカテゴリ・対象を同時更新")
    expect(state.entries.first { $0.id == expense.id }!.createdAt == created, "編集で登録日時を書き換えない")
    expect(state.entries.first { $0.id == refund.id }!.tagIDs == [otherTag], "元支出の編集後も返金タグは独立")
    expect(BudgetSummary.totals(state.orderedEntries(bookID: book)).expense == 0, "通常集計はOFFの支出と返金をともに除外")
    let tagged = BudgetSummary.matchingTags(state.orderedEntries(bookID: book), tags: [otherTag], matchAll: true)
    expect(BudgetSummary.totals(tagged, includeExcluded: true).expense == -800, "タグ集計は返金自身のタグでOFFも控除")
    try state.validateBackup()
    let encrypted = try BackupCodec.encrypt(BackupPayload(snapshot: state), password: "refund-password")
    expectBackup(try BackupCodec.decrypt(encrypted, password: "refund-password").snapshot == state, "返金関連・登録日時・相手先を暗号化往復で保持")
    var invalid = state; invalid.entries[invalid.entries.firstIndex { $0.id == refund.id }!].refundOfID = UUID()
    rejects("バックアップ内の返金参照切れを拒否") { try invalid.validateBackup() }
    invalid = state; invalid.entries[invalid.entries.firstIndex { $0.id == refund.id }!].amount = 1001
    rejects("バックアップ内の返金超過を拒否") { try invalid.validateBackup() }
    invalid = state; invalid.entries[invalid.entries.firstIndex { $0.id == refund.id }!].includedInTotals = true
    rejects("バックアップ内の連動不整合を拒否") { try invalid.validateBackup() }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let repository = JSONBudgetRepository(url: folder.appendingPathComponent("state.json"))
    try repository.save(state)
    expectBackup(try repository.load() == state, "返金と関連を通常ファイル保存から再読込")
    var deleted = state; try deleted.deleteTransaction(refund.id)
    expect(deleted.entries.contains { $0.id == expense.id } && deleted.refundedAmount(for: expense.id) == 200, "返金だけ削除したら元支出を保持し未返金額を戻す")
    deleted = state; try deleted.deleteTransaction(expense.id)
    expect(deleted.entries.isEmpty, "元支出削除では全関連返金も削除")
    var fresh = testSnapshot()
    let fbook = fresh.books[0].id, fwallet = fresh.accounts.first!.id
    var input = BudgetEntry(bookID: fbook, kind: .expense, amount: 999_999_999, date: january, sourceID: fwallet)
    _ = try fresh.validated(input)
    expect(true, "新しい金額上限ちょうどを許可")
    input.amount += 1
    rejects("新しい金額上限超過を拒否") { _ = try fresh.validated(input) }
    input.amount = 1; input.merchant = String(repeating: "店", count: 101)
    rejects("相手先100文字超を拒否し切り捨てない") { _ = try fresh.validated(input) }
    input.merchant = String(repeating: "店", count: 100); input.memo = String(repeating: "🧑‍🧑‍🧒", count: 1000)
    _ = try fresh.validated(input)
    expect(true, "Swift Characterで相手先100・メモ1000文字の境界を許可")
    input.memo += "あ"
    rejects("メモ1000文字超を拒否") { _ = try fresh.validated(input) }
    input.memo = ""; input.merchant = nil
    try fresh.saveTransaction(input, now: created)
    var later = input; later.id = UUID()
    try fresh.saveTransaction(later, now: created.addingTimeInterval(1))
    let firstOrder = fresh.orderedEntries(bookID: fbook).map(\.id)
    expect(firstOrder == [later.id, input.id], "同日の取引は登録日時降順")
    input.memo = "編集"; try fresh.saveTransaction(input, now: created.addingTimeInterval(2))
    expect(fresh.orderedEntries(bookID: fbook).map(\.id) == firstOrder, "編集で同日取引の順序を変えない")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as! [String: Any]
    var oldEntries = legacy["entries"] as! [[String: Any]]
    for index in oldEntries.indices { for key in ["createdAt", "merchant", "refundOfID"] { oldEntries[index].removeValue(forKey: key) } }
    legacy["entries"] = oldEntries
    let old = try JSONDecoder().decode(BudgetSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
    expect(old.entries.allSatisfy { $0.createdAt == nil && $0.merchant == nil && $0.refundOfID == nil }, "新属性なしの旧JSONを読める")
    expect(old.orderedEntries(bookID: fbook).map(\.id) == old.entries.map(\.id), "旧取引の同日順は保存済み配列順を保持")
    var withArchived = testSnapshot()
    let abook = withArchived.books[0].id, awallet = withArchived.accounts.first!.id
    let archivedTag = try withArchived.saveTag(bookID: abook, name: "古いタグ")
    var original = BudgetEntry(bookID: abook, kind: .expense, amount: 100, date: january, sourceID: awallet, tagIDs: [archivedTag])
    try withArchived.saveTransaction(original); original = withArchived.entries[0]
    try withArchived.setTagArchived(id: archivedTag, bookID: abook, archived: true)
    let inherited = BudgetEntry(bookID: abook, kind: .refund, amount: 20, date: february, destinationID: awallet, tagIDs: original.tagIDs, refundOfID: original.id)
    try withArchived.saveTransaction(inherited)
    expect(withArchived.refunds(for: original.id)[0].tagIDs == original.tagIDs, "アーカイブ済みも元支出から返金へタグ継承できる")
}
