import SwiftUI

struct EntryEditor: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let existing: BudgetEntry?
    let refundOriginal: BudgetEntry?
    let onSaved: ((UUID) -> Void)?
    @State private var kind: EntryKind
    @State private var amount: String
    @State private var date: Date
    @State private var categoryID: UUID?
    @State private var sourceID: UUID?
    @State private var destinationID: UUID?
    @State private var tags: Set<UUID>
    @State private var included: Bool
    @State private var memo: String
    @State private var merchant: String
    @State private var baseline: BudgetEntry?
    @State private var discarding = false
    @State private var error: String?
    @State private var master: MasterType?
    @State private var choosingAccount: AccountSide?
    @State private var choosingCategory = false
    @State private var didInitialize = false
    init(bookID: UUID, existing: BudgetEntry? = nil, refundOriginal: BudgetEntry? = nil, initialDate: Date = Date(), onSaved: ((UUID) -> Void)? = nil) {
        self.bookID = bookID; self.existing = existing; self.refundOriginal = refundOriginal; self.onSaved = onSaved
        _kind = State(initialValue: existing?.kind ?? (refundOriginal == nil ? .expense : .refund))
        _amount = State(initialValue: existing.map { String($0.amount) } ?? "")
        _date = State(initialValue: existing?.date ?? EntryDateLimits.clamp(max(initialDate, refundOriginal?.date ?? .distantPast)))
        _categoryID = State(initialValue: existing?.categoryID)
        _sourceID = State(initialValue: existing?.sourceID)
        _destinationID = State(initialValue: existing?.destinationID)
        _tags = State(initialValue: existing?.tagIDs ?? refundOriginal?.tagIDs ?? [])
        _included = State(initialValue: existing?.includedInTotals ?? true)
        _memo = State(initialValue: existing?.memo ?? "")
        _merchant = State(initialValue: existing?.merchant ?? refundOriginal?.merchant ?? "")
    }
    var body: some View {
        Form {
            Section { Text(store.state.books.first { $0.id == bookID }?.name ?? "家計簿").font(.headline) }
            if existing == nil && kind != .refund {
                Picker("種類", selection: $kind) {
                    ForEach(EntryKind.allCases.filter { $0 != .refund }) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            } else { LabeledContent("種類", value: kind.title) }
            if kind == .refund, let original = currentOriginal {
                Section("元の支出") {
                    Text("\(original.date.formatted(date: .abbreviated, time: .omitted)) ・ \(yen(original.amount))")
                    Text("返金可能額 \(yen(original.amount - store.state.refundedAmount(for: original.id) + (existing?.amount ?? 0)))")
                    Text("カテゴリ・収支計算対象は元の支出に連動します。タグはこの返金で個別に変更できます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("金額・日付") {
                TextField("金額（円）", text: $amount).keyboardType(.numberPad)
                DatePicker("日付", selection: $date, in: EntryDateLimits.range(), displayedComponents: .date)
            }
            if kind != .transfer && kind != .refund {
                Section("カテゴリ") {
                    Button { choosingCategory = true } label: {
                        HStack {
                            Text("カテゴリ")
                            Spacer()
                            Text(store.categories.first(where: { $0.id == categoryID }).map(store.categoryTitle) ?? "未分類 ＞ 未分類")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(.primary)

                }
            }
            Section("入出金元") {
                if kind == .expense || kind == .transfer { accountButton("出金元", id: sourceID, side: .source) }
                if kind != .expense { accountButton("入金先", id: destinationID, side: .destination) }
                if kind == .transfer { Text("片方のみの指定も可能です。残高は計算しません。").font(.caption).foregroundStyle(.secondary) }
            }
            Section("タグ（任意）") {
                ForEach(store.tags.filter { !$0.isArchived || tags.contains($0.id) }) { tag in
                    Toggle(tag.name, isOn: Binding(get: { tags.contains(tag.id) }, set: { if $0 { tags.insert(tag.id) } else { tags.remove(tag.id) } }))
                }
                Button("タグを追加", systemImage: "plus") { master = .tag }
            }
            Section {
                if kind != .transfer && kind != .refund { Toggle("収支計算の対象", isOn: $included) }
                TextField("お店・相手先（任意）", text: $merchant)
                Text("\(merchant.count)/100文字").font(.caption).foregroundStyle(merchant.count > 100 ? .red : .secondary)
                TextField("メモ", text: $memo, axis: .vertical)
                Text("\(memo.count)/1,000文字").font(.caption).foregroundStyle(memo.count > 1000 ? .red : .secondary)
            }

        }
        .navigationTitle(existing == nil ? (kind == .refund ? "返金を登録" : "取引を登録") : "取引を編集")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { if hasChanges { discarding = true } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!store.canEditBook(bookID)) }
        }
        .onAppear {
            guard !didInitialize else { return }; didInitialize = true
            if existing == nil {
                if kind == .refund {
                    destinationID = store.accounts.first { $0.id == refundOriginal?.sourceID && !$0.isArchived }?.id
                } else { resetAccounts() }
            }
            baseline = draft
        }
        .alert("保存できません", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("閉じる", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .interactiveDismissDisabled(hasChanges)
        .alert("入力内容を破棄しますか？", isPresented: $discarding) {
            Button("入力を続ける", role: .cancel) {}
            Button("破棄する", role: .destructive) { dismiss() }
        }
        .onChange(of: kind) { _, _ in categoryID = nil; resetAccounts(); included = true }
        .sheet(isPresented: $choosingCategory) {
            NavigationStack {
                CategorySelectionView(bookID: bookID, kind: kind, currentID: categoryID ?? existing?.categoryID) { id in
                    categoryID = id; choosingCategory = false
                }
            }
        }
        .sheet(item: $master) { item in
            NavigationStack {
                MasterEditorView(type: item, bookID: bookID, onSaved: { id in tags.insert(id) })
            }
        }
        .sheet(item: $choosingAccount) { side in
            NavigationStack {
                AccountSelectionView(bookID: bookID, title: side == .source ? "出金元" : "入金先",
                                     currentID: side == .source ? sourceID : destinationID,
                                     previousID: side == .source ? existing?.sourceID : existing?.destinationID,
                                     allowsUnspecified: kind == .transfer) { id in
                    if side == .source { sourceID = id } else { destinationID = id }
                    choosingAccount = nil
                }
            }
        }
    }
    private func accountButton(_ title: String, id: UUID?, side: AccountSide) -> some View {
        Button { choosingAccount = side } label: {
            HStack {
                Text(title); Spacer()
                Text(store.accountName(id)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }.tint(.primary)
    }
    private func resetAccounts() {
        let wallet = store.accounts.first { $0.isWallet }?.id
        sourceID = kind == .expense ? wallet : nil
        destinationID = kind == .income ? wallet : nil
    }
    private var currentOriginal: BudgetEntry? {
        let id = existing?.refundOfID ?? refundOriginal?.id
        return store.state.entries.first { $0.id == id && $0.kind == .expense }
    }
    private var draft: BudgetEntry {
        // Stable placeholder identity makes dirty checking independent of UUID generation.
        BudgetEntry(id: existing?.id ?? bookID, bookID: bookID, kind: kind, amount: Int64(amount) ?? 0,
                    date: date, categoryID: categoryID, sourceID: sourceID, destinationID: destinationID,
                    tagIDs: tags, includedInTotals: included, memo: memo, merchant: merchant,
                    createdAt: existing?.createdAt, refundOfID: existing?.refundOfID ?? refundOriginal?.id)
    }
    private var hasChanges: Bool {
        guard let baseline else { return false }
        // Compare the raw amount too: a nonnumeric edit must still trigger the warning.
        return draft != baseline || amount != (baseline.amount == 0 ? "" : String(baseline.amount))
    }
    private func save() {
        guard let value = Int64(amount), value > 0 else { error = BudgetError.invalidAmount.localizedDescription; return }
        var entry = draft
        entry.id = existing?.id ?? UUID(); entry.amount = value
        do { _ = try store.state.validated(entry, previous: existing) } catch { self.error = error.localizedDescription; return }
        if store.saveEntry(entry) { onSaved?(entry.id); dismiss() } else { error = store.errorMessage; store.errorMessage = nil }
    }
}

enum AccountSide: String, Identifiable { case source, destination; var id: String { rawValue } }
