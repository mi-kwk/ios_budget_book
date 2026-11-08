import SwiftUI
import Charts

func yen(_ amount: Int64) -> String { amount.formatted(.currency(code: "JPY").precision(.fractionLength(0))) }

enum BudgetTab: Hashable { case home, entries, summary }

struct RootView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var showSettings = false
    @State private var showEntry = false
    @State private var selectedTab: BudgetTab = .home
    @State private var newEntryDate = Date()
    var body: some View {
        TabView(selection: $selectedTab) {
            shell("ホーム") { HomeView() }.tabItem { Label("ホーム", systemImage: "house") }.tag(BudgetTab.home)
            shell("入出金") { EntriesView() }.tabItem { Label("入出金", systemImage: "list.bullet.rectangle") }.tag(BudgetTab.entries)
            shell("収支") { SummaryView() }.tabItem { Label("収支", systemImage: "chart.pie") }.tag(BudgetTab.summary)
        }
        .sheet(isPresented: $store.showHistory) { HistorySearchNavigation() }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $showEntry) {
            if let bookID = store.bookID { NavigationStack { EntryEditor(bookID: bookID, initialDate: newEntryDate) } }
        }
        .alert("確認", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("閉じる", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
    private func shell<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().navigationTitle(title)
                .safeAreaInset(edge: .top) {
                    if store.currentBook?.archived == true {
                        HStack {
                            Label("\(store.currentBook?.name ?? "家計簿")：閲覧専用", systemImage: "archivebox")
                                .font(.caption)
                            Spacer()
                            Button("閲覧を終了") { store.endArchivedViewing() }.font(.caption)
                        }.padding(10).background(.thinMaterial)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(store.state.orderedBooks(includeArchived: false)) { book in
                                Button { store.selectBook(book.id) } label: {
                                    if store.bookID == book.id { Label(book.name, systemImage: "checkmark") }
                                    else { Text(book.name) }
                                }
                            }
                        } label: { Label(store.currentBook?.name ?? "家計簿", systemImage: "books.vertical") }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("設定")
                        Button { newEntryDate = selectedTab == .entries && store.calendarMode ? store.selectedDay : Date(); showEntry = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("取引を登録").disabled(!store.canEditCurrentBook)
                    }
                }
        }.id("\(title)-\(store.bookID?.uuidString ?? "none")")
    }
}

struct MonthPicker: View {
    @EnvironmentObject private var store: BudgetStore
    var body: some View {
        HStack {
            Button { store.moveDisplayedMonth(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("前の月")
            Spacer()
            Text(store.displayMonth.formatted(.dateTime.year().month())).font(.headline)
            if BudgetCalendar.isFutureMonth(store.displayMonth) { Text("予定").font(.caption).foregroundStyle(.secondary) }
            Button("今月") { store.goToToday() }.font(.caption).accessibilityLabel("今月に戻る")
            Spacer()
            Button { store.moveDisplayedMonth(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("次の月")
        }.buttonStyle(.borderless).padding(.vertical, 4)
    }
}

struct TotalsView: View {
    let totals: MoneyTotals
    var body: some View {
        row("収入", value: totals.income, color: .teal)
        row("支出", value: totals.expense, color: .orange)
        row("差額", value: totals.difference, color: .primary)
    }
    private func row(_ title: String, value: Int64, color: Color) -> some View {
        HStack { Text(title); Spacer(); Text(yen(value)).fontWeight(.semibold).foregroundStyle(color).monospacedDigit() }
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: BudgetStore
    private var month: Date { store.displayMonth }
    private var lineChart: Bool { store.currentBook?.annualLineChart ?? false }
    @State private var annualSelectedMonth: Int?
    var body: some View {
        List {
            MonthPicker()
            Section("月間収支") { TotalsView(totals: BudgetSummary.totals(store.entries(in: month))) }
            Section("カテゴリ別集計") { CategoryKindPicker(); CategoryChart(month: month, kind: store.categoryKind) }
            Section("年間収支") {
                HStack {
                    Button { store.changeDisplayedYear(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("前の年").disabled(Calendar.current.component(.year, from: month) <= 1900)
                    Spacer(); Text("\(Calendar.current.component(.year, from: month))年").font(.headline); Spacer()
                    Button { store.changeDisplayedYear(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("次の年").disabled(Calendar.current.component(.year, from: month) >= 2099)
                }.buttonStyle(.borderless)
                Picker("グラフ形式", selection: Binding(get: { lineChart }, set: { store.setAnnualLineChart($0) })) { Text("棒").tag(false); Text("折れ線").tag(true) }.pickerStyle(.segmented).disabled(!store.canEditCurrentBook)
                Chart {
                    ForEach(1...12, id: \.self) { number in
                        let future = futureMonth(number)
                        if !future || annualHasTargets(number) {
                        if lineChart {
                            LineMark(x: .value("月", number), y: .value("収入", annual(number).income)).foregroundStyle(by: .value("種類", "収入"))
                            LineMark(x: .value("月", number), y: .value("支出", annual(number).expense)).foregroundStyle(by: .value("種類", "支出"))
                        } else {
                            BarMark(x: .value("月", number), y: .value("収入", annual(number).income)).foregroundStyle(by: .value("種類", "収入")).position(by: .value("種類", "収入"))
                            BarMark(x: .value("月", number), y: .value("支出", annual(number).expense)).foregroundStyle(by: .value("種類", "支出")).position(by: .value("種類", "支出"))
                        }
                        }
                    }
                }.chartForegroundStyleScale(["収入": Color.teal, "支出": Color.orange]).frame(height: 180)
                    .chartXScale(domain: 1...12)
                    .chartXAxis {
                        AxisMarks(values: Array(1...12)) { value in
                            AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)\(futureMonth(number) ? "予定" : "月")").font(.caption2) } }
                        }
                    }
                    .chartXSelection(value: $annualSelectedMonth)
                    .onChange(of: annualSelectedMonth) { _, value in if let value { store.selectDisplayedMonth(value) } }
                Text("\(Calendar.current.component(.year, from: month))年・集計対象ONの収入と返金差引後支出。未来月は予定で、対象取引のない未来月は描画しません。月を選ぶと詳細を表示します。").font(.caption).foregroundStyle(.secondary)
                if let number = annualSelectedMonth {
                    Text("\(number)月\(futureMonth(number) ? "（予定）" : "")の詳細").font(.headline)
                    TotalsView(totals: annual(number))
                }
            }
        }
    }
    private func futureMonth(_ number: Int) -> Bool {
        let year = Calendar.current.component(.year, from: month)
        guard let date = Calendar.current.date(from: DateComponents(year: year, month: number, day: 1)) else { return false }
        return BudgetCalendar.isFutureMonth(date)
    }
    private func annualHasTargets(_ number: Int) -> Bool {
        store.entries.contains { Calendar.current.component(.year, from: $0.date) == Calendar.current.component(.year, from: month) && Calendar.current.component(.month, from: $0.date) == number && $0.includedInTotals && $0.kind != .transfer }
    }
    private func annual(_ number: Int) -> MoneyTotals {
        let calendar = Calendar.current
        return BudgetSummary.totals(store.entries.filter {
            calendar.component(.year, from: $0.date) == calendar.component(.year, from: month) && calendar.component(.month, from: $0.date) == number
        })
    }
}

struct CategoryChart: View {
    @EnvironmentObject private var store: BudgetStore
    let month: Date
    let kind: EntryKind
    var parentID: UUID? = nil
    private var amounts: [CategoryAmount] {
        guard let bookID = store.bookID else { return [] }
        return store.state.orderedCategoryAmounts(bookID: bookID, kind: kind, entries: store.entries(in: month), parentID: parentID)
    }

    var body: some View {
        if amounts.isEmpty {
            ContentUnavailableView("集計対象の取引がありません", systemImage: "chart.pie", description: Text("対象外の取引は履歴で確認できます。"))
        } else {
            if BudgetSnapshot.categoryChartKind(amounts) == .zero {
                ContentUnavailableView("差引金額は0円です", systemImage: "equal.circle")
            } else {
            Chart(amounts) { item in
                if amounts.contains(where: { $0.amount < 0 }) {
                    BarMark(x: .value("金額", item.amount), y: .value("カテゴリ", item.name))
                        .foregroundStyle(by: .value("カテゴリ", item.name))
                } else {
                    SectorMark(angle: .value("金額", item.amount), innerRadius: .ratio(0.62), angularInset: 2)
                        .foregroundStyle(by: .value("カテゴリ", item.name))
                }
            }.frame(height: 190)
            }
            if amounts.contains(where: { $0.amount < 0 }) {
                Text("返金の差し引きでマイナスのカテゴリがあるため、棒グラフで表示しています。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(amounts) { item in
                NavigationLink {
                    if parentID == nil {
                        List { CategoryChart(month: month, kind: kind, parentID: item.id) }.navigationTitle(item.name)
                    } else {
                        List {
                            ForEach(store.entries(in: month).filter { $0.categoryID == item.id && $0.includedInTotals }) { entry in
                                NavigationLink { EntryDetail(entryID: entry.id) } label: { EntryRow(entry: entry) }
                            }
                        }.navigationTitle(item.name)
                    }
                } label: { HStack { CategoryIconView(categoryID: item.id); Text(item.name); Spacer(); Text(yen(item.amount)).foregroundStyle(.secondary) } }
            }
        }
    }
}

struct EntriesView: View {
    @EnvironmentObject private var store: BudgetStore
    private var month: Date { store.displayMonth }
    private var calendarMode: Bool { store.calendarMode }
    private var selectedDay: Date { store.selectedDay }
    private var visible: [BudgetEntry] {
        let values = store.entries(in: month)
        return calendarMode ? values.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDay) } : values
    }
    var body: some View {
        List {
            MonthPicker()
            Picker("表示", selection: $store.calendarMode) { Text("一覧").tag(false); Text("カレンダー").tag(true) }.pickerStyle(.segmented)
            if calendarMode {
                Section { BudgetCalendarView() }
                Section("\(selectedDay.formatted(date: .abbreviated, time: .omitted))の収支・取引") {
                    TotalsView(totals: BudgetSummary.totals(visible))
                    if visible.contains(where: { $0.kind == .transfer }) { Label("振替があります（収支には含みません）", systemImage: "arrow.left.arrow.right").font(.caption) }
                }
            }
            Button("履歴を検索") { store.openHistorySearch() }
            if visible.isEmpty { ContentUnavailableView("取引がありません", systemImage: "tray", description: Text("この家計簿の取引を＋から登録してください。")) }
            ForEach(visible) { entry in
                NavigationLink { EntryDetail(entryID: entry.id) } label: { EntryRow(entry: entry) }
            }
        }
    }
}

struct EntryRow: View {
    @EnvironmentObject private var store: BudgetStore
    let entry: BudgetEntry
    var body: some View {
        HStack(alignment: .top) {
            if entry.kind == .transfer {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.teal).frame(width: 34).accessibilityHidden(true)
            } else { CategoryIconView(categoryID: entry.categoryID) }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.kind == .transfer ? "\(store.accountName(entry.sourceID)) → \(store.accountName(entry.destinationID))" : store.categoryName(entry.categoryID))
                Text("\(entry.date.formatted(date: .abbreviated, time: .omitted)) ・ \(entry.kind.title)").font(.caption).foregroundStyle(.secondary)
                if let merchant = entry.merchant, !merchant.isEmpty { Text(merchant).font(.caption) }
                if !entry.memo.isEmpty { Text(entry.memo).font(.caption).lineLimit(2) }
                if !entry.includedInTotals && entry.kind != .transfer { Text("収支計算の対象外").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(yen(entry.amount)).monospacedDigit().fontWeight(.medium)
        }.padding(.vertical, 4)
    }
}

struct SummaryView: View {
    @EnvironmentObject private var store: BudgetStore
    private var month: Date { store.displayMonth }
    @State private var expandedTags = false
    private var visibleTags: [BudgetTag] { store.tags.filter { !(store.currentBook?.hiddenTagIDs.contains($0.id) ?? false) } }
    var body: some View {
        List {
            MonthPicker()
            Section("通常収支") { TotalsView(totals: BudgetSummary.totals(store.entries(in: month))) }
            if store.currentBook?.showsTagSummary == true {
                Section("タグ別集計") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                        ForEach(expandedTags ? visibleTags : Array(visibleTags.prefix(4))) { tag in
                            let totals = BudgetSummary.totals(store.entries(in: month).filter { $0.tagIDs.contains(tag.id) }, includeExcluded: true)
                            NavigationLink {
                                List {
                                    TotalsView(totals: totals)
                                    LabeledContent("振替", value: yen(totals.transfer))
                                    ForEach(store.entries(in: month).filter { $0.tagIDs.contains(tag.id) }) { entry in
                                        NavigationLink { EntryDetail(entryID: entry.id) } label: { EntryRow(entry: entry) }
                                    }
                                }.navigationTitle(tag.name)
                            } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tag.name).font(.headline)
                                Text("収入 \(yen(totals.income))")
                                Text("支出 \(yen(totals.expense))")
                                Text("振替 \(yen(totals.transfer))")
                            }.font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                    if visibleTags.count > 4 { Button(expandedTags ? "閉じる" : "もっと見る") { expandedTags.toggle() } }
                    if visibleTags.isEmpty { Text("表示するタグは設定の「タグ集計の表示」で選べます。非表示でも付与・検索は可能です。").foregroundStyle(.secondary) }
                    Text("集計対象OFFも含みます。振替は別表示で、タグ間の金額は重複する場合があります。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("カテゴリ別集計") {
                CategoryKindPicker()
                CategoryChart(month: month, kind: store.categoryKind)
            }
        }
    }
}

struct EntryDetail: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let entryID: UUID
    var fromHistory = false
    @State private var editedFromHistory = false
    @State private var editing = false
    @State private var deleting = false
    @State private var addingRefund = false
    var body: some View {
        Group {
            if let raw = store.state.entries.first(where: { $0.id == entryID }) {
                let entry = store.state.effectiveEntry(raw)
                List {
                    if store.state.books.first(where: { $0.id == entry.bookID })?.archived == true {
                        Label("アーカイブ済みの家計簿：閲覧専用", systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    EntryRow(entry: entry)
                    LabeledContent("出金元", value: store.accountName(entry.sourceID))
                    LabeledContent("入金先", value: store.accountName(entry.destinationID))
                    ForEach(store.tags.filter { entry.tagIDs.contains($0.id) }) { Text("#\($0.name)") }
                    if entry.kind == .expense {
                        let refunds = store.state.refunds(for: entry.id)
                        let refunded = store.state.refundedAmount(for: entry.id)
                        Section("返金") {
                            LabeledContent("返金合計", value: yen(refunded))
                            LabeledContent("未返金額", value: yen(entry.amount - refunded))
                            Button("この支出の返金を登録") { addingRefund = true }.disabled(refunded >= entry.amount || !store.canEditBook(entry.bookID))
                            ForEach(refunds) { refund in
                                NavigationLink { EntryDetail(entryID: refund.id) } label: { EntryRow(entry: refund) }
                            }
                        }
                    }
                    if entry.kind == .refund, let originalID = entry.refundOfID {
                        Section("元の支出") {
                            NavigationLink("元の支出を開く") { EntryDetail(entryID: originalID) }
                        }
                    }
                    Button("編集") { editing = true }.disabled(!store.canEditBook(entry.bookID))
                    Button("削除", role: .destructive) { deleting = true }.disabled(!store.canEditBook(entry.bookID))
                }
                .sheet(isPresented: $addingRefund) { NavigationStack { EntryEditor(bookID: entry.bookID, refundOriginal: entry) } }
                .sheet(isPresented: $editing, onDismiss: {
                    if editedFromHistory { editedFromHistory = false; dismiss() }
                }) {
                    NavigationStack {
                        EntryEditor(bookID: entry.bookID, existing: entry, onSaved: { id in
                            if fromHistory { store.historyEntrySaved(id); editedFromHistory = true }
                        })
                    }
                }
                .confirmationDialog("この取引を削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("削除", role: .destructive) { store.deleteEntry(entryID); if store.errorMessage == nil { dismiss() } }
                } message: {
                    Text(entry.kind == .expense && !store.state.refunds(for: entryID).isEmpty
                         ? "この支出に紐づく返金もすべて削除します。この操作は取り消せません。"
                         : "この操作は取り消せません。")
                }
            } else { ContentUnavailableView("取引が見つかりません", systemImage: "tray") }
        }.navigationTitle("取引詳細")
    }
}


struct CategoryKindPicker: View {
    @EnvironmentObject private var store: BudgetStore
    var body: some View {
        Picker("収支種別", selection: $store.categoryKind) {
            Text("支出").tag(EntryKind.expense)
            Text("収入").tag(EntryKind.income)
        }.pickerStyle(.segmented)
    }
}
