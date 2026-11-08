import SwiftUI

struct HistorySearchNavigation: View {
    @EnvironmentObject private var store: BudgetStore
    var body: some View {
        NavigationStack { HistoryView() }.id(store.bookID)
    }
}

struct HistoryView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var keywordFocused: Bool
    private var query: EntrySearchQuery { store.historyQuery ?? EntrySearchQuery(month: store.displayMonth) }
    private var results: [BudgetEntry] { store.bookID.map { store.state.searchEntries(bookID: $0, query: query) } ?? [] }
    private var binding: Binding<EntrySearchQuery> { Binding(get: { query }, set: { store.setHistoryQuery($0) }) }
    var body: some View {
        List {
            Section("キーワード") {
                TextField("相手先・メモ（空白で複数語）", text: binding.keyword)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($keywordFocused).submitLabel(.search)
                    .onSubmit { keywordFocused = false }
                Text("英字大小と全角半角は区別せず、複数語はすべて一致で検索します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("家計簿", value: store.currentBook?.name ?? "未選択")
                Text(periodTitle).font(.subheadline)
                NavigationLink { HistoryFiltersView(query: binding) } label: {
                    Label("検索条件", systemImage: "line.3.horizontal.decrease")
                }
                Button("条件をリセット") { store.resetHistorySearch() }
                if store.currentBook?.archived == true { Label("閲覧専用の家計簿", systemImage: "lock").font(.caption) }
            }
            if let notice = store.historyNotice { Section { Text(notice).font(.callout).accessibilityIdentifier("historyNotice") } }
            if !query.hasValidPeriod() {
                Section { Text("開始日は終了日以前にしてください。").foregroundStyle(.red) }
            } else {
                Section("検索結果：\(results.count)件（集計対象外も選択条件に応じて含む）") {
                    let totals = BudgetSummary.totals(results, includeExcluded: true)
                    LabeledContent("収入", value: yen(totals.income))
                    LabeledContent("支出（返金差引後）", value: yen(totals.expense))
                    LabeledContent("振替", value: yen(totals.transfer))
                    LabeledContent("返金（支出から控除済み）", value: yen(results.filter { $0.kind == .refund }.reduce(0) { $0 + $1.amount }))
                }
                Section("対象取引") {
                    if results.isEmpty { ContentUnavailableView("条件に合う取引がありません", systemImage: "magnifyingglass", description: Text("期間や検索条件を変更してください。")) }
                    ForEach(results) { entry in
                        NavigationLink { EntryDetail(entryID: entry.id, fromHistory: true) } label: { EntryRow(entry: entry) }
                    }
                }
            }
        }.navigationTitle("履歴検索").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(store.state.orderedBooks(includeArchived: false)) { book in
                            Button(book.name) { store.selectBook(book.id) }
                        }
                    } label: { Label(store.currentBook?.name ?? "家計簿", systemImage: "books.vertical") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } }
            }
            .onAppear { store.beginHistorySearch() }
    }
    private var periodTitle: String {
        switch query.period {
        case .month: query.month.formatted(.dateTime.year().month()) + "を検索"
        case .custom: query.startDate.formatted(date: .abbreviated, time: .omitted) + "〜" + query.endDate.formatted(date: .abbreviated, time: .omitted)
        case .all: "全期間を検索"
        }
    }
}

struct HistoryFiltersView: View {
    @EnvironmentObject private var store: BudgetStore
    @Binding var query: EntrySearchQuery
    var body: some View {
        Form { periodSection; kindsSection; inclusionSection; categoriesSection; tagsSection; accountsSection }
            .navigationTitle("検索条件").navigationBarTitleDisplayMode(.inline)
    }
    private var periodSection: some View {
        Section("期間") {
            Picker("検索期間", selection: $query.period) { ForEach(EntrySearchPeriod.allCases) { Text($0.title).tag($0) } }
            if query.period == .month {
                DatePicker("対象月", selection: $query.month, in: EntryDateLimits.range(), displayedComponents: .date)
                Text("選んだ日を含む1か月を検索します。取引を編集しても検索期間は変わりません。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if query.period == .custom {
                DatePicker("開始日", selection: $query.startDate, in: EntryDateLimits.range(), displayedComponents: .date)
                DatePicker("終了日", selection: $query.endDate, in: EntryDateLimits.range(), displayedComponents: .date)
                if !query.hasValidPeriod() { Text("開始日は終了日以前にしてください。").foregroundStyle(.red) }
            }
        }
    }
    private var kindsSection: some View {
        Section("取引種別（未選択はすべて）") {
            ForEach(EntryKind.allCases) { kind in
                Toggle(kind.title, isOn: Binding(get: { query.kinds.contains(kind) }, set: { enabled in
                    var next = query
                    if enabled { next.kinds.insert(kind) } else { next.kinds.remove(kind) }
                    query = next
                }))
            }
        }
    }
    private var inclusionSection: some View {
        Section("収支計算の対象") {
            Picker("対象内・外", selection: $query.inclusion) { ForEach(EntrySearchInclusion.allCases) { Text($0.title).tag($0) } }
            Text("振替は収支計算の対象外として扱います。異なる条件はAND、カテゴリ・入出金元の複数選択はORです。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var categoriesSection: some View {
        Section {
            DisclosureGroup("カテゴリ（\(query.categoryIDs.count)件）") {
                if let book = store.bookID {
                    ForEach([EntryKind.expense, .income]) { kind in
                        ForEach(store.state.orderedCategories(bookID: book, kind: kind, parentID: nil)) { parent in
                            uuidToggle("\(kind.title) / \(parent.name)（配下すべて）" + archived(parent), id: parent.id, selection: $query.categoryIDs)
                            ForEach(store.state.orderedCategories(bookID: book, kind: kind, parentID: parent.id)) { child in
                                uuidToggle(child.name + archived(child), id: child.id, selection: $query.categoryIDs).padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
    }
    private var tagsSection: some View {
        Section {
            DisclosureGroup("タグ（\(query.tagIDs.count)件）") {
                Picker("複数タグ条件", selection: $query.matchAllTags) { Text("すべて一致（AND）").tag(true); Text("いずれか（OR）").tag(false) }
                ForEach(store.tags) { tag in uuidToggle(tag.name + (tag.isArchived ? "（アーカイブ済み）" : ""), id: tag.id, selection: $query.tagIDs) }
                if store.tags.isEmpty { Text("タグはありません。") }
            }
        }
    }
    private var accountsSection: some View {
        Section {
            DisclosureGroup("入出金元（\(query.accountIDs.count)件）") {
                ForEach(store.accounts) { account in uuidToggle(account.name + (account.isArchived ? "（アーカイブ済み）" : ""), id: account.id, selection: $query.accountIDs) }
            }
            Text("家計簿を切り替えるとカテゴリ・タグ・入出金元の選択のみ解除します。期間・種別・キーワード・対象内外・タグAND/ORは保持します。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func archived(_ category: BudgetCategory) -> String { store.state.isCategoryAvailable(category) ? "" : "（アーカイブ済み）" }
    private func uuidToggle(_ title: String, id: UUID, selection: Binding<Set<UUID>>) -> some View {
        Toggle(title, isOn: Binding(get: { selection.wrappedValue.contains(id) }, set: { enabled in
            var values = selection.wrappedValue
            if enabled { values.insert(id) } else { values.remove(id) }
            selection.wrappedValue = values
        }))
    }
}
