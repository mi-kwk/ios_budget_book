import SwiftUI
import Charts

func yen(_ amount: Int64) -> String { amount.formatted(.currency(code: "JPY").precision(.fractionLength(0))) }

struct RootView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var showSettings = false
    @State private var showEntry = false
    var body: some View {
        TabView {
            shell("ホーム") { HomeView() }.tabItem { Label("ホーム", systemImage: "house") }
            shell("入出金") { EntriesView() }.tabItem { Label("入出金", systemImage: "list.bullet.rectangle") }
            shell("収支") { SummaryView() }.tabItem { Label("収支", systemImage: "chart.pie") }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $showEntry) {
            if let bookID = store.bookID { NavigationStack { EntryEditor(bookID: bookID) } }
        }
        .alert("確認", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("閉じる", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
    private func shell<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(store.state.books) { book in
                                Button { store.selectBook(book.id) } label: {
                                    if store.bookID == book.id { Label(book.name, systemImage: "checkmark") }
                                    else { Text(book.name) }
                                }
                            }
                        } label: { Label(store.currentBook?.name ?? "家計簿", systemImage: "books.vertical") }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("設定")
                        Button { showEntry = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("取引を登録").disabled(store.bookID == nil || !store.canWrite)
                    }
                }
        }
    }
}

struct MonthPicker: View {
    @Binding var month: Date
    var body: some View {
        HStack {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("前の月")
            Spacer()
            Text(month.formatted(.dateTime.year().month())).font(.headline)
            Spacer()
            Button { move(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("次の月")
        }.buttonStyle(.borderless).padding(.vertical, 4)
    }
    private func move(_ value: Int) { month = Calendar.current.date(byAdding: .month, value: value, to: month) ?? month }
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
    @State private var month = Date()
    @State private var lineChart = false
    var body: some View {
        List {
            MonthPicker(month: $month)
            Section("月間収支") { TotalsView(totals: BudgetSummary.totals(store.entries(in: month))) }
            Section("カテゴリ別支出") { CategoryChart(month: month, kind: .expense) }
            Section("年間収支") {
                Picker("グラフ形式", selection: $lineChart) { Text("棒").tag(false); Text("折れ線").tag(true) }.pickerStyle(.segmented)
                Chart {
                    ForEach(1...12, id: \.self) { number in
                        if lineChart {
                            LineMark(x: .value("月", number), y: .value("収入", annual(number).income)).foregroundStyle(by: .value("種類", "収入"))
                            LineMark(x: .value("月", number), y: .value("支出", annual(number).expense)).foregroundStyle(by: .value("種類", "支出"))
                        } else {
                            BarMark(x: .value("月", number), y: .value("収入", annual(number).income)).foregroundStyle(by: .value("種類", "収入")).position(by: .value("種類", "収入"))
                            BarMark(x: .value("月", number), y: .value("支出", annual(number).expense)).foregroundStyle(by: .value("種類", "支出")).position(by: .value("種類", "支出"))
                        }
                    }
                }.chartForegroundStyleScale(["収入": Color.teal, "支出": Color.orange]).frame(height: 180)
                Text("\(Calendar.current.component(.year, from: month))年・集計対象ONの収入と支出").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func annual(_ number: Int) -> MoneyTotals {
        let calendar = Calendar.current
        return BudgetSummary.totals(store.entries.filter {
            calendar.component(.year, from: $0.date) == calendar.component(.year, from: month) && calendar.component(.month, from: $0.date) == number
        })
    }
}

struct CategoryAmount: Identifiable { let id: UUID; let name: String; let amount: Int64 }
struct CategoryChart: View {
    @EnvironmentObject private var store: BudgetStore
    let month: Date
    let kind: EntryKind
    var parentID: UUID? = nil
    private var amounts: [CategoryAmount] {
        guard let bookID = store.bookID else { return [] }
        return store.state.categoryAmounts(bookID: bookID, kind: kind, entries: store.entries(in: month), parentID: parentID)
            .map { CategoryAmount(id: $0.key, name: store.categoryName($0.key), amount: $0.value) }
            .sorted { $0.amount == $1.amount ? $0.name < $1.name : $0.amount > $1.amount }
    }

    var body: some View {
        if amounts.isEmpty {
            ContentUnavailableView("集計する取引がありません", systemImage: "chart.pie", description: Text("＋から収入や支出を登録できます。"))
        } else {
            Chart(amounts) { item in
                SectorMark(angle: .value("金額", item.amount), innerRadius: .ratio(0.62), angularInset: 2)
                    .foregroundStyle(by: .value("カテゴリ", item.name))
            }.frame(height: 190)
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
                } label: { HStack { Text(item.name); Spacer(); Text(yen(item.amount)).foregroundStyle(.secondary) } }
            }
        }
    }
}

struct EntriesView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var month = Date()
    @State private var calendarMode = false
    @State private var selectedDay = Date()
    private var visible: [BudgetEntry] {
        let values = store.entries(in: month)
        return calendarMode ? values.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDay) } : values
    }
    var body: some View {
        List {
            MonthPicker(month: $month)
            Picker("表示", selection: $calendarMode) { Text("一覧").tag(false); Text("カレンダー").tag(true) }.pickerStyle(.segmented)
            if calendarMode {
                DatePicker("日付", selection: $selectedDay, displayedComponents: .date).datePickerStyle(.graphical)
                    .onChange(of: selectedDay) { _, value in month = value }
                Section("選択日の収支") { TotalsView(totals: BudgetSummary.totals(visible)) }
            }
            NavigationLink("履歴を検索", destination: HistoryView())
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
            Image(systemName: entry.kind == .transfer ? "arrow.left.arrow.right" : entry.kind == .expense ? "arrow.up.right" : "arrow.down.left")
                .foregroundStyle(entry.kind == .expense ? Color.orange : Color.teal).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.kind == .transfer ? "\(store.accountName(entry.sourceID)) → \(store.accountName(entry.destinationID))" : store.categoryName(entry.categoryID))
                Text("\(entry.date.formatted(date: .abbreviated, time: .omitted)) ・ \(entry.kind.title)").font(.caption).foregroundStyle(.secondary)
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
    @State private var month = Date()
    @State private var kind = EntryKind.expense
    var body: some View {
        List {
            MonthPicker(month: $month)
            Section("通常収支") { TotalsView(totals: BudgetSummary.totals(store.entries(in: month))) }
            if store.currentBook?.showsTagSummary == true {
                Section("タグ別集計") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                        ForEach(store.tags.filter { !(store.currentBook?.hiddenTagIDs.contains($0.id) ?? false) }) { tag in
                            let totals = BudgetSummary.totals(store.entries(in: month).filter { $0.tagIDs.contains(tag.id) }, includeExcluded: true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tag.name).font(.headline)
                                Text("収入 \(yen(totals.income))")
                                Text("支出 \(yen(totals.expense))")
                                Text("振替 \(yen(totals.transfer))")
                            }.font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if store.tags.isEmpty { Text("タグは設定から追加できます。").foregroundStyle(.secondary) }
                    Text("集計対象OFFも含みます。振替は別表示で、タグ間の金額は重複する場合があります。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("カテゴリ別集計") {
                Picker("収支種別", selection: $kind) { Text("支出").tag(EntryKind.expense); Text("収入").tag(EntryKind.income) }.pickerStyle(.segmented)
                CategoryChart(month: month, kind: kind)
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var text = ""
    @State private var selectedTags: Set<UUID> = []
    @State private var matchAll = true
    var body: some View {
        List {
            if !store.tags.isEmpty {
                Section("タグで絞り込み") {
                    Picker("複数タグ条件", selection: $matchAll) { Text("すべて一致（AND）").tag(true); Text("いずれか（OR）").tag(false) }
                    ForEach(store.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { selectedTags.contains(tag.id) }, set: { if $0 { selectedTags.insert(tag.id) } else { selectedTags.remove(tag.id) } }))
                    }
                }
            }
            Section("すべての期間・対象外の取引も含む") {
                ForEach(BudgetSummary.matchingTags(store.entries, tags: selectedTags, matchAll: matchAll).filter { text.isEmpty || $0.memo.localizedCaseInsensitiveContains(text) || store.categoryName($0.categoryID).localizedCaseInsensitiveContains(text) }) { entry in
                    NavigationLink { EntryDetail(entryID: entry.id) } label: { EntryRow(entry: entry) }
                }
            }
        }.searchable(text: $text, prompt: "メモ・カテゴリ名").navigationTitle("履歴")
    }
}

struct EntryDetail: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let entryID: UUID
    @State private var editing = false
    @State private var deleting = false
    var body: some View {
        Group {
            if let entry = store.state.entries.first(where: { $0.id == entryID }) {
                List {
                    EntryRow(entry: entry)
                    LabeledContent("出金元", value: store.accountName(entry.sourceID))
                    LabeledContent("入金先", value: store.accountName(entry.destinationID))
                    ForEach(store.tags.filter { entry.tagIDs.contains($0.id) }) { Text("#\($0.name)") }
                    Button("編集") { editing = true }
                    Button("削除", role: .destructive) { deleting = true }
                }
                .sheet(isPresented: $editing) { NavigationStack { EntryEditor(bookID: entry.bookID, existing: entry) } }
                .confirmationDialog("この取引を削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("削除", role: .destructive) { store.deleteEntry(entryID); if store.errorMessage == nil { dismiss() } }
                }
            } else { ContentUnavailableView("取引が見つかりません", systemImage: "tray") }
        }.navigationTitle("取引詳細")
    }
}
