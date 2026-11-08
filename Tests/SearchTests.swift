import Foundation

@MainActor
func runSearchChecks() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    func date(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    var state = BudgetSnapshot.initial()
    let book = state.books[0].id, wallet = state.accounts.first!.id
    let bank = try state.saveAccount(bookID: book, name: "銀行")
    let card = try state.saveAccount(bookID: book, name: "カード")
    let tagA = try state.saveTag(bookID: book, name: "旅行")
    let tagB = try state.saveTag(bookID: book, name: "家族")
    let food = state.categories.first { $0.bookID == book && $0.kind == .expense && $0.parentID == nil && $0.name == "食費" }!
    let cafe = state.categories.first { $0.parentID == food.id && $0.name == "カフェ" }!
    let groceries = state.categories.first { $0.parentID == food.id && $0.name == "食料品" }!
    let transport = state.categories.first { $0.bookID == book && $0.kind == .expense && $0.parentID == nil && $0.name == "交通費" }!
    let train = state.categories.first { $0.parentID == transport.id }!
    let expense = BudgetEntry(bookID: book, kind: .expense, amount: 1000, date: date(11, 5), categoryID: cafe.id, sourceID: wallet, tagIDs: [tagA, tagB], memo: "週末 TRAVEL", merchant: "ＣＡＦＥ SHOP")
    let old = BudgetEntry(bookID: book, kind: .expense, amount: 500, date: date(10, 31), categoryID: groceries.id, sourceID: bank, tagIDs: [tagB], memo: "Café only", merchant: "ｶﾌｪ")
    let excluded = BudgetEntry(bookID: book, kind: .expense, amount: 300, date: date(11, 15), categoryID: train.id, sourceID: bank, tagIDs: [tagB], includedInTotals: false, memo: "対象外")
    let income = BudgetEntry(bookID: book, kind: .income, amount: 2000, date: date(11, 6), destinationID: bank, tagIDs: [tagA], merchant: "Salary")
    let transfer = BudgetEntry(bookID: book, kind: .transfer, amount: 700, date: date(11, 7), sourceID: wallet, destinationID: bank, tagIDs: [tagA])
    let oneSide = BudgetEntry(bookID: book, kind: .transfer, amount: 800, date: date(11, 8), destinationID: bank, tagIDs: [tagB])
    let refund = BudgetEntry(bookID: book, kind: .refund, amount: 200, date: date(11, 9), destinationID: card, tagIDs: [tagB], memo: "返金", refundOfID: expense.id)
    let excludedRefund = BudgetEntry(bookID: book, kind: .refund, amount: 100, date: date(11, 16), destinationID: wallet, tagIDs: [tagA], refundOfID: excluded.id)
    let future = BudgetEntry(bookID: book, kind: .income, amount: 900, date: date(12, 1), destinationID: bank)
    for entry in [expense, old, excluded, income, transfer, oneSide, refund, excludedRefund, future] { try state.saveTransaction(entry) }
    let foreign = try state.createBook(name: "別家計簿", shared: false)
    let foreignWallet = state.accounts.first { $0.bookID == foreign }!.id
    let foreignEntry = BudgetEntry(bookID: foreign, kind: .expense, amount: 99, date: date(11, 1), sourceID: foreignWallet, includedInTotals: false, merchant: "Cafe")
    try state.saveTransaction(foreignEntry)
    let base = EntrySearchQuery(month: date(11, 20), calendar: calendar)
    func ids(_ query: EntrySearchQuery, in snapshot: BudgetSnapshot? = nil, bookID: UUID? = nil) -> Set<UUID> {
        Set((snapshot ?? state).searchEntries(bookID: bookID ?? book, query: query, calendar: calendar).map(\.id))
    }
    expect(base.month == date(11, 1) && base.startDate == date(11, 1) && base.endDate == date(11, 30), "検索初期期間は捕捉した共通表示月")
    expect(base.kinds.isEmpty && base.matchAllTags && base.inclusion == .all, "初期は全種別・対象内外両方・タグAND")
    expect(ids(base).count == 7 && !ids(base).contains(future.id) && !ids(base).contains(old.id), "月指定は月内だけで対象外・振替・返金も含む")
    expect(!ids(base).contains(foreignEntry.id), "別家計簿の取引を混在させない")
    var q = base; q.period = .all
    expect(ids(q).count == 9, "全期間は前月と未来月も含む")
    q = base; q.period = .custom; q.startDate = date(11, 5); q.endDate = date(11, 9)
    expect(ids(q) == [expense.id, income.id, transfer.id, oneSide.id, refund.id], "任意期間の両端日を含む")
    q.startDate = date(11, 9, 23); q.endDate = date(11, 9, 1)
    expect(q.hasValidPeriod(calendar: calendar) && ids(q) == [refund.id], "時刻によらず同じ日を検索できる")
    q.startDate = date(11, 10)
    expect(!q.hasValidPeriod(calendar: calendar) && ids(q).isEmpty, "逆転した期間は無効で結果を出さない")
    q.period = .all
    expect(q.hasValidPeriod(calendar: calendar) && ids(q).count == 9, "全期間では未使用の期間入力を条件にしない")
    q = base; q.kinds = [.refund]
    expect(ids(q) == [refund.id, excludedRefund.id], "返金を独立した種別として検索")
    q.kinds = [.income, .transfer]
    expect(ids(q) == [income.id, transfer.id, oneSide.id], "複数の取引種別はOR")
    q = base; q.categoryIDs = [food.id]
    expect(ids(q) == [expense.id, refund.id], "大カテゴリ指定は配下と返金の連動カテゴリを含む")
    q.categoryIDs = [cafe.id]
    expect(ids(q) == [expense.id, refund.id], "小カテゴリ指定")
    q.categoryIDs = [food.id, cafe.id]
    expect(state.searchEntries(bookID: book, query: q, calendar: calendar).count == 2, "親と子を選んでも取引を二重にしない")
    q.categoryIDs = [food.id, transport.id]
    expect(ids(q) == [expense.id, refund.id, excluded.id, excludedRefund.id], "複数カテゴリはOR")
    q.kinds = [.income]
    expect(ids(q).isEmpty, "種別とカテゴリはAND")
    q = base; q.tagIDs = [tagA, tagB]
    expect(ids(q) == [expense.id], "複数タグは初期AND")
    q.matchAllTags = false
    expect(ids(q).count == 7, "タグORはどちらかを持つ全件")
    expect(state.searchEntries(bookID: book, query: q, calendar: calendar).count == 7, "OR一致でも同じIDを二重集計しない")
    q.tagIDs = [tagA]
    expect(ids(q) == [expense.id, income.id, transfer.id, excludedRefund.id], "返金自身のタグで判定し元支出と区別")
    q.tagIDs = []
    expect(ids(q).count == 7, "タグ未選択は条件なし")
    q = base; q.accountIDs = [wallet]
    expect(ids(q) == [expense.id, transfer.id, excludedRefund.id], "出金元・振替元・返金入金先で一致")
    q.accountIDs = [bank]
    expect(ids(q) == [excluded.id, income.id, transfer.id, oneSide.id], "振替先と片側指定も検索対象")
    q.accountIDs = [card]; q.kinds = [.refund]
    expect(ids(q) == [refund.id], "返金は元支出の出金元ではなく返金の入金先で判定")
    q = base; q.accountIDs = [wallet, bank]
    expect(ids(q).count == 6 && state.searchEntries(bookID: book, query: q, calendar: calendar).count == 6, "複数入出金元はOR・両側一致の振替も一度だけ")
    q.categoryIDs = [food.id]; q.tagIDs = [tagB]
    expect(ids(q) == [expense.id], "カテゴリ・タグ・入出金元をANDで複合")
    q = base; q.inclusion = .included
    expect(ids(q) == [expense.id, income.id, refund.id], "対象内は返金の元支出連動を使用し振替を含めない")
    q.inclusion = .excluded
    expect(ids(q) == [excluded.id, transfer.id, oneSide.id, excludedRefund.id], "対象外はOFF返金と振替を含む")
    q = base; q.keyword = "cafe"
    expect(ids(q) == [expense.id], "英字大小と全角半角を無視した部分一致")
    q.keyword = "ＣａＦｅ 週末"
    expect(ids(q) == [expense.id], "語ごとに相手先・メモをまたいでAND一致")
    q.keyword = "shop\nTRAVEL\t週末"
    expect(ids(q) == [expense.id], "空白・改行・タブ区切りの複数語をAND")
    q.keyword = "shop ない単語"
    expect(ids(q).isEmpty, "複数語の一つでも不一致なら除外")
    q.keyword = " \n　\t "
    expect(ids(q).count == 7, "空欄・空白のみのキーワードは条件なし")
    q.period = .all; q.keyword = "カフェ"
    expect(ids(q) == [old.id], "半角カナ・全角カナも検索時に幅を揃える")
    q = base; q.keyword = "食費"
    expect(ids(q).isEmpty, "カテゴリ名をキーワード対象に混ぜない")
    q = base; q.categoryIDs = [food.id]; q.tagIDs = [tagA]; q.accountIDs = [wallet]; q.keyword = "cafe travel"; q.kinds = [.expense]; q.inclusion = .included
    expect(ids(q) == [expense.id], "すべての条件を組み合わせても一致する取引だけ返す")
    let captured = q
    var edited = state.entries.first { $0.id == expense.id }!
    edited.merchant = "OTHER"; edited.memo = "変更後"
    var changed = state; try changed.saveTransaction(edited)
    expect(ids(q, in: changed).isEmpty && q == captured, "編集後も条件を保持して再評価し条件外の取引は消える")
    var changedIncome = state.entries.first { $0.id == income.id }!; changedIncome.date = date(12, 2)
    changed = state; try changed.saveTransaction(changedIncome)
    expect(!ids(base, in: changed).contains(income.id) && base.month == date(11, 1), "日付編集で共通表示月が変わっても捕捉した検索月は固定")
    q = base; q.period = .all; q.kinds = [.expense]; q.keyword = "CAFE"; q.inclusion = .excluded; q.matchAllTags = false
    q.categoryIDs = [food.id]; q.tagIDs = [tagB]; q.accountIDs = [bank]
    let beforeSwitch = q
    q.clearBookSelections()
    expect(q.categoryIDs.isEmpty && q.tagIDs.isEmpty && q.accountIDs.isEmpty, "家計簿切替では所属先の選択だけ解除")
    expect(q.period == beforeSwitch.period && q.month == beforeSwitch.month && q.startDate == beforeSwitch.startDate && q.endDate == beforeSwitch.endDate && q.kinds == beforeSwitch.kinds && q.keyword == beforeSwitch.keyword && q.inclusion == beforeSwitch.inclusion && q.matchAllTags == beforeSwitch.matchAllTags, "家計簿切替でも期間・種別・語句・対象内外・タグモードを保持")
    expect(ids(q, bookID: foreign) == [foreignEntry.id], "切替先でグローバル条件を再適用")
    let totals = BudgetSummary.totals(state.searchEntries(bookID: book, query: base, calendar: calendar), includeExcluded: true)
    expect(totals.income == 2000 && totals.expense == 1000 && totals.transfer == 1500, "検索合計は対象外も条件に応じて含め、返金差引と振替を分離")
    var duplicate = state; duplicate.entries.append(state.entries.first { $0.id == transfer.id }!)
    expect(duplicate.searchEntries(bookID: book, query: base, calendar: calendar).count == 7, "同じ取引IDを検索結果へ重複表示しない")
    let duplicateTotals = BudgetSummary.totals(duplicate.searchEntries(bookID: book, query: base, calendar: calendar), includeExcluded: true)
    expect(duplicateTotals == totals, "同じIDを合計へ二重計上しない")
    var archived = state
    try archived.setCategoryArchived(id: food.id, bookID: book, archived: true)
    try archived.setTagArchived(id: tagB, bookID: book, archived: true)
    try archived.setAccountArchived(id: card, bookID: book, archived: true)
    q = base; q.categoryIDs = [food.id]; q.tagIDs = [tagB]; q.accountIDs = [card]
    expect(ids(q, in: archived) == [refund.id], "アーカイブ済みのカテゴリ・タグ・入出金元も過去検索へ使用可能")
    let unchanged = state
    _ = state.searchEntries(bookID: book, query: captured, calendar: calendar)
    expect(state == unchanged && state.entries.first { $0.id == expense.id }?.merchant == "ＣＡＦＥ SHOP", "検索用の正規化は保存表記を変更しない")
    q = base; q.period = .custom; q.startDate = date(11, 30); q.endDate = date(11, 30)
    var boundary = state
    var endEntry = income; endEntry.id = UUID(); endEntry.date = date(11, 30, 23)
    boundary.entries.append(endEntry)
    expect(ids(q, in: boundary) == [endEntry.id], "期間末日の夜の旧データも検索対象")
    q = base; q.categoryIDs = [UUID()]
    expect(ids(q).isEmpty, "存在しないカテゴリ条件を勝手に解除して結果を広げない")
    q = base; q.accountIDs = [foreignWallet]
    expect(ids(q).isEmpty, "別家計簿の入出金元IDでは一致しない")
    q = base; q.tagIDs = [UUID()]
    expect(ids(q).isEmpty, "不明なタグ条件では一致しない")
    let result = state.searchEntries(bookID: book, query: base, calendar: calendar)
    expect(result.first?.id == excludedRefund.id && result.last?.id == expense.id, "検索結果も取引日降順")
    var newer = income; newer.id = UUID()
    try state.saveTransaction(newer, now: Date().addingTimeInterval(100))
    let sameDay = state.searchEntries(bookID: book, query: base, calendar: calendar).filter { calendar.isDate($0.date, inSameDayAs: income.date) }
    expect(sameDay.map(\.id) == [newer.id, income.id], "同日の検索結果は登録日時降順")
}
