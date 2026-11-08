import Foundation

@MainActor
func runCalendarChecks() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    var navigation = CalendarNavigation(now: date(2026, 1, 31, hour: 18), calendar: calendar)
    expect(navigation.month == date(2026, 1, 1) && navigation.selectedDay == date(2026, 1, 31), "起動時は今月・今日を日付で初期化")
    navigation.moveMonth(1, calendar: calendar)
    expect(navigation.month == date(2026, 2, 1) && navigation.selectedDay == date(2026, 2, 28), "月末31日から平年2月へ進むと28日に調整")
    navigation.showMonth(date(2024, 1, 1), calendar: calendar)
    navigation.selectDay(date(2024, 1, 31), calendar: calendar)
    navigation.moveMonth(1, calendar: calendar)
    expect(navigation.selectedDay == date(2024, 2, 29), "閏年2月は29日へ調整")
    navigation.selectDay(date(2026, 12, 15, hour: 23), calendar: calendar)
    navigation.moveMonth(1, calendar: calendar)
    expect(navigation.month == date(2027, 1, 1) && navigation.selectedDay == date(2027, 1, 15), "年をまたいで月と選択日を連動")
    navigation.moveMonth(-1, calendar: calendar)
    expect(navigation.month == date(2026, 12, 1), "前の月で年境界を戻れる")
    navigation.selectDay(date(2026, 5, 10, hour: 12), calendar: calendar)
    expect(navigation.month == date(2026, 5, 1) && navigation.selectedDay == date(2026, 5, 10), "日付選択で対象月と日付を同時更新")
    let unchanged = navigation
    navigation.showMonth(date(2026, 5, 25), calendar: calendar)
    expect(navigation == unchanged, "同じ月を表示しても選択日を変更しない")
    expect(BudgetCalendar.weekdays(start: .monday) == ["月", "火", "水", "木", "金", "土", "日"], "月曜始まりの曜日順")
    expect(BudgetCalendar.weekdays(start: .sunday) == ["日", "月", "火", "水", "木", "金", "土"], "日曜始まりの曜日順")
    let monday = BudgetCalendar.cells(month: date(2026, 11, 18), start: .monday, calendar: calendar)
    let sunday = BudgetCalendar.cells(month: date(2026, 11, 1), start: .sunday, calendar: calendar)
    expect(monday.count == 42 && monday.prefix(6).allSatisfy { $0 == nil } && monday[6] == date(2026, 11, 1), "日曜開始の月を月曜始まりで6週・先頭6空欄に配置")
    expect(sunday.count == 35 && sunday[0] == date(2026, 11, 1), "日曜始まりなら同月を5週で配置")
    expect(monday.compactMap { $0 }.count == 30 && Set(monday.compactMap { $0 }).count == 30, "月内の日付を欠落・重複なく生成")
    let leap = BudgetCalendar.cells(month: date(2024, 2, 15), start: .monday, calendar: calendar)
    expect(leap.compactMap { $0 }.last == date(2024, 2, 29), "閏月の日付セルに29日を含む")
    let fourWeeks = BudgetCalendar.cells(month: date(2021, 2, 1), start: .monday, calendar: calendar)
    expect(fourWeeks.count == 28, "月曜開始の28日月は4週で配置")
    expect(BudgetCalendar.cells(month: date(2026, 11, 18), start: .monday, calendar: calendar) == monday, "月中の日付を渡しても同じ月グリッド")
    var state = BudgetSnapshot.initial()
    let book = state.books[0].id, wallet = state.accounts.first!.id
    let expense = BudgetEntry(bookID: book, kind: .expense, amount: 1000, date: date(2026, 1, 31), sourceID: wallet)
    try state.saveTransaction(expense)
    let refund = BudgetEntry(bookID: book, kind: .refund, amount: 300, date: date(2026, 2, 1), destinationID: wallet, refundOfID: expense.id)
    try state.saveTransaction(refund)
    try state.saveTransaction(BudgetEntry(bookID: book, kind: .income, amount: 800, date: date(2026, 2, 1, hour: 15), destinationID: wallet))
    try state.saveTransaction(BudgetEntry(bookID: book, kind: .expense, amount: 99, date: date(2026, 2, 1), sourceID: wallet, includedInTotals: false))
    try state.saveTransaction(BudgetEntry(bookID: book, kind: .transfer, amount: 500, date: date(2026, 2, 1), sourceID: wallet))
    // Transaction dates are normalized using the device timezone; align fixture values to the injected test calendar.
    for index in state.entries.indices {
        state.entries[index].date = state.entries[index].id == expense.id ? date(2026, 1, 31) : date(2026, 2, 1)
    }
    var summaries = BudgetCalendar.summaries(state.orderedEntries(bookID: book), calendar: calendar)
    let first = summaries[date(2026, 2, 1)]!
    expect(first.totals.income == 800 && first.totals.expense == -300 && first.totals.difference == 1100, "返金月の支出をマイナス控除し収入と別表示")
    expect(first.hasTransfer && first.totals.transfer == 0 && first.count == 4, "振替は存在マークだけで通常収支に加算せず、対象外も当日件数へ含む")
    expect(first.hasIncome && first.hasExpense && summaries[date(2026, 1, 31)]!.totals.expense == 1000, "元支出と返金を別の日へ集計")
    var original = state.entries.first { $0.id == expense.id }!; original.includedInTotals = false
    try state.saveTransaction(original)
    summaries = BudgetCalendar.summaries(state.orderedEntries(bookID: book), calendar: calendar)
    expect(summaries[date(2026, 2, 1)]!.totals.expense == 0 && !summaries[date(2026, 2, 1)]!.hasExpense, "元支出の対象OFFに日別返金も連動")
    expect(summaries[date(2026, 2, 1)]!.count == 4, "対象OFFの返金・支出も当日一覧対象に保持")
    expect(BudgetCalendar.summaries([], calendar: calendar).isEmpty, "取引なしの日別集計は空")
    let excludedOnly = BudgetCalendar.summaries([state.entries.first { $0.kind == .expense && $0.id != expense.id }!], calendar: calendar).values.first!
    expect(!excludedOnly.hasExpense && !excludedOnly.hasIncome && !excludedOnly.hasTransfer && excludedOnly.count == 1, "対象外だけの日は金額・振替マークを表示せず一覧件数は保持")
    var dst = Calendar(identifier: .gregorian); dst.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let dstMonth = dst.date(from: DateComponents(year: 2026, month: 3, day: 1))!
    let dstDays = BudgetCalendar.cells(month: dstMonth, start: .sunday, calendar: dst).compactMap { $0 }
    expect(dstDays.count == 31 && Set(dstDays.map { dst.component(.day, from: $0) }).count == 31, "夏時間切替月も日付の欠落・重複なし")
    expect(dstDays.allSatisfy { dst.component(.hour, from: $0) == 0 }, "日付を86400秒固定で進めず夏時間でも日初を保つ")
    expect(state.calendarWeekStart == nil, "旧保存データ・新規Snapshotの週開始未設定は月曜へフォールバック")
    state.calendarWeekStart = .sunday
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let repository = JSONBudgetRepository(url: folder.appendingPathComponent("calendar.json"))
    try repository.save(state)
    expectBackup(try repository.load()?.calendarWeekStart == .sunday, "週開始設定を再読込後も保持")
    let encrypted = try BackupCodec.encrypt(BackupPayload(snapshot: state), password: "calendar-password")
    expectBackup(try BackupCodec.decrypt(encrypted, password: "calendar-password").snapshot == state, "週開始設定を全データと暗号化往復で保持")
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
    object.removeValue(forKey: "calendarWeekStart")
    let old = try JSONDecoder().decode(BudgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    expect(old.calendarWeekStart == nil && old.entries == state.entries, "週設定なしの旧JSONを関連を失わず読み込む")
    object["calendarWeekStart"] = 99
    rejects("不明な週開始値を読み込まない") { _ = try JSONDecoder().decode(BudgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object)) }
    var zero = CalendarDaySummary()
    zero = BudgetCalendar.summaries([BudgetEntry(bookID: book, kind: .expense, amount: 300, date: date(2026, 2, 1)), refund], calendar: calendar).values.first!
    expect(zero.hasExpense && zero.totals.expense == 0, "全額差引で0円でも支出取引があれば支出0を表示")
    expect(EntryDateLimits.contains(date(1900, 1, 1), calendar: calendar), "入力日付の下限を許可")
    expect(EntryDateLimits.contains(date(2099, 12, 31, hour: 23), calendar: calendar), "入力日付の上限日は時刻があっても許可")
    expect(!EntryDateLimits.contains(date(1899, 12, 31), calendar: calendar), "入力日付下限未満を拒否")
    expect(!EntryDateLimits.contains(date(2100, 1, 1), calendar: calendar), "入力日付上限超過を拒否")
    navigation.selectDay(date(1900, 1, 1), calendar: calendar)
    navigation.moveMonth(-1, calendar: calendar)
    expect(navigation.month == date(1900, 1, 1), "表示月は日付範囲の下限で止まる")
    navigation.selectDay(date(2099, 12, 31), calendar: calendar)
    navigation.moveMonth(1, calendar: calendar)
    expect(navigation.month == date(2099, 12, 1), "表示月は日付範囲の上限で止まる")
    navigation.selectDay(date(2024, 2, 29), calendar: calendar)
    navigation.changeYear(2025, calendar: calendar)
    expect(navigation.month == date(2025, 2, 1) && navigation.selectedDay == date(2025, 2, 28), "年変更は月を維持し閏日だけ調整")
    navigation.selectMonth(11, calendar: calendar)
    expect(navigation.month == date(2025, 11, 1), "年間グラフの月選択は対象年を維持")
    let bounded = navigation
    navigation.changeYear(2100, calendar: calendar); navigation.selectMonth(13, calendar: calendar)
    expect(navigation == bounded, "不正な年・月の指定で表示を変えない")
    expect(BudgetCalendar.isFutureMonth(date(2026, 12, 1), now: date(2026, 11, 8), calendar: calendar), "次月は予定月と判定")
    expect(!BudgetCalendar.isFutureMonth(date(2026, 11, 30), now: date(2026, 11, 8), calendar: calendar), "同月の未来日は予定月と誤判定しない")
    expect(!BudgetCalendar.isFutureMonth(date(2026, 10, 1), now: date(2026, 11, 8), calendar: calendar), "過去月は実績月と判定")
    var charts = BudgetSnapshot.initial()
    let chartBook = charts.books[0].id, chartWallet = charts.accounts.first!.id
    let rootA = try charts.saveCategory(bookID: chartBook, kind: .expense, name: "検証A", parentID: nil)
    let rootB = try charts.saveCategory(bookID: chartBook, kind: .expense, name: "検証B", parentID: nil)
    let childA = try charts.saveCategory(bookID: chartBook, kind: .expense, name: "A", parentID: rootA)
    let childB = try charts.saveCategory(bookID: chartBook, kind: .expense, name: "B", parentID: rootB)
    let rest = charts.orderedCategories(bookID: chartBook, kind: .expense, parentID: nil).map(\.id).filter { $0 != rootA && $0 != rootB }
    try charts.reorderCategories(bookID: chartBook, kind: .expense, parentID: nil, ids: [rootB, rootA] + rest)
    let a = BudgetEntry(bookID: chartBook, kind: .expense, amount: 100, date: date(2026, 1, 1), categoryID: childA, sourceID: chartWallet)
    let b = BudgetEntry(bookID: chartBook, kind: .expense, amount: 100, date: date(2026, 1, 1), categoryID: childB, sourceID: chartWallet)
    try charts.saveTransaction(a); try charts.saveTransaction(b)
    var sorted = charts.orderedCategoryAmounts(bookID: chartBook, kind: .expense, entries: charts.entries)
    expect(sorted.map(\.id) == [rootB, rootA], "カテゴリ同額は名前ではなく設定順")
    expect(BudgetSnapshot.categoryChartKind(sorted) == .pie, "正の差引額のみなら円グラフ")
    var refundA = BudgetEntry(bookID: chartBook, kind: .refund, amount: 100, date: date(2026, 1, 1), destinationID: chartWallet, refundOfID: a.id)
    let refundB = BudgetEntry(bookID: chartBook, kind: .refund, amount: 100, date: date(2026, 1, 1), destinationID: chartWallet, refundOfID: b.id)
    try charts.saveTransaction(refundA); try charts.saveTransaction(refundB)
    sorted = charts.orderedCategoryAmounts(bookID: chartBook, kind: .expense, entries: charts.entries)
    expect(sorted.count == 2 && sorted.allSatisfy { $0.amount == 0 } && BudgetSnapshot.categoryChartKind(sorted) == .zero, "相殺0円のカテゴリは一覧へ残し円を描かない")
    let empty = charts.orderedCategoryAmounts(bookID: chartBook, kind: .expense, entries: [])
    expect(empty.isEmpty && BudgetSnapshot.categoryChartKind(empty) == .empty, "対象取引なしと相殺ゼロを区別")
    refundA.date = date(2026, 2, 1); try charts.saveTransaction(refundA)
    try charts.saveTransaction(BudgetEntry(bookID: chartBook, kind: .expense, amount: 100, date: date(2026, 2, 1), categoryID: childB, sourceID: chartWallet))
    let feb = charts.entries.filter { calendar.isDate($0.date, equalTo: date(2026, 2, 1), toGranularity: .month) }
    sorted = charts.orderedCategoryAmounts(bookID: chartBook, kind: .expense, entries: feb)
    expect(sorted.map(\.amount) == [100, -100] && BudgetSnapshot.categoryChartKind(sorted) == .bar, "正負混在で総額0円でも棒グラフ・金額降順")
    try charts.setAnnualLineChart(bookID: chartBook, enabled: true)
    let otherChartBook = try charts.createBook(name: "別形式", shared: false)
    expect(charts.books.first { $0.id == chartBook }!.annualLineChart == true && charts.books.first { $0.id == otherChartBook }!.annualLineChart == nil, "年間グラフ形式は家計簿単位で独立")
    try repository.save(charts)
    expectBackup(try repository.load()?.books.first { $0.id == chartBook }?.annualLineChart == true, "年間グラフ形式を再起動後も保持")
    let graphCipher = try BackupCodec.encrypt(BackupPayload(snapshot: charts), password: "calendar-password")
    expectBackup(try BackupCodec.decrypt(graphCipher, password: "calendar-password").snapshot == charts, "年間形式・週設定も含めた全体をバックアップ保持")
    try charts.setBookArchived(id: chartBook, archived: true)
    rejects("閲覧専用の家計簿の年間形式を変更しない") { try charts.setAnnualLineChart(bookID: chartBook, enabled: false) }
    var invalidDate = BudgetEntry(bookID: otherChartBook, kind: .income, amount: 1, date: date(2100, 1, 1), destinationID: charts.accounts.first { $0.bookID == otherChartBook }!.id)
    rejects("データ層でも取引日の上限超過を拒否") { try charts.saveTransaction(invalidDate) }
    invalidDate.date = date(1899, 12, 31)
    rejects("データ層でも取引日の下限未満を拒否") { try charts.saveTransaction(invalidDate) }

}
