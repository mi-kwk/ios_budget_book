import SwiftUI

struct EntryEditor: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let existing: BudgetEntry?
    @State private var kind: EntryKind
    @State private var amount: String
    @State private var date: Date
    @State private var categoryID: UUID?
    @State private var sourceID: UUID?
    @State private var destinationID: UUID?
    @State private var tags: Set<UUID>
    @State private var included: Bool
    @State private var memo: String
    @State private var error: String?
    @State private var master: MasterType?
    @State private var choosingAccount: AccountSide?
    @State private var choosingCategory = false
    @State private var didInitialize = false
    init(bookID: UUID, existing: BudgetEntry? = nil) {
        self.bookID = bookID; self.existing = existing
        _kind = State(initialValue: existing?.kind ?? .expense)
        _amount = State(initialValue: existing.map { String($0.amount) } ?? "")
        _date = State(initialValue: existing?.date ?? Date())
        _categoryID = State(initialValue: existing?.categoryID)
        _sourceID = State(initialValue: existing?.sourceID)
        _destinationID = State(initialValue: existing?.destinationID)
        _tags = State(initialValue: existing?.tagIDs ?? [])
        _included = State(initialValue: existing?.includedInTotals ?? true)
        _memo = State(initialValue: existing?.memo ?? "")
    }
    var body: some View {
        Form {
            Section { Text(store.state.books.first { $0.id == bookID }?.name ?? "家計簿").font(.headline) }
            Picker("種類", selection: $kind) { ForEach(EntryKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Section("金額・日付") {
                TextField("金額（円）", text: $amount).keyboardType(.numberPad)
                DatePicker("日付", selection: $date, displayedComponents: .date)
            }
            if kind != .transfer {
                Section("カテゴリ") {
                    Button { choosingCategory = true } label: {
                        HStack {
                            Text("カテゴリ")
                            Spacer()
                            Text(store.categories.first(where: { $0.id == categoryID }).map(store.categoryTitle) ?? "未分類")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(.primary)

                }
            }
            Section("入出金元") {
                if kind != .income { accountButton("出金元", id: sourceID, side: .source) }
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
                if kind != .transfer { Toggle("収支計算の対象", isOn: $included) }
                TextField("メモ", text: $memo, axis: .vertical)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(existing == nil ? "取引を登録" : "取引を編集")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear {
            guard !didInitialize else { return }; didInitialize = true
            if existing == nil { resetAccounts() }
        }
        .onChange(of: kind) { _, _ in categoryID = nil; resetAccounts(); included = true }
        .sheet(isPresented: $choosingCategory) {
            NavigationStack {
                CategorySelectionView(bookID: bookID, kind: kind, currentID: categoryID ?? existing?.categoryID) { id in
                    categoryID = id; choosingCategory = false
                }
            }
        }
        .sheet(item: $master) { item in NavigationStack { MasterEditorView(type: item, bookID: bookID) } }
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
    private func save() {
        guard let value = Int64(amount), value > 0 else { error = BudgetError.invalidAmount.localizedDescription; return }
        let entry = BudgetEntry(id: existing?.id ?? UUID(), bookID: bookID, kind: kind, amount: value, date: date, categoryID: categoryID, sourceID: sourceID, destinationID: destinationID, tagIDs: tags, includedInTotals: included, memo: memo)
        do { _ = try store.state.validated(entry, previous: existing) } catch { self.error = error.localizedDescription; return }
        if store.saveEntry(entry) { dismiss() } else { error = store.errorMessage }
    }
}

enum AccountSide: String, Identifiable { case source, destination; var id: String { rawValue } }
